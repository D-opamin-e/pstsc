import AppKit

/// AppKit drops key-up events while Command is held; the remote side needs them to release keys.
final class PstscApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyUp, event.modifierFlags.contains(.command), let keyWindow,
           keyWindow.firstResponder is RemoteContentView {
            keyWindow.sendEvent(event)
            return
        }
        super.sendEvent(event)
    }
}

/// Two agents logged in as the same user keep taking the remote session from each other
/// (ERRINFO_RPC_INITIATED_DISCONNECT), so only one may run. The lock is released when the process exits.
private func acquireSingleInstanceLock() -> Bool {
    try? FileManager.default.createDirectory(at: AppCatalog.supportFolder, withIntermediateDirectories: true)
    let path = AppCatalog.supportFolder.appendingPathComponent("agent.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
}

/// `PstscAgent --write-iconset <dir>`: writes the Dock icon as an .iconset for scripts/build-app.sh.
if let flag = CommandLine.arguments.firstIndex(of: "--write-iconset"), CommandLine.arguments.count > flag + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let icon = DockIcon.make()
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
        }
    }
    exit(0)
}

guard acquireSingleInstanceLock() else {
    FileHandle.standardError.write(Data("[pstsc] Pstsc is already running; quit the other instance first.\n".utf8))
    exit(1)
}

/// Copies everything written to stderr (our logs and FreeRDP's) into ~/Library/Logs/Pstsc/agent.log
/// while still passing it through, so a run started from Finder or another terminal can be inspected.
private func mirrorStderrToLogFile() {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pstsc")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let logURL = folder.appendingPathComponent("agent.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil) // start fresh each launch
    guard let log = try? FileHandle(forWritingTo: logURL) else { return }

    let original = dup(STDERR_FILENO)
    var fds: [Int32] = [0, 0]
    guard original >= 0, pipe(&fds) == 0 else { return }
    dup2(fds[1], STDERR_FILENO)
    close(fds[1])
    let reader = fds[0]
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(reader, &buffer, buffer.count)
            if count <= 0 { break }
            _ = buffer.withUnsafeBytes { write(original, $0.baseAddress, count) }
            log.write(Data(buffer[0..<count]))
        }
    }
}

mirrorStderrToLogFile()
// FreeRDP's own log names the remote PC, account and address; keep it off unless asked for
// (e.g. WLOG_LEVEL=INFO when debugging).
setenv("WLOG_LEVEL", "OFF", 0)

let app = PstscApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
