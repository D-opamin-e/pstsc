import AppKit
import CryptoKit

/// Messages between the agent and the per-program Dock proxies (DistributedNotificationCenter).
/// Keep in sync with Sources/PstscDockProxy/main.swift.
enum DockMessage {
    // agent -> proxy (object: program key)
    static let update = Notification.Name("pstsc.proxy.update")
    static let quit = Notification.Name("pstsc.proxy.quit")
    static let quitAll = Notification.Name("pstsc.proxy.quitAll")
    // proxy -> agent (object: program key)
    static let hello = Notification.Name("pstsc.agent.hello")
    static let activate = Notification.Name("pstsc.agent.activate")
    static let close = Notification.Name("pstsc.agent.close")
    static let focusWindow = Notification.Name("pstsc.agent.focusWindow")
}

/// A remote program with at least one window on screen, e.g. KakaoTalk.exe.
struct RemoteProgram {
    let key: String
    var name: String
    var icon: CGImage?
    /// Start menu entry, to start the program again (e.g. bring it back from the tray).
    var appID: String?
    var windowIds: Set<UInt32> = []
}

/// Groups remote windows by the program that owns them and keeps one Dock proxy per program.
final class ProgramTracker {
    /// explicit: the user clicked the Dock icon (not just macOS activating the proxy on its own).
    var onActivate: ((RemoteProgram, _ explicit: Bool) -> Void)?
    /// Whether a window is open on screen (shown and not hidden by the server).
    var isPresent: ((UInt32) -> Bool)?
    var onClose: ((RemoteProgram) -> Void)?
    var onFocusWindow: ((UInt32) -> Void)?
    /// Supplies (id, title) of the program's app windows for the proxy's Dock menu.
    var windowTitles: ((RemoteProgram) -> [(UInt32, String)])?

    private let catalog: AppCatalog
    private let icons: AppIconStore
    private let proxies = DockProxyController()
    private(set) var programs: [String: RemoteProgram] = [:]
    private var windowProgram: [UInt32: String] = [:]
    private var windowIcons: [UInt32: CGImage] = [:]
    private var windowTitlesSeen: [UInt32: String] = [:]
    private var pendingOwned: [UInt32: UInt32] = [:] // owned window -> owner
    private var requested = Set<UInt32>()

