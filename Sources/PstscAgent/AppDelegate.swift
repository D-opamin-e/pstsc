import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, RDPSessionDelegate, NSMenuDelegate,
    UNUserNotificationCenterDelegate {
    private enum Mode {
        /// Each remote window is its own Mac window (like Parallels Coherence).
        case apps
        /// The whole remote desktop in one Mac window.
        case desktop
    }

    /// One RDPSession per connection; callbacks from an older one are ignored.
    private var session: RDPSession?
    private var windowManager: RemoteWindowManager?
    private var desktopWindow: DesktopWindowController?
    private var mode: Mode = .apps
    private var ready = false
    /// Kept in memory only, so switching modes can reconnect without asking again.
    private var credentials: Credentials?
    /// App chosen while in desktop mode; launched once the RemoteApp connection is ready.
    private var pendingLaunch: RemoteApp?
    /// Save the password in the Keychain once it is proven right (first time the session is ready).
    private var rememberOnSuccess = false
    /// Whether these credentials ever got a working session; only then do we reconnect on our own.
    private var hasBeenReady = false
    /// Consecutive connections that logged off before the RemoteApp session ever became ready.
    /// Two in a row means the remote PC isn't set up for RemoteApp, not a transient drop.
    private var earlyLogoffs = 0
    private var reconnectAttempts = 0
    /// Set when the user signs out of / shuts down the remote PC from the power menu: no auto-reconnect.
    private var userEndedRemoteSession = false
    private var reconnectWork: DispatchWorkItem?

    private let connectWindow = ConnectWindowController()
    private let catalog = AppCatalog()
    private let appIcons = AppIconStore()
    private let startPrefs = StartMenuPrefs()
    private lazy var startMenu = StartMenuController(catalog: catalog, icons: appIcons, prefs: startPrefs)
    /// Groups remote windows by program and gives each program its own Dock icon.
    private lazy var programs = ProgramTracker(catalog: catalog, icons: appIcons)
    private let windowListMenu = NSMenu(title: L("창"))
    private var modeMenuItem: NSMenuItem?
    private var shareHomeItem: NSMenuItem?
    private var loginItemItem: NSMenuItem?
    private var autoConnectItem: NSMenuItem?
    private let launchers = LauncherController()

    private enum Pref {
        static let shareHome = "shareHomeFolder"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Pref.shareHome: true])
        NSApp.applicationIconImage = DockIcon.make()
        buildMenus()
        connectWindow.onConnect = { [weak self] credentials, remember in
            guard let self else { return }
            self.credentials = credentials
            self.rememberOnSuccess = remember
            self.hasBeenReady = false
            self.earlyLogoffs = 0
            if !remember {
                CredentialStore.forget(host: credentials.host, user: credentials.username)
            }
            self.updateToggleItems()
            self.connect(mode: .apps)
        }
        connectWindow.onConnectDesktop = { [weak self] in
            guard let self, self.credentials != nil else { return }
            self.connect(mode: .desktop)
        }
        catalog.onChange = { [weak self] in
            guard let self else { return }
            self.startMenu.reload()
            self.launchers.sync(apps: self.catalog.apps)
        }
        catalog.onIconsChange = { [weak self] in
            guard let self else { return }
            self.startMenu.reload()
            self.launchers.sync(apps: self.catalog.apps)
        }
        catalog.onIconsProgress = { [weak self] in self?.startMenu.reload() }
        startMenu.onLaunch = { [weak self] app in self?.launch(app) }
        startMenu.onPower = { [weak self] action in self?.perform(action) }
        setUpProgramDock()
        setUpNotifications()

        // Launchpad/Spotlight launchers ask a running Pstsc to start an app.
        DistributedNotificationCenter.default().addObserver(forName: .init("pstsc.agent.launch"), object: nil,
                                                            queue: .main) { [weak self] note in
            guard let appID = note.object as? String else { return }
            self?.launch(appID: appID)
        }
        // Fixed diagnostics request (no parameters): measure what Pstsc costs the remote PC.
        DistributedNotificationCenter.default().addObserver(forName: .init("pstsc.agent.resources"), object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.runResourceReport(showResult: false)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.reconnectAfterWake()
        }
        if !catalog.apps.isEmpty {
            launchers.sync(apps: catalog.apps)
        }

        // Started by a launcher while Pstsc was not running: run that app once connected.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--launch-app"), arguments.count > flag + 1 {
            pendingLaunch = remoteApp(forID: arguments[flag + 1])
        }

        if let saved = CredentialStore.savedForAutoConnect() {
            credentials = saved
            // These worked before: if the network is not up yet (e.g. right after Mac login), keep retrying.
            hasBeenReady = true
            connect(mode: .apps)
        } else {
            connectWindow.showWindow(nil)
            NSApp.activate()
        }
    }

    private func remoteApp(forID appID: String) -> RemoteApp {
        catalog.apps.first { $0.appID == appID } ?? RemoteApp(name: appID, appID: appID)
    }

    private func launch(appID: String) {
        launch(remoteApp(forID: appID))
    }

    // MARK: Notifications

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Balloon tips from remote tray icons appear as Mac notifications.
    func session(_ session: RDPSession, trayBalloonFrom windowId: UInt32, iconId: UInt32, title: String, text: String) {
        guard session === self.session else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Windows" : title
        content.body = text
        content.sound = .default
        content.userInfo = ["windowId": Int(windowId), "iconId": Int(iconId)]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the notification is the same as clicking the balloon on Windows.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let windowId = info["windowId"] as? Int, let iconId = info["iconId"] as? Int, let session {
            NSApp.activate()
            session.clickTrayBalloon(windowId: UInt32(windowId), iconId: UInt32(iconId))
            if let program = programs.program(forWindow: UInt32(windowId)) {
                windowManager?.bringToFront(windowIds: program.windowIds)
            }
        }
        completionHandler()
    }

    // MARK: Reconnecting

    /// Network drop or the PC went away: try again with growing pauses until it works.
    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let delays: [TimeInterval] = [2, 5, 10, 20, 30]
        let delay = reconnectAttempts < delays.count ? delays[reconnectAttempts] : 60
        reconnectAttempts += 1
        NSApp.dockTile.badgeLabel = "↻"
        FileHandle.standardError.write(Data("[pstsc] reconnecting in \(Int(delay))s (attempt \(reconnectAttempts))\n".utf8))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.credentials != nil, self.session == nil else { return }
            self.reconnectWork = nil
            self.connect(mode: self.mode)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopReconnecting() {
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAttempts = 0
        NSApp.dockTile.badgeLabel = nil
    }

    /// After sleep the old TCP connection is usually dead without FreeRDP noticing yet.
    private func reconnectAfterWake() {
        guard credentials != nil, hasBeenReady, session != nil || reconnectWork != nil else { return }
        FileHandle.standardError.write(Data("[pstsc] woke from sleep, reconnecting\n".utf8))
        stopReconnecting()
        tearDownSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.session == nil, self.credentials != nil else { return }
            self.connect(mode: self.mode)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.disconnect()
        programs.reset()
    }

    private func setUpProgramDock() {
        programs.windowTitles = { [weak self] program in
            program.windowIds.compactMap { self?.windowManager?.windows[$0] }
                .filter { !$0.info.isPopup && $0.hasBeenShown }
                .sorted { $0.info.title < $1.info.title }
                .map { ($0.remoteId, $0.info.title) }
        }
        programs.isPresent = { [weak self] id in self?.windowManager?.isPresent(id) ?? false }
        programs.onActivate = { [weak self] program, explicit in
            guard let self else { return }
            let shown = self.windowManager?.bringToFront(windowIds: program.windowIds) ?? false
            // Only in the tray: starting it again makes Windows programs show their main window.
            if !shown, explicit, let appID = program.appID {
                self.launch(appID: appID)
            }
        }
        programs.onClose = { [weak self] program in
            guard let self, let session = self.session, let manager = self.windowManager else { return }
            for id in program.windowIds {
                guard let window = manager.windows[id], window.info.ownerId == 0, !window.info.isPopup else { continue }
                session.command(windowId: id, RDPSession.commandClose)
            }
        }
        programs.onFocusWindow = { [weak self] id in
            guard let window = self?.windowManager?.windows[id] else { return }
            self?.windowManager?.bringToFront(window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillResignActive(_ notification: Notification) {
        KeyboardBridge.shared.releaseAll()
    }

    /// Clicking the Dock icon opens the Windows Start panel, like Parallels' Windows button.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindowsStart()
        return false
    }

    /// Like Parallels' Windows Dock icon: opens the Start menu. In app mode that is our Windows 11
    /// look-alike (RemoteApp never shows the real one); in desktop mode the real one.
    @objc private func openWindowsStart() {
        guard let session else {
            showConnectWindow()
            return
        }
        if mode == .desktop {
            NSApp.activate()
            desktopWindow?.present()
            session.pressWindowsKey()
            return
        }
        startMenu.userName = credentials?.username ?? ""
        startMenu.isDesktopMode = false
        startMenu.toggle()
    }

    private func perform(_ action: StartMenuController.PowerAction) {
        switch action {
        case .toggleDesktop:
            toggleMode()
        case .disconnect:
            disconnect()
        case .signOut:
            confirmRemote(L("원격 PC에서 로그아웃할까요?"), detail: L("열려 있는 원격 프로그램이 모두 닫힙니다."),
                          program: #"C:\Windows\System32\logoff.exe"#, arguments: "", staysDisconnected: true)
        case .restart:
            confirmRemote(L("원격 PC를 다시 시작할까요?"), detail: L("열려 있는 원격 프로그램이 모두 닫히고 연결이 끊깁니다."),
                          program: #"C:\Windows\System32\shutdown.exe"#, arguments: "/r /t 0")
        case .shutDown:
            confirmRemote(L("원격 PC를 끌까요?"), detail: L("다시 켜기 전까지 원격 PC에 연결할 수 없습니다."),
                          program: #"C:\Windows\System32\shutdown.exe"#, arguments: "/s /t 0", staysDisconnected: true)
        }
    }

    private func confirmRemote(_ question: String, detail: String, program: String, arguments: String,
                               staysDisconnected: Bool = false) {
        guard let session, ready else { return }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: L("확인"))
        alert.addButton(withTitle: L("취소"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        userEndedRemoteSession = staysDisconnected
        session.launch(program: program, arguments: arguments)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        guard session != nil else {
            if reconnectWork != nil {
                menu.addItem(withTitle: L("다시 연결하는 중… (취소)"), action: #selector(disconnect), keyEquivalent: "")
            }
            menu.addItem(withTitle: L("원격 PC 연결…"), action: #selector(showConnectWindow), keyEquivalent: "")
            return menu
        }
        menu.addItem(withTitle: L("Windows 시작"), action: #selector(openWindowsStart), keyEquivalent: "")
        menu.addItem(withTitle: mode == .apps ? L("Windows 데스크톱 보기") : L("앱 창 모드로 돌아가기"),
                     action: #selector(toggleMode), keyEquivalent: "")
        if let windows = windowManager?.appWindows, !windows.isEmpty {
            menu.addItem(.separator())
            for window in windows {
                let item = NSMenuItem(title: window.info.title.isEmpty ? L("(제목 없음)") : window.info.title,
                                      action: #selector(showRemoteWindow(_:)), keyEquivalent: "")
                item.representedObject = window
                menu.addItem(item)
            }
        }
        return menu
    }

    // MARK: Connection

    private func connect(mode newMode: Mode) {
        guard let credentials, let screen = NSScreen.screens.first else { return }
        tearDownSession()
        // Switch the Start menu to this PC: show its cached apps (or none), never the last PC's.
        catalog.beginConnection(host: credentials.host)
        mode = newMode
        ready = false

        let session = RDPSession()
        session.delegate = self
        self.session = session

        var options: RDPSession.Options
        switch newMode {
        case .apps:
            // The remote desktop mirrors the primary screen; windows may maximize into its visible part.
            let frame = screen.frame
            let visible = screen.visibleFrame
            let workArea = CGRect(x: visible.minX - frame.minX, y: frame.maxY - visible.maxY,
                                  width: visible.width, height: visible.height)
            // Every Mac display in Windows coordinates (top-left origin, primary at 0,0) so remote
            // windows can be dragged between displays.
            let monitors = NSScreen.screens.map { s in
                CGRect(x: s.frame.minX - frame.minX, y: frame.maxY - s.frame.maxY,
                       width: s.frame.width, height: s.frame.height)
            }
            let bounds = monitors.reduce(CGRect.null) { $0.union($1) }
            options = RDPSession.Options(host: credentials.host, username: credentials.username,
                                         password: credentials.password, desktopSize: bounds.size, workArea: workArea)
            options.monitors = monitors
            options.remoteApp = true
            // First program: the hidden helper that exports the Start menu and keeps the session alive.
            AppCatalog.prepareHelper()
            options.program = AppCatalog.helperProgram
            options.programArguments = AppCatalog.helperArguments
            let manager = RemoteWindowManager(session: session)
            manager.onFirstShown = { [weak self, weak session] window in
                guard let self, let session else { return }
                self.programs.windowShown(window, session: session)
            }
            manager.onTitleChanged = { [weak self] id, title in self?.programs.windowTitleChanged(id, title: title) }
            manager.onRemoved = { [weak self] id in self?.programs.windowRemoved(id) }
            manager.onPresenceChanged = { [weak self] id in self?.programs.presenceChanged(id) }
            windowManager = manager
        case .desktop:
            let size = DesktopWindowController.desktopSize(for: screen)
            options = RDPSession.Options(host: credentials.host, username: credentials.username,
                                         password: credentials.password, desktopSize: size,
                                         workArea: CGRect(origin: .zero, size: size))
            options.remoteApp = false
            let desktop = DesktopWindowController(session: session, desktopSize: size)
            desktop.onClose = { [weak self] in
                // Closing the desktop window goes back to app mode rather than disconnecting.
                guard let self, self.mode == .desktop, self.desktopWindow === desktop else { return }
                self.connect(mode: .apps)
            }
            desktopWindow = desktop
        }
        options.sharedFolder = AppCatalog.sharedFolder.path
        if UserDefaults.standard.bool(forKey: Pref.shareHome) {
            // Shows up in the remote Explorer as "Mac" (\\tsclient\Mac) for exchanging files.
            options.userDriveName = "Mac"
            options.userDrivePath = FileManager.default.homeDirectoryForCurrentUser.path
        }

        connectWindow.setBusy(true, status: L("연결 중…"))
        updateModeMenuTitle()
        if !session.connect(options) {
            tearDownSession()
            connectWindow.setBusy(false, status: L("연결 설정을 만들지 못했습니다. 주소 형식을 확인하세요."))
            connectWindow.showWindow(nil)
        }
    }

    private func tearDownSession() {
        let old = session
        session = nil
        old?.delegate = nil
        old?.disconnect()
        windowManager?.removeAll()
        windowManager = nil
        programs.reset()
        if let desktop = desktopWindow {
            desktopWindow = nil
            desktop.onClose = nil
            desktop.close()
        }
    }

    @objc private func toggleMode() {
        connect(mode: mode == .apps ? .desktop : .apps)
    }

    private func launch(_ app: RemoteApp) {
        if mode == .apps, ready, let session {
            session.launch(appID: app.appID)
        } else {
            pendingLaunch = app
            if credentials == nil {
                showConnectWindow()
            } else if mode == .desktop || (session == nil && reconnectWork == nil) {
                connect(mode: .apps)
            }
        }
    }

    // MARK: RDPSessionDelegate

    func sessionDidConnect(_ session: RDPSession) {
        guard session === self.session else { return }
        connectWindow.setBusy(false, status: L("연결됨"))
        connectWindow.window?.orderOut(nil)
        if mode == .desktop {
            desktopWindow?.present()
        }
    }

    func sessionFoundOtherUserSignedIn(_ session: RDPSession) {
        guard session === self.session else { return }
        // In desktop mode the remote console shows the "take over this session?" prompt and the
        // connection proceeds once answered, so let it continue.
        guard mode == .apps else { return }
        // Apps-mode (RemoteApp) has no screen to show the "take over this session?" prompt, so the
        // server just refuses. Offer desktop mode, which does show that prompt and can take over.
        stopReconnecting()
        tearDownSession()
        connectWindow.offerDesktopMode(status: L("원격 PC가 이미 사용 중입니다(다른 사용자이거나, PC 앞에서 로그인한 같은 계정). 앱 창 모드로는 연결할 수 없습니다. 데스크톱 모드로 접속하면 그 세션을 넘겨받을 수 있습니다. 넘겨받으면 원격 PC는 잠깁니다."))
        connectWindow.showWindow(nil)
        NSApp.activate()
    }

    func sessionDidBecomeReady(_ session: RDPSession) {
        guard session === self.session else { return }
        ready = true
        hasBeenReady = true
        earlyLogoffs = 0
        stopReconnecting()
        if rememberOnSuccess, let credentials {
            CredentialStore.remember(credentials)
            rememberOnSuccess = false
            updateToggleItems()
        }
        catalog.watchForExport()
        if let app = pendingLaunch {
            pendingLaunch = nil
            session.launch(appID: app.appID)
        }
    }

    func session(_ session: RDPSession, didDisconnect reason: RDPSession.DropReason, message: String?) {
        guard session === self.session else { return }
        tearDownSession()
        FileHandle.standardError.write(Data("[pstsc] disconnected: \(reason) \(message ?? "")\n".utf8))

        // A logoff before this connection ever became ready (not reset by a successful ready) means
        // the RemoteApp session can't start. Twice in a row = the remote PC isn't set up for
        // RemoteApp (enable-remoteapp.reg not applied, or applied without a restart); stop looping.
        if reason == .loggedOff && !ready && mode == .apps && !userEndedRemoteSession {
            earlyLogoffs += 1
            if earlyLogoffs >= 2 {
                earlyLogoffs = 0
                stopReconnecting()
                pendingLaunch = nil
                connectWindow.setBusy(false, status: L("이 원격 PC는 아직 Pstsc 연결 준비가 되어 있지 않습니다. 저장소의 enable-remoteapp.reg를 원격 PC에서 실행하고 재시작한 뒤 다시 연결하세요."))
                connectWindow.showWindow(nil)
                NSApp.activate()
                return
            }
        }

        switch reason {
        case .loggedOff where credentials != nil && !userEndedRemoteSession:
            // Windows ended the remote session (e.g. timed out): start a fresh one quietly.
            scheduleReconnect()
            return
        case .network where hasBeenReady && credentials != nil:
            // Keep the pending app: it runs once we are back.
            scheduleReconnect()
            return
        case .credentials:
            if let credentials {
                CredentialStore.forget(host: credentials.host, user: credentials.username)
            }
            credentials = nil
            updateToggleItems()
            connectWindow.setBusy(false, status: L("비밀번호 또는 계정을 확인하세요.") + (message.map { " (\($0))" } ?? ""))
        default:
            connectWindow.setBusy(false, status: message.map { L("연결 끊김: %@", $0) } ?? L("연결이 끊겼습니다."))
        }
        stopReconnecting()
        pendingLaunch = nil
        userEndedRemoteSession = false
        connectWindow.showWindow(nil)
        NSApp.activate()
    }

    func session(_ session: RDPSession, windowChanged info: RemoteWindowInfo) {
        guard session === self.session else { return }
        windowManager?.apply(info)
    }

    func session(_ session: RDPSession, windowRemoved id: UInt32) {
        guard session === self.session else { return }
        windowManager?.remove(id)
    }

    func session(_ session: RDPSession, framesChangedIn rect: CGRect, windowIds: Set<UInt32>) {
        guard session === self.session else { return }
        if mode == .desktop {
            desktopWindow?.refresh()
        } else {
            windowManager?.refresh(rect, windowIds: windowIds)
        }
    }

    func session(_ session: RDPSession, failedToLaunch program: String, code: UInt16) {
        guard session === self.session else { return }

        // The helper (conhost.exe) failing means the remote PC isn't set up for RemoteApp; a
        // user-launched program failing is usually a bad path. Code 3 = not in the allow list.
        let isHelper = program.lowercased().contains("conhost.exe")
        if isHelper {
            tearDownSession()
            connectWindow.setBusy(false, status: L("이 원격 PC는 아직 Pstsc 연결 준비가 되어 있지 않습니다. 저장소의 enable-remoteapp.reg를 원격 PC에서 실행하고 재시작한 뒤 다시 연결하세요."))
            connectWindow.showWindow(nil)
            NSApp.activate()
            return
        }

        let reason: String
        switch code {
        case 3: reason = L("원격 PC에서 RemoteApp이 허용되어 있지 않습니다. enable-remoteapp.reg를 적용하세요.")
        case 5: reason = L("원격 PC에서 그 경로의 프로그램을 찾지 못했습니다.")
        default: reason = L("원격 PC에서 RemoteApp 허용 설정과 프로그램 경로를 확인하세요.")
        }
        let alert = NSAlert()
        alert.messageText = L("프로그램을 실행하지 못했습니다")
        alert.informativeText = L("%@\n오류 코드: %d\n%@", program, Int32(code), reason)
        alert.runModal()
    }

    func session(_ session: RDPSession, localMoveSizeStartedFor windowId: UInt32, type: UInt16) {
        guard session === self.session else { return }
        windowManager?.beginLocalMoveSize(windowId: windowId, type: type)
    }

    func session(_ session: RDPSession, windowId: UInt32, icon: CGImage) {
        guard session === self.session else { return }
        programs.iconArrived(windowId: windowId, icon: icon)
    }

    func session(_ session: RDPSession, windowId: UInt32, imageName: String, applicationId: String) {
        guard session === self.session else { return }
        programs.appIdArrived(windowId: windowId, imageName: imageName, applicationId: applicationId)
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Windows 시작"), action: #selector(openWindowsStart), keyEquivalent: "")
        let modeItem = appMenu.addItem(withTitle: L("Windows 데스크톱 보기"), action: #selector(toggleMode), keyEquivalent: "")
        modeMenuItem = modeItem
        appMenu.addItem(withTitle: L("경로로 원격 프로그램 실행…"), action: #selector(launchProgramByPath), keyEquivalent: "")
        appMenu.addItem(.separator())
        shareHomeItem = appMenu.addItem(withTitle: L("Mac 홈 폴더를 원격 PC와 공유 ('Mac' 드라이브)"),
                                        action: #selector(toggleShareHome), keyEquivalent: "")
        autoConnectItem = appMenu.addItem(withTitle: L("실행하면 자동 연결 (키체인에 저장)"),
                                          action: #selector(toggleAutoConnect), keyEquivalent: "")
        loginItemItem = appMenu.addItem(withTitle: L("로그인 시 Pstsc 열기"), action: #selector(toggleLoginItem), keyEquivalent: "")
        appMenu.addItem(withTitle: L("Launchpad 앱 폴더 열기"), action: #selector(openLaunchersFolder), keyEquivalent: "")
        appMenu.addItem(withTitle: L("원격 PC 리소스 사용량…"), action: #selector(showRemoteResources), keyEquivalent: "")
        updateToggleItems()
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("연결 끊기"), action: #selector(disconnect), keyEquivalent: "")
        appMenu.addItem(withTitle: L("Pstsc 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard edit commands for the connect window's text fields. Remote windows take
        // Command shortcuts before the menu sees them (RemoteContentView.performKeyEquivalent).
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("편집"))
        editMenu.addItem(withTitle: L("잘라내기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("복사"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        windowListMenu.delegate = self
        windowItem.submenu = windowListMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func updateToggleItems() {
        shareHomeItem?.state = UserDefaults.standard.bool(forKey: Pref.shareHome) ? .on : .off
        autoConnectItem?.state = UserDefaults.standard.bool(forKey: "autoConnect") ? .on : .off
        loginItemItem?.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleShareHome() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Pref.shareHome), forKey: Pref.shareHome)
        updateToggleItems()
        // Drives are announced at connect time: reconnect to apply.
        if session != nil {
            connect(mode: mode)
        }
    }

    @objc private func toggleAutoConnect() {
        if UserDefaults.standard.bool(forKey: "autoConnect") {
            let defaults = UserDefaults.standard
            CredentialStore.forget(host: defaults.string(forKey: "host") ?? "", user: defaults.string(forKey: "username") ?? "")
        } else if let credentials, hasBeenReady {
            CredentialStore.remember(credentials)
        } else {
            showConnectWindow()
        }
        updateToggleItems()
    }

    @objc private func toggleLoginItem() {
        if let error = LoginItem.setEnabled(!LoginItem.isEnabled) {
            let alert = NSAlert()
            alert.messageText = L("로그인 항목을 바꾸지 못했습니다")
            alert.informativeText = L("응용 프로그램 폴더의 Pstsc.app으로 실행했을 때만 설정할 수 있습니다.\n%@", error)
            alert.runModal()
        }
        updateToggleItems()
    }

    @objc private func showRemoteResources() {
        runResourceReport(showResult: true)
    }

    /// Runs the fixed resources.ps1 on the remote PC and logs (and optionally shows) its report.
    private func runResourceReport(showResult: Bool) {
        guard mode == .apps, ready, let session else {
            if showResult {
                let alert = NSAlert()
                alert.messageText = L("앱 창 모드로 연결된 상태에서만 측정할 수 있습니다.")
                alert.runModal()
            }
            return
        }
        AppCatalog.prepareHelper()
        let started = Date()
        session.launch(program: AppCatalog.helperProgram, arguments: AppCatalog.resourceArguments)
        var waited = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            waited += 1
            let file = AppCatalog.resourceReport
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= started, let report = try? String(contentsOf: file, encoding: .utf8) {
                timer.invalidate()
                if showResult { self?.showReport(report) }
            } else if waited >= 30 {
                timer.invalidate()
                FileHandle.standardError.write(Data("[pstsc] remote resource report did not arrive\n".utf8))
            }
        }
    }

    private func showReport(_ report: String) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        text.string = report
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        let alert = NSAlert()
        alert.messageText = L("원격 PC 리소스 사용량")
        alert.informativeText = L("Pstsc 연결 세션의 프로세스와 원격 데스크톱 서비스를 3초 동안 측정했습니다.")
        alert.accessoryView = scroll
        NSApp.activate()
        alert.runModal()
    }

    @objc private func openLaunchersFolder() {
        NSWorkspace.shared.open(LauncherController.folder)
    }

    private func updateModeMenuTitle() {
        modeMenuItem?.title = mode == .apps ? L("Windows 데스크톱 보기") : L("앱 창 모드로 돌아가기")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === windowListMenu else { return }
        menu.removeAllItems()
        let windows = windowManager?.appWindows ?? []
        if windows.isEmpty {
            menu.addItem(withTitle: L("열린 원격 창 없음"), action: nil, keyEquivalent: "")
        }
        for window in windows {
            let title = window.info.title.isEmpty ? L("(제목 없음)") : window.info.title
            let item = NSMenuItem(title: title, action: #selector(showRemoteWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window
            if window.info.showState == RemoteWindowInfo.showMinimized {
                item.title += L(" (최소화됨)")
            }
            menu.addItem(item)
        }
    }

    @objc private func showRemoteWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? RemoteAppWindow else { return }
        windowManager?.bringToFront(window)
    }

    @objc private func showConnectWindow() {
        connectWindow.showWindow(nil)
        NSApp.activate()
    }

    @objc private func launchProgramByPath() {
        guard mode == .apps, ready, let session else {
            openWindowsStart()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("원격 프로그램 실행")
        alert.informativeText = L("원격 PC에 있는 실행 파일의 전체 경로를 입력하세요.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = #"C:\Program Files\...\program.exe"#
        alert.accessoryView = field
        alert.addButton(withTitle: L("실행"))
        alert.addButton(withTitle: L("취소"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty {
            session.launch(program: path)
        }
    }

    @objc private func disconnect() {
        let wasReconnecting = reconnectWork != nil
        stopReconnecting()
        guard session != nil || wasReconnecting else { return }
        tearDownSession()
        pendingLaunch = nil
        connectWindow.setBusy(false, status: L("연결을 끊었습니다."))
        connectWindow.showWindow(nil)
    }
}
