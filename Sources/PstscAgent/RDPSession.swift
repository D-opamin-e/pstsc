import AppKit
import PstscRDP

/// One RemoteApp window as reported by the server. Coordinates are remote desktop pixels
/// (top-left origin), which map 1:1 to points on the primary Mac screen.
struct RemoteWindowInfo {
    let id: UInt32
    let ownerId: UInt32
    let style: UInt32
    let extendedStyle: UInt32
    let showState: UInt32
    let title: String
    /// Visible part of the window (invisible Windows resize borders removed).
    let frame: CGRect
    /// Top-left of the whole window, including the invisible borders. GFX surfaces start here.
    let origin: CGPoint
    /// Size of the whole window, including the invisible borders.
    let windowSize: CGSize

    /// The visible part in the window's own coordinates, i.e. where to crop its GFX surface.
    var surfaceCrop: CGRect { frame.offsetBy(dx: -origin.x, dy: -origin.y) }

    static let showHidden: UInt32 = 0
    static let showMinimized: UInt32 = 2

    private static let wsPopup: UInt32 = 0x8000_0000
    private static let wsCaption: UInt32 = 0x00C0_0000
    /// WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX: only real app windows have these.
    private static let wsAppFrame: UInt32 = 0x0008_0000 | 0x0004_0000 | 0x0002_0000 | 0x0001_0000
    private static let wsExToolWindow: UInt32 = 0x0000_0080
    private static let wsExAppWindow: UInt32 = 0x0004_0000
    private static let wsExLayered: UInt32 = 0x0008_0000

    /// Layered windows (menu drop shadows, fading popups) have per-pixel alpha; drawn opaque they
    /// turn into black boxes over the window below.
    var isLayered: Bool { extendedStyle & Self.wsExLayered != 0 }

    /// Menus, tooltips and similar: must never take focus or the remote closes them.
    /// Apps that draw their own title bar (KakaoTalk, Steam) are WS_POPUP too, but keep
    /// system-menu/resize/minimize styles or WS_EX_APPWINDOW, so those count as app windows.
    var isPopup: Bool {
        if extendedStyle & Self.wsExAppWindow != 0 { return false }
        if extendedStyle & Self.wsExToolWindow != 0 { return true }
        return style & Self.wsPopup != 0 && style & Self.wsCaption == 0 && style & Self.wsAppFrame == 0
    }
}

protocol RDPSessionDelegate: AnyObject {
    func sessionDidConnect(_ session: RDPSession)
    /// RemoteApp mode: programs can be launched from now on.
    func sessionDidBecomeReady(_ session: RDPSession)
    /// Another user is signed in on the remote PC (Windows Pro allows only one); the remote screen
    /// is asking them whether to let us in, and logon fails if nobody answers.
    func sessionFoundOtherUserSignedIn(_ session: RDPSession)
    func session(_ session: RDPSession, didDisconnect reason: RDPSession.DropReason, message: String?)
    /// A remote tray icon showed a balloon tip (shown as a Mac notification).
    func session(_ session: RDPSession, trayBalloonFrom windowId: UInt32, iconId: UInt32, title: String, text: String)
    func session(_ session: RDPSession, windowChanged info: RemoteWindowInfo)
    func session(_ session: RDPSession, windowRemoved id: UInt32)
    /// rect: changed part of the shared desktop framebuffer (legacy drawing, may be .null).
    /// windowIds: windows whose own GFX surface changed.
    func session(_ session: RDPSession, framesChangedIn rect: CGRect, windowIds: Set<UInt32>)
    func session(_ session: RDPSession, failedToLaunch program: String, code: UInt16)
    func session(_ session: RDPSession, windowId: UInt32, icon: CGImage)
    /// The user grabbed a window's title bar or border on the remote side: move/size it locally.
    func session(_ session: RDPSession, localMoveSizeStartedFor windowId: UInt32, type: UInt16)
    /// Which program owns a window (answer to requestAppId).
    func session(_ session: RDPSession, windowId: UInt32, imageName: String, applicationId: String)
}