    init(catalog: AppCatalog, icons: AppIconStore) {
        self.catalog = catalog
        self.icons = icons
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: DockMessage.hello, object: nil, queue: .main) { [weak self] note in
            guard let self, let key = note.object as? String, let program = self.programs[key] else { return }
            self.sendUpdate(program)
        }
        center.addObserver(forName: DockMessage.activate, object: nil, queue: .main) { [weak self] note in
            guard let self, let key = note.object as? String, let program = self.programs[key] else { return }
            self.onActivate?(program, note.userInfo?["explicit"] as? Bool ?? true)
        }
        center.addObserver(forName: DockMessage.close, object: nil, queue: .main) { [weak self] note in
            guard let self, let key = note.object as? String, let program = self.programs[key] else { return }
            self.onClose?(program)
        }
        center.addObserver(forName: DockMessage.focusWindow, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? Int else { return }
            self?.onFocusWindow?(UInt32(id))
        }
        proxies.quitAll()
    }

    func program(forWindow id: UInt32) -> RemoteProgram? {
        windowProgram[id].flatMap { programs[$0] }
    }

    /// Called the first time a remote app window appears on the Mac.
    func windowShown(_ window: RemoteAppWindow, session: RDPSession) {
        let info = window.info
        windowTitlesSeen[info.id] = info.title
        if info.ownerId != 0 {
            if let key = windowProgram[info.ownerId] {
                assign(info.id, to: key)
            } else {
                pendingOwned[info.id] = info.ownerId
            }
            return
        }
        guard !requested.contains(info.id) else { return }
        requested.insert(info.id)
        session.requestAppId(windowId: info.id)
    }

    func windowTitleChanged(_ id: UInt32, title: String) {
        windowTitlesSeen[id] = title
        if let program = program(forWindow: id) { sendUpdate(program) }
    }

    func appIdArrived(windowId: UInt32, imageName: String, applicationId: String) {
        let key = (applicationId.isEmpty ? imageName : applicationId).lowercased()
        guard !key.isEmpty else { return }
        // Our own hidden helper (keep-alive window) is not a program the user opened.
        let image = imageName.lowercased()
        if image.hasSuffix("\\powershell.exe") || image.hasSuffix("\\conhost.exe") { return }
        if programs[key] == nil {
            let app = catalogApp(imageName: imageName, applicationId: applicationId)
            let name = app?.name.trimmingCharacters(in: .whitespaces)
                ?? fallbackName(imageName: imageName, applicationId: applicationId, title: windowTitlesSeen[windowId] ?? "")
            // The Start menu icon (96 px) is much sharper than the window icon the server sends.
            programs[key] = RemoteProgram(key: key, name: name, icon: app.flatMap { icons.cgImage(for: $0) },
                                          appID: app?.appID)
        }
        assign(windowId, to: key)
        for (owned, owner) in pendingOwned where owner == windowId {
            pendingOwned[owned] = nil
            assign(owned, to: key)
        }
    }

    func iconArrived(windowId: UInt32, icon: CGImage) {
        if let current = windowIcons[windowId], current.width >= icon.width { return }
        windowIcons[windowId] = icon
        guard let key = windowProgram[windowId], var program = programs[key] else { return }
        if program.icon == nil || program.icon!.width < icon.width {
            program.icon = icon
            programs[key] = program
            syncProxy(program)
        }
    }

    /// A window of some program appeared or disappeared on screen.
    func presenceChanged(_ windowId: UInt32) {
        if let program = program(forWindow: windowId) {
            syncProxy(program)
        }
    }

    func windowRemoved(_ id: UInt32) {
        windowIcons[id] = nil
        windowTitlesSeen[id] = nil
        requested.remove(id)
        pendingOwned[id] = nil
        guard let key = windowProgram.removeValue(forKey: id), var program = programs[key] else { return }
        program.windowIds.remove(id)
        if program.windowIds.isEmpty {
            programs[key] = nil
            proxies.quit(key)
        } else {
            programs[key] = program
            sendUpdate(program)
        }
    }

    /// Connection ended: every proxy goes away.
    func reset() {
        programs.removeAll()
        windowProgram.removeAll()
        windowIcons.removeAll()
        windowTitlesSeen.removeAll()
        pendingOwned.removeAll()
        requested.removeAll()
        proxies.quitAll()
    }

    private func assign(_ windowId: UInt32, to key: String) {
        guard var program = programs[key] else { return }
        windowProgram[windowId] = key
        program.windowIds.insert(windowId)
        if let icon = windowIcons[windowId], program.icon == nil || program.icon!.width < icon.width {
            program.icon = icon
        }
        programs[key] = program
        syncProxy(program)
    }

    /// The Dock icon exists only while the program has a window on screen: a program that hid
    /// itself to the tray (KakaoTalk's X) leaves the Dock, like a Mac app with no windows would quit.
    private func syncProxy(_ program: RemoteProgram) {
        if program.windowIds.contains(where: { isPresent?($0) ?? true }) {
            proxies.show(program)
            sendUpdate(program)
        } else {
            proxies.quit(program.key)
        }
    }

    private func sendUpdate(_ program: RemoteProgram) {
        proxies.update(program, windows: windowTitles?(program) ?? [])
    }

    /// The Start menu entry for a program, matched by AppUserModelID, then by exe file name.
    private func catalogApp(imageName: String, applicationId: String) -> RemoteApp? {
        let apps = catalog.apps
        if !applicationId.isEmpty,
           let app = apps.first(where: { $0.appID.caseInsensitiveCompare(applicationId) == .orderedSame }) {
            return app
        }
        let exe = Self.fileName(imageName.isEmpty ? applicationId : imageName)
        guard !exe.isEmpty else { return nil }
        return apps.first { Self.fileName($0.appID).caseInsensitiveCompare(exe) == .orderedSame }
    }

    /// Without a Start menu match: the exe name, else the window title.
    private func fallbackName(imageName: String, applicationId: String, title: String) -> String {
        let exe = Self.fileName(imageName.isEmpty ? applicationId : imageName)
        let base = exe.lowercased().hasSuffix(".exe") ? String(exe.dropLast(4)) : exe
        if !base.isEmpty { return base }
        return title.isEmpty ? "Windows 앱" : title
    }

    private static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
    }
}

