import AppKit
import CryptoKit

/// Icons of the remote Start menu apps, exported by the helper as icons/<md5 of AppID>.png.
final class AppIconStore {
    private static let folder = AppCatalog.sharedFolder.appendingPathComponent("icons", isDirectory: true)
    private var cache: [String: NSImage] = [:]
    private lazy var placeholder: NSImage = {
        let image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// The app's icon, or a neutral placeholder while it has not arrived yet.
    func icon(for app: RemoteApp) -> NSImage {
        if let cached = cache[app.appID] { return cached }
        guard let image = NSImage(contentsOf: Self.file(for: app)) else { return placeholder }
        cache[app.appID] = image
        return image
    }

    func cgImage(for app: RemoteApp) -> CGImage? {
        guard FileManager.default.fileExists(atPath: Self.file(for: app).path) else { return nil }
        return icon(for: app).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func file(for app: RemoteApp) -> URL {
        let hash = Insecure.MD5.hash(data: Data(app.appID.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(hash).png")
    }
}

/// Pinned and recently launched apps of the Start menu, kept in UserDefaults by AppID.
final class StartMenuPrefs {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let pinned = "startPinnedAppIDs"
        static let recent = "startRecentAppIDs"
    }

    /// Typical Windows 11 pins, used until the user pins something themselves. These are the
    /// remote PC's Start menu names, so Korean, English and Japanese Windows are all listed.
    private static let defaultPinNames = [
        "파일 탐색기", "File Explorer", "エクスプローラー",
        "설정", "Settings", "設定",
        "Microsoft Edge", "네이버 웨일", "Chrome", "Google Chrome", "카카오톡", "KakaoTalk", "LINE",
        "메모장", "Notepad", "メモ帳",
        "계산기", "Calculator", "電卓",
        "그림판", "Paint", "ペイント",
        "사진", "Photos", "フォト",
        "Microsoft Store", "Word", "Excel", "PowerPoint", "Outlook",
        "작업 관리자", "Task Manager", "タスク マネージャー",
        "명령 프롬프트", "Command Prompt", "コマンド プロンプト",
        "터미널", "Terminal", "ターミナル",
    ]

    func pinned(in catalog: [RemoteApp]) -> [RemoteApp] {
        let byID = Dictionary(catalog.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        if let ids = defaults.stringArray(forKey: Key.pinned) {
            return ids.compactMap { byID[$0] }
        }
        var seen = Set<String>()
        return Self.defaultPinNames.compactMap { name in
            catalog.first { $0.name == name && seen.insert($0.appID).inserted }
        }.prefix(18).map { $0 }
    }

    func isPinned(_ app: RemoteApp, in catalog: [RemoteApp]) -> Bool {
        pinned(in: catalog).contains(app)
    }

    func togglePin(_ app: RemoteApp, in catalog: [RemoteApp]) {
        var ids = pinned(in: catalog).map(\.appID)
        if let index = ids.firstIndex(of: app.appID) {
            ids.remove(at: index)
        } else {
            ids.append(app.appID)
        }
        defaults.set(ids, forKey: Key.pinned)
    }

    func recent(in catalog: [RemoteApp]) -> [RemoteApp] {
        let byID = Dictionary(catalog.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        return (defaults.stringArray(forKey: Key.recent) ?? []).compactMap { byID[$0] }
    }

    func recordLaunch(_ app: RemoteApp) {
        var ids = defaults.stringArray(forKey: Key.recent) ?? []
        ids.removeAll { $0 == app.appID }
        ids.insert(app.appID, at: 0)
        defaults.set(Array(ids.prefix(6)), forKey: Key.recent)
    }
}
