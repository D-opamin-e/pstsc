import AppKit
import CryptoKit

/// Puts one small launcher app per remote Start menu entry into ~/Applications/Pstsc 앱/, so remote
/// programs show up in Launchpad and Spotlight like Parallels' "Windows Applications" folder.
/// A launcher is a copy of PstscDockProxy in launcher mode: it asks Pstsc to start the app
/// (opening Pstsc first if needed) and quits.
final class LauncherController {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Pstsc 앱", isDirectory: true)

    private let queue = DispatchQueue(label: "pstsc.launchers", qos: .utility)
    private var syncing = false
    private var syncAgain = false

    /// Uninstallers, help files and web links would only clutter Launchpad.
    private static let skippedWords = ["uninstall", "제거", "アンインストール", "help", "도움말", "ヘルプ",
                                       "readme", "web site", "website", "웹 사이트", "홈페이지", "ホームページ",
                                       "documentation", "license"]

    /// Creates missing launchers, refreshes their icons and removes ones whose app is gone.
    /// Runs in the background; calls made while a sync is running are folded into one more pass.
    func sync(apps: [RemoteApp]) {
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        let wanted = apps.filter { app in
            let name = app.name.lowercased()
            return !Self.skippedWords.contains { name.contains($0) }
        }
        guard let proxy = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("PstscDockProxy") else { return }

        queue.async {
            let count = Self.sync(wanted, proxy: proxy)
            DispatchQueue.main.async {
                FileHandle.standardError.write(Data("[pstsc] launchers up to date (\(count) apps)\n".utf8))
                self.syncing = false
                if self.syncAgain {
                    self.syncAgain = false
                    self.sync(apps: apps)
                }
            }
        }
    }

    private static func sync(_ apps: [RemoteApp], proxy: URL) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let proxyDate = (try? proxy.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        var keep = Set<String>()
        var usedNames = Set<String>()
        for app in apps {
            var name = app.name.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            guard !name.isEmpty else { continue }
            if usedNames.contains(name.lowercased()) { name += " (\(shortHash(app.appID).prefix(4)))" }
            usedNames.insert(name.lowercased())
            let bundle = folder.appendingPathComponent("\(name).app", isDirectory: true)
            keep.insert(bundle.lastPathComponent)
            update(bundle, for: app, name: name, proxy: proxy, proxyDate: proxyDate)
        }

        // Launchers for apps that left the remote Start menu.
        let existing = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for item in existing where item.hasSuffix(".app") && !keep.contains(item) {
            try? fm.removeItem(at: folder.appendingPathComponent(item))
        }
        return keep.count
    }

    private static func update(_ bundle: URL, for app: RemoteApp, name: String, proxy: URL, proxyDate: Date?) {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let executable = macOS.appendingPathComponent("PstscDockProxy")
        let icns = resources.appendingPathComponent("AppIcon.icns")
        let iconPNG = AppCatalog.sharedFolder.appendingPathComponent("icons/\(md5(app.appID)).png")
        do {
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            var changed = false

            let plist: [String: Any] = [
                "CFBundleName": name,
                "CFBundleDisplayName": name,
                "CFBundleIdentifier": "com.pstsc.launch." + shortHash(app.appID),
                "CFBundleExecutable": "PstscDockProxy",
                "CFBundleIconFile": "AppIcon",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "LSMinimumSystemVersion": "14.0",
                "LSUIElement": true, // hands off to Pstsc and quits; no Dock icon of its own
                "PstscLaunchAppID": app.appID,
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let plistURL = contents.appendingPathComponent("Info.plist")
            if (try? Data(contentsOf: plistURL)) != plistData {
                try plistData.write(to: plistURL)
                changed = true
            }

            let copyDate = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if copyDate == nil || (proxyDate.map { $0 > copyDate! } ?? false) {
                try? fm.removeItem(at: executable)
                try fm.copyItem(at: proxy, to: executable)
                changed = true
            }

            let pngDate = (try? iconPNG.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let icnsDate = (try? icns.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let pngDate, icnsDate == nil || pngDate > icnsDate!, makeICNS(from: iconPNG, to: icns) {
                changed = true
            }

            if changed {
                run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
                // Tell Finder/Launchpad the bundle (and its icon) changed.
                run("/usr/bin/touch", [bundle.path])
            }
        } catch {
            FileHandle.standardError.write(Data("[pstsc] creating a launcher failed: \(error)\n".utf8))
        }
    }

    /// Windows icons arrive as 96 px PNGs; scale them into an .iconset and let iconutil pack it.
    private static func makeICNS(from png: URL, to icns: URL) -> Bool {
        guard let image = NSImage(contentsOf: png) else { return false }
        let iconset = FileManager.default.temporaryDirectory
            .appendingPathComponent("pstsc-\(UUID().uuidString).iconset", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                // Mac icons leave a margin around the artwork.
                let inset = CGFloat(pixels) * 0.1
                image.draw(in: NSRect(x: inset, y: inset, width: CGFloat(pixels) - 2 * inset, height: CGFloat(pixels) - 2 * inset))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: iconset.appendingPathComponent(name))
            }
        }
        return run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path]) == 0
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