/// Creates, launches and talks to the small per-program .app bundles that give each remote
/// program its own Dock icon. The windows themselves stay in the agent.
final class DockProxyController {
    static let appsFolder = AppCatalog.supportFolder.appendingPathComponent("Apps", isDirectory: true)
    private let center = DistributedNotificationCenter.default()
    private var launched = Set<String>()
    private var iconWritten: [String: Int] = [:] // key -> icon width written

    func show(_ program: RemoteProgram) {
        guard let bundle = ensureBundle(for: program) else { return }
        writeIconIfBetter(program, bundle: bundle)
        guard !launched.contains(program.key) else { return }
        launched.insert(program.key)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            if let error {
                FileHandle.standardError.write(Data("[pstsc] Dock proxy failed to launch: \(error)\n".utf8))
            }
        }
    }

    func update(_ program: RemoteProgram, windows: [(UInt32, String)]) {
        guard launched.contains(program.key) else { return }
        var info: [String: Any] = [
            "titles": windows.map { $0.1 },
            "ids": windows.map { Int($0.0) },
            "agentPID": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        if let bundle = bundleURL(for: program) {
            info["iconPath"] = bundle.appendingPathComponent("Contents/Resources/icon.png").path
        }
        center.postNotificationName(DockMessage.update, object: program.key, userInfo: info, deliverImmediately: true)
    }

    func quit(_ key: String) {
        launched.remove(key)
        center.postNotificationName(DockMessage.quit, object: key, userInfo: nil, deliverImmediately: true)
    }

    func quitAll() {
        launched.removeAll()
        center.postNotificationName(DockMessage.quitAll, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Bundles

    private func bundleURL(for program: RemoteProgram) -> URL? {
        let safe = program.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !safe.isEmpty else { return nil }
        return Self.appsFolder.appendingPathComponent("\(safe).app", isDirectory: true)
    }

    /// ~/Library/Application Support/Pstsc/Apps/<Name>.app with a copy of PstscDockProxy inside.
    private func ensureBundle(for program: RemoteProgram) -> URL? {
        guard let bundle = bundleURL(for: program),
              let source = Bundle.main.executableURL?.resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("PstscDockProxy") else { return nil }
        let fm = FileManager.default
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let executable = macOS.appendingPathComponent("PstscDockProxy")
        do {
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)

            let plist: [String: Any] = [
                "CFBundleName": program.name,
                "CFBundleDisplayName": program.name,
                "CFBundleIdentifier": "com.pstsc.remote." + Self.shortHash(program.key),
                "CFBundleExecutable": "PstscDockProxy",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "NSHighResolutionCapable": true,
                "LSMinimumSystemVersion": "14.0",
                "PstscProgramKey": program.key,
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
            let plistChanged = (try? Data(contentsOf: plistURL)) != plistData
            if plistChanged { try plistData.write(to: plistURL) }

            let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let copyDate = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let binaryStale = copyDate == nil || (sourceDate.map { $0 > copyDate! } ?? false)
            if binaryStale {
                try? fm.removeItem(at: executable)
                try fm.copyItem(at: source, to: executable)
            }
            if plistChanged || binaryStale {
                Self.adHocSign(bundle)
            }
            return bundle
        } catch {
            FileHandle.standardError.write(Data("[pstsc] could not create a Dock proxy: \(error)\n".utf8))
            return nil
        }
    }

    private func writeIconIfBetter(_ program: RemoteProgram, bundle: URL) {
        guard let icon = program.icon, icon.width > (iconWritten[program.key] ?? 0),
              let png = Self.dockIconPNG(from: icon) else { return }
        try? png.write(to: bundle.appendingPathComponent("Contents/Resources/icon.png"))
        iconWritten[program.key] = icon.width
    }

    /// Windows icons are small (32–96 px); draw them big and smooth on a 512 px canvas.
    private static func dockIconPNG(from icon: CGImage) -> Data? {
        let size = 512
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = icon.width >= 64 ? .high : .medium
        let inset = CGFloat(size) * 0.1
        context.draw(icon, in: CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func shortHash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Bundles we assemble ourselves need a fresh (ad-hoc) signature to launch on Apple Silicon.
    private static func adHocSign(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