/// Mirror of the remote framebuffer. Written on the RDP thread, read on the main thread.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: UnsafeMutableRawPointer?
    private var width = 0
    private var height = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    deinit { pixels?.deallocate() }

    func copy(from buffer: UnsafePointer<UInt8>, stride: Int, desktopWidth: Int, desktopHeight: Int, dirty: CGRect) {
        lock.lock()
        defer { lock.unlock() }

        if desktopWidth != width || desktopHeight != height {
            pixels?.deallocate()
            width = desktopWidth
            height = desktopHeight
            pixels = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
            copyRows(from: buffer, stride: stride, rect: CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            copyRows(from: buffer, stride: stride, rect: dirty)
        }
    }

    private func copyRows(from buffer: UnsafePointer<UInt8>, stride: Int, rect: CGRect) {
        guard let pixels else { return }
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty else { return }
        let rowBytes = Int(r.width) * 4
        for row in Int(r.minY)..<Int(r.maxY) {
            let src = buffer + row * stride + Int(r.minX) * 4
            let dst = pixels + row * width * 4 + Int(r.minX) * 4
            dst.copyMemory(from: src, byteCount: rowBytes)
        }
    }

    /// Copies the given desktop rectangle into a standalone image. alpha: the pixels carry per-pixel
    /// alpha (GFX ARGB surfaces of layered windows such as menu shadows); otherwise the 4th byte is unused.
    func image(of rect: CGRect, alpha: Bool = false) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        guard let pixels else { return nil }
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty else { return nil }

        let w = Int(r.width), h = Int(r.height)
        let rowBytes = w * 4
        var data = Data(count: rowBytes * h)
        data.withUnsafeMutableBytes { out in
            for row in 0..<h {
                let src = pixels + (Int(r.minY) + row) * width * 4 + Int(r.minX) * 4
                (out.baseAddress! + row * rowBytes).copyMemory(from: src, byteCount: rowBytes)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // FreeRDP BGRX32/BGRA32 == little-endian XRGB/ARGB
        let alphaInfo: CGImageAlphaInfo = alpha ? .first : .noneSkipFirst
        let info = CGBitmapInfo(rawValue: alphaInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: colorSpace, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Swift face of the C client. Delegate calls are always delivered on the main thread.
final class RDPSession {
    weak var delegate: RDPSessionDelegate?
    let frames = FrameStore()

    private var client: OpaquePointer?
    private let dirtyLock = NSLock()
    private var pendingDirty: CGRect = .null
    private var pendingWindows = Set<UInt32>()
    private var flushScheduled = false
    private let surfacesLock = NSLock()
    private var surfaces: [UInt32: FrameStore] = [:]

    /// Pixels of one window when the server uses the graphics pipeline (one surface per window).
    func surface(for windowId: UInt32) -> FrameStore? {
        surfacesLock.lock()
        defer { surfacesLock.unlock() }
        return surfaces[windowId]
    }

    func removeSurface(for windowId: UInt32) {
        surfacesLock.lock()
        surfaces[windowId] = nil
        surfacesLock.unlock()
    }

    private func surfaceStore(for windowId: UInt32) -> FrameStore {
        surfacesLock.lock()
        defer { surfacesLock.unlock() }
        if let store = surfaces[windowId] { return store }
        let store = FrameStore()
        surfaces[windowId] = store
        return store
    }

    struct Options {
        var host: String
        var username: String
        var password: String
        /// true: each remote window is its own Mac window; false: the whole remote desktop in one window.
        var remoteApp = true
        var program = ""
        var programArguments = ""
        /// Shown to the remote PC as \\tsclient\pstsc
        var sharedFolder = ""
        /// A Mac folder shown as a drive in the remote Explorer, for exchanging files.
        var userDriveName = ""
        var userDrivePath = ""
        var desktopSize: CGSize
        var workArea: CGRect
        /// Displays in Windows screen coordinates (primary first, at 0,0). More than one
        /// makes the remote desktop span all of them.
        var monitors: [CGRect] = []
    }

    /// Top-left of the remote virtual desktop in Windows screen coordinates. Window positions are
    /// relative to the primary display, but mouse input is relative to this corner, which is
    /// negative when a display sits left of or above the primary one.
    private var inputOrigin: CGPoint = .zero

    deinit { disconnect() }

    func connect(_ options: Options) -> Bool {
        disconnect()

        var callbacks = PstscCallbacks()
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        callbacks.stateChanged = { user, state, errorCode, message in
            let session = RDPSession.from(user)
            let text = message.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { session.handleState(state, errorCode: errorCode, message: text) }
        }
        callbacks.windowChanged = { user, info in
            guard let info else { return }
            let session = RDPSession.from(user)
            let window = RDPSession.makeWindowInfo(info.pointee)
            DispatchQueue.main.async { session.delegate?.session(session, windowChanged: window) }
        }
        callbacks.windowRemoved = { user, id in
            let session = RDPSession.from(user)
            DispatchQueue.main.async { session.delegate?.session(session, windowRemoved: id) }
        }
        callbacks.frameUpdated = { user, buffer, stride, desktopWidth, desktopHeight, x, y, width, height in
            guard let buffer else { return }
            let session = RDPSession.from(user)
            let dirty = CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
            session.frames.copy(from: buffer, stride: Int(stride), desktopWidth: Int(desktopWidth),
                                desktopHeight: Int(desktopHeight), dirty: dirty)
            session.scheduleFlush(dirty: dirty)
        }
        callbacks.windowIcon = { user, windowId, width, height, pixels in
            guard let pixels, let image = RDPSession.makeIcon(pixels, width: Int(width), height: Int(height)) else { return }
            let session = RDPSession.from(user)
            DispatchQueue.main.async { session.delegate?.session(session, windowId: windowId, icon: image) }
        }
        callbacks.trayBalloon = { user, windowId, iconId, title, text in
            let session = RDPSession.from(user)
            let title = title.map { String(cString: $0) } ?? ""
            let text = text.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                session.delegate?.session(session, trayBalloonFrom: windowId, iconId: iconId, title: title, text: text)
            }
        }
        callbacks.localMoveSize = { user, windowId, start, type in
            guard start else { return }
            let session = RDPSession.from(user)
            DispatchQueue.main.async {
                session.delegate?.session(session, localMoveSizeStartedFor: windowId, type: type)
            }
        }
        callbacks.windowAppId = { user, windowId, _, imageName, applicationId in
            let session = RDPSession.from(user)
            let image = imageName.map { String(cString: $0) } ?? ""
            let appId = applicationId.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                session.delegate?.session(session, windowId: windowId, imageName: image, applicationId: appId)
            }
        }
        callbacks.windowSurfaceUpdated = { user, windowId, buffer, stride, surfaceWidth, surfaceHeight, x, y, width, height in
            guard let buffer else { return }
            let session = RDPSession.from(user)
            let dirty = CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
            session.surfaceStore(for: windowId).copy(from: buffer, stride: Int(stride), desktopWidth: Int(surfaceWidth),
                                                     desktopHeight: Int(surfaceHeight), dirty: dirty)
            session.scheduleFlush(windowId: windowId)
        }
        callbacks.execResult = { user, result, _, program in
            guard result != 0 else { return }
            let session = RDPSession.from(user)
            let name = program.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { session.delegate?.session(session, failedToLaunch: name, code: result) }
        }

        guard let client = pstsc_client_new(callbacks) else { return false }
        self.client = client

        // strdup'd copies stay valid for the whole start call; the C side copies what it keeps.
        let strings = [options.host, options.username, options.password, options.program,
                       options.programArguments, options.sharedFolder,
                       options.userDriveName, options.userDrivePath].map { strdup($0) }
        defer {
            if let password = strings[2] { memset(password, 0, strlen(password)) }
            strings.forEach { free($0) }
        }
        var opts = PstscConnectOptions()
        opts.host = UnsafePointer(strings[0])
        opts.username = UnsafePointer(strings[1])
        opts.password = UnsafePointer(strings[2])
        opts.remoteApp = options.remoteApp
        opts.program = UnsafePointer(strings[3])
        opts.programArguments = UnsafePointer(strings[4])
        opts.sharedFolder = UnsafePointer(strings[5])
        opts.userDriveName = UnsafePointer(strings[6])
        opts.userDrivePath = UnsafePointer(strings[7])
        opts.desktopWidth = UInt32(options.desktopSize.width)
        opts.desktopHeight = UInt32(options.desktopSize.height)
        opts.workAreaX = Int32(options.workArea.minX)
        opts.workAreaY = Int32(options.workArea.minY)
        opts.workAreaWidth = UInt32(options.workArea.width)
        opts.workAreaHeight = UInt32(options.workArea.height)
        let monitors = options.monitors.enumerated().map { index, rect in
            PstscMonitor(x: Int32(rect.minX), y: Int32(rect.minY), width: UInt32(rect.width),
                         height: UInt32(rect.height), primary: index == 0)
        }
        inputOrigin = options.monitors.count > 1
            ? CGPoint(x: options.monitors.map(\.minX).min()!, y: options.monitors.map(\.minY).min()!)
            : .zero
        let started = monitors.withUnsafeBufferPointer { buffer -> Bool in
            opts.monitors = buffer.baseAddress
            opts.monitorCount = UInt32(buffer.count)
            return pstsc_client_start(client, &opts)
        }
        if !started {
            pstsc_client_free(client)
            self.client = nil
        }
        return started
    }

    func disconnect() {
        guard let client else { return }
        self.client = nil
        // Joins the RDP thread; it only ever posts to main asynchronously, so this cannot deadlock.
        pstsc_client_free(client)
    }

    // MARK: Input (desktop coordinates)

    func mouseMove(to p: CGPoint) {
        let q = inputPoint(p)
        pstsc_mouse_move(client, q.x, q.y)
    }

    func mouseButton(_ button: PstscMouseButton, down: Bool, at p: CGPoint) {
        let q = inputPoint(p)
        pstsc_mouse_button(client, button, down, q.x, q.y)
    }

    func mouseWheel(horizontal: Bool, delta: Int, at p: CGPoint) {
        let q = inputPoint(p)
        pstsc_mouse_wheel(client, horizontal, Int32(delta), q.x, q.y)
    }

    private func inputPoint(_ p: CGPoint) -> (x: Int32, y: Int32) {
        (Int32(p.x - inputOrigin.x), Int32(p.y - inputOrigin.y))
    }

    func key(_ macKeyCode: UInt16, down: Bool) { pstsc_key(client, macKeyCode, down) }

    func hangulKey(down: Bool) { pstsc_hangul_key(client, down) }

    func pressWindowsKey() { pstsc_windows_key(client) }

    // MARK: RemoteApp control

    func activate(windowId: UInt32) { pstsc_activate_window(client, windowId, true) }

    func command(windowId: UInt32, _ command: UInt16) { pstsc_window_command(client, windowId, command) }

    /// Arguments of the last launch per program, so a launch the server refused as "not ready yet"
    /// can be sent again (the server only reports the program, not its arguments).
    private(set) var lastArguments: [String: String] = [:]

    func launch(program: String, arguments: String = "") {
        lastArguments[program.lowercased()] = arguments
        program.withCString { program in
            arguments.withCString { args in
                pstsc_exec(client, program, arguments.isEmpty ? nil : args)
            }
        }
    }

    /// Launches a Start menu entry by its AppUserModelID (works for desktop and Store apps).
    func launch(appID: String) {
        launch(program: #"C:\Windows\explorer.exe"#, arguments: #"shell:AppsFolder\"# + appID)
    }

    static let commandMinimize: UInt16 = 0xF020
    static let commandMaximize: UInt16 = 0xF030
    static let commandClose: UInt16 = 0xF060
    static let commandRestore: UInt16 = 0xF120

    // MARK: Private

    func requestAppId(windowId: UInt32) { pstsc_request_app_id(client, windowId) }

    /// Tells the program behind a tray icon that the user clicked its balloon (NIN_BALLOONUSERCLICK).
    func clickTrayBalloon(windowId: UInt32, iconId: UInt32) {
        pstsc_notify_event(client, windowId, iconId, 0x0405)
    }

    /// rect: the whole window (invisible borders included) in desktop coordinates.
    func moveWindow(_ windowId: UInt32, to rect: CGRect) {
        pstsc_window_move(client, windowId, Int32(rect.minX), Int32(rect.minY), Int32(rect.maxX), Int32(rect.maxY))
    }

    /// BGRA with straight alpha, top-down.
    private static func makeIcon(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int) -> CGImage? {
        let data = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func from(_ user: UnsafeMutableRawPointer?) -> RDPSession {
        Unmanaged<RDPSession>.fromOpaque(user!).takeUnretainedValue()
    }

    private static func makeWindowInfo(_ c: PstscWindowInfo) -> RemoteWindowInfo {
        var frame = CGRect(x: Int(c.x), y: Int(c.y), width: Int(c.width), height: Int(c.height))
        if c.visibleWidth > 0 && c.visibleHeight > 0 {
            frame = CGRect(x: Int(c.x + c.visibleX), y: Int(c.y + c.visibleY),
                           width: Int(c.visibleWidth), height: Int(c.visibleHeight))
        }
        return RemoteWindowInfo(id: c.windowId, ownerId: c.ownerWindowId, style: c.style,
                                extendedStyle: c.extendedStyle, showState: c.showState,
                                title: String(cString: c.title), frame: frame,
                                origin: CGPoint(x: Int(c.x), y: Int(c.y)),
                                windowSize: CGSize(width: Int(c.width), height: Int(c.height)))
    }

    /// Why a connection ended, which decides whether to reconnect on our own.
    enum DropReason {
        /// Network trouble or the PC went away: worth reconnecting.
        case network
        /// Wrong password or account problem: ask the user.
        case credentials
        /// The remote session was signed out or timed out; a fresh one can be started right away.
        case loggedOff
        /// The remote side ended it on purpose (another device took the session, server shutdown, …).
        case remoteEnded
        /// We stopped it ourselves.
        case cancelled

        init(errorCode: UInt32) {
            let errorClass = (errorCode >> 16) & 0xFFFF
            let type = errorCode & 0xFFFF
            switch errorClass {
            case 1: // ERRINFO: the server said why it disconnected us
                // RPC_INITIATED_LOGOFF, IDLE_TIMEOUT, LOGON_TIMEOUT, LOGOFF_BY_USER
                self = [0x02, 0x03, 0x04, 0x0C].contains(type) ? .loggedOff : .remoteEnded
            case 2: // ERRCONNECT
                let credentialErrors: Set<UInt32> = [0x09, 0x0E, 0x0F, 0x12, 0x13, 0x14, 0x15, 0x17, 0x18, 0x19]
                if type == 0x0B {
                    self = .cancelled
                } else if credentialErrors.contains(type) {
                    self = .credentials
                } else {
                    self = .network
                }
            default:
                self = .network
            }
        }
    }

    private func handleState(_ state: PstscState, errorCode: UInt32, message: String) {
        switch state {
        case PSTSC_STATE_CONNECTED:
            delegate?.sessionDidConnect(self)
        case PSTSC_STATE_READY:
            delegate?.sessionDidBecomeReady(self)
        case PSTSC_STATE_OTHER_USER_SIGNED_IN:
            delegate?.sessionFoundOtherUserSignedIn(self)
        case PSTSC_STATE_FAILED, PSTSC_STATE_DISCONNECTED:
            delegate?.session(self, didDisconnect: DropReason(errorCode: errorCode), message: message.isEmpty ? nil : message)
        default:
            break
        }
    }

    /// Coalesces paint notifications so the main thread refreshes at most once per run loop pass.
    private func scheduleFlush(dirty: CGRect = .null, windowId: UInt32? = nil) {
        dirtyLock.lock()
        pendingDirty = pendingDirty.union(dirty)
        if let windowId { pendingWindows.insert(windowId) }
        let alreadyScheduled = flushScheduled
        flushScheduled = true
        dirtyLock.unlock()
        guard !alreadyScheduled else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dirtyLock.lock()
            let rect = self.pendingDirty
            let windows = self.pendingWindows
            self.pendingDirty = .null
            self.pendingWindows.removeAll()
            self.flushScheduled = false
            self.dirtyLock.unlock()
            self.delegate?.session(self, framesChangedIn: rect, windowIds: windows)
        }
    }
}
