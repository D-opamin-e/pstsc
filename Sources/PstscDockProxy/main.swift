import AppKit

/// Gives one remote Windows program its own Dock icon. The program's windows are drawn by the
/// Pstsc agent; this app only relays Dock clicks, its Dock menu and Quit to the agent.
/// Message names must match DockMessage in Sources/PstscAgent/ProgramDock.swift.
final class ProxyDelegate: NSObject, NSApplicationDelegate {
    private let key = Bundle.main.object(forInfoDictionaryKey: "PstscProgramKey") as? String ?? ""
    private let center = DistributedNotificationCenter.default()
    private var windows: [(id: Int, title: String)] = []
    private var agentPID: pid_t = 0
    private var quitRequestedByAgent = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadIcon(Bundle.main.url(forResource: "icon", withExtension: "png")?.path)

        center.addObserver(forName: .init("pstsc.proxy.update"), object: key, queue: .main) { [weak self] note in
            self?.applyUpdate(note.userInfo ?? [:])
        }
        center.addObserver(forName: .init("pstsc.proxy.quit"), object: key, queue: .main) { [weak self] _ in
            self?.quitNow()
        }
        center.addObserver(forName: .init("pstsc.proxy.quitAll"), object: nil, queue: .main) { [weak self] _ in
            self?.quitNow()
        }
        post("pstsc.agent.hello")
    }

    /// Cmd+Tab to the program, or macOS activating us on its own when another app's window closed:
    /// bring forward windows that are open, but never start the program again.
    func applicationDidBecomeActive(_ notification: Notification) {
        handOverToAgent(explicit: false)
    }

    /// A click on the Dock icon: may also start the program again when it only sits in the tray.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        handOverToAgent(explicit: true)
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for window in windows {
            let item = NSMenuItem(title: window.title.isEmpty ? "(제목 없음)" : window.title,
                                  action: #selector(focusWindow(_:)), keyEquivalent: "")
            item.target = self
            item.tag = window.id
            menu.addItem(item)
        }
        return menu
    }

    /// Quit from the Dock asks the remote program to close; we exit once the agent reports it gone,
    /// so a "save changes?" prompt on the Windows side can still be answered.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitRequestedByAgent || agentPID == 0 || NSRunningApplication(processIdentifier: agentPID) == nil {
            return .terminateNow
        }
        post("pstsc.agent.close")
        return .terminateCancel
    }

    @objc private func focusWindow(_ sender: NSMenuItem) {
        yieldToAgent()
        center.postNotificationName(.init("pstsc.agent.focusWindow"), object: key,
                                    userInfo: ["id": sender.tag], deliverImmediately: true)
    }

    private func applyUpdate(_ info: [AnyHashable: Any]) {
        let titles = info["titles"] as? [String] ?? []
        let ids = info["ids"] as? [Int] ?? []
        windows = zip(ids, titles).map { (id: $0, title: $1) }
        if let pid = info["agentPID"] as? Int { agentPID = pid_t(pid) }
        loadIcon(info["iconPath"] as? String)
    }

    private func loadIcon(_ path: String?) {
        guard let path, let image = NSImage(contentsOfFile: path) else { return }
        NSApp.applicationIconImage = image
    }

    private func handOverToAgent(explicit: Bool) {
        yieldToAgent()
        center.postNotificationName(.init("pstsc.agent.activate"), object: key,
                                    userInfo: ["explicit": explicit], deliverImmediately: true)
    }

    /// The agent owns the windows and needs to be the active app to receive the keyboard.
    private func yieldToAgent() {
        guard agentPID != 0, let agent = NSRunningApplication(processIdentifier: agentPID) else { return }
        NSApp.yieldActivation(to: agent)
        agent.activate()
    }

    private func post(_ name: String) {
        center.postNotificationName(.init(name), object: key, userInfo: nil, deliverImmediately: true)
    }

    private func quitNow() {
        quitRequestedByAgent = true
        NSApp.terminate(nil)
    }
}

/// Launcher mode (bundles in ~/Applications/Pstsc 앱, made for Launchpad/Spotlight): ask Pstsc to
/// start the remote app, opening Pstsc first if it is not running, then quit right away.
if let appID = Bundle.main.object(forInfoDictionaryKey: "PstscLaunchAppID") as? String {
    let agentID = "com.pstsc.agent"
    if !NSRunningApplication.runningApplications(withBundleIdentifier: agentID).isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            .init("pstsc.agent.launch"), object: appID, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    guard let pstsc = NSWorkspace.shared.urlForApplication(withBundleIdentifier: agentID) else { exit(1) }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ["--launch-app", appID]
    let opened = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: pstsc, configuration: configuration) { _, _ in opened.signal() }
    _ = opened.wait(timeout: .now() + 15)
    exit(0)
}

let app = NSApplication.shared
let delegate = ProxyDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
