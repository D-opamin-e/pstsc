import AppKit
import PstscRDP

/// A borderless Mac window showing one remote window. Windows draws its own title bar,
/// so the whole remote window is content and every click goes to the remote side.
final class RemoteAppWindow: NSWindow {
    let remoteId: UInt32
    private(set) var info: RemoteWindowInfo
    let remoteView: RemoteContentView
    /// Whether the window was ever put on screen; only the first appearance takes focus.
    var hasBeenShown = false
    /// Set once the shared desktop framebuffer was freshly painted inside this window. Some apps
    /// (Steam, Explorer) never get their own GFX surface and are drawn there instead.
    var hasFreshDesktopPixels = false
    /// While the user drags the window locally, server position updates must not move it.
    var isLocallyMoving = false
    /// Frame we reported after a local move; older server updates arriving meanwhile are ignored.
    private var reportedFrame: (frame: CGRect, until: Date)?

    init(info: RemoteWindowInfo, session: RDPSession) {
        remoteId = info.id
        self.info = info
        remoteView = RemoteContentView(session: session)
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)

        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        backgroundColor = .black
        hasShadow = true
        contentView = remoteView
        update(info)
    }

    /// Popups may take the keyboard too (typing into the Start menu's search box); keys go to the
    /// remote session as a whole, and popups never send a RAIL activate, which would close them.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !info.isPopup }

    func update(_ info: RemoteWindowInfo) {
        self.info = info
        title = info.title
        level = info.isPopup ? .popUpMenu : .normal
        isOpaque = !info.isLayered
        backgroundColor = info.isLayered ? .clear : .black
        hasShadow = !info.isLayered
        if isLocallyMoving { return }
        if let reported = reportedFrame {
            if info.frame == reported.frame || Date() > reported.until {
                reportedFrame = nil
            } else {
                return // a stale position from before our move report
            }
        }
        let frame = Self.macFrame(forDesktopRect: info.frame)
        if frame != self.frame {
            setFrame(frame, display: false)
        }
    }

    /// Drags or resizes the window on the Mac until the mouse button is released and returns the
    /// new visible frame in desktop coordinates. type: 1–8 resize edges, 9 move (RAIL_WMSZ_*).
    func trackLocalMoveSize(type: UInt16) -> CGRect {
        let startMouse = NSEvent.mouseLocation
        let start = frame
        let minimum = NSSize(width: 120, height: 60)
        isLocallyMoving = true
        trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                    mode: .eventTracking) { event, stop in
            guard let event else { return }
            let dx = NSEvent.mouseLocation.x - startMouse.x
            let dy = NSEvent.mouseLocation.y - startMouse.y
            var f = start
            switch type {
            case 9:
                f.origin.x += dx
                f.origin.y += dy
            default:
                // Windows edges; Mac y grows upward, so "top" is maxY.
                if [1, 4, 7].contains(type) { f.origin.x = min(start.minX + dx, start.maxX - minimum.width); f.size.width = start.maxX - f.origin.x }
                if [2, 5, 8].contains(type) { f.size.width = max(start.width + dx, minimum.width) }
                if [3, 4, 5].contains(type) { f.size.height = max(start.height + dy, minimum.height) }
                if [6, 7, 8].contains(type) {
                    f.origin.y = min(start.minY + dy, start.maxY - minimum.height)
                    f.size.height = start.maxY - f.origin.y
                }
            }
            self.setFrame(f, display: false)
            if event.type == .leftMouseUp { stop.pointee = true }
        }
        isLocallyMoving = false
        let screen = Self.primaryScreenFrame
        let desktop = CGRect(x: frame.minX - screen.minX, y: screen.maxY - frame.maxY,
                             width: frame.width, height: frame.height).integral
        reportedFrame = (desktop, Date().addingTimeInterval(1.5))
        return desktop
    }

    /// Uses the window's own GFX surface when the server sends one, else the shared desktop framebuffer.
    func refresh(from session: RDPSession) {
        if let surface = session.surface(for: remoteId) {
            remoteView.show(surface.image(of: info.surfaceCrop, alpha: info.isLayered))
        } else {
            remoteView.show(session.frames.image(of: info.frame))
        }
    }

    // MARK: Coordinate mapping (remote desktop = primary screen, 1 pixel = 1 point)

    static var primaryScreenFrame: CGRect {
        NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    static func macFrame(forDesktopRect r: CGRect) -> NSRect {
        let screen = primaryScreenFrame
        return NSRect(x: screen.minX + r.minX, y: screen.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func desktopPoint(forScreenPoint p: NSPoint) -> CGPoint {
        let screen = primaryScreenFrame
        return CGPoint(x: (p.x - screen.minX).rounded(.down), y: (screen.maxY - p.y).rounded(.down))
    }
}

/// Draws the remote pixels and forwards mouse and keyboard input to the session.
final class RemoteContentView: NSView {
    /// Turns a point in this view's coordinates into remote desktop pixels.
    typealias PointMapper = (_ viewPoint: NSPoint, _ view: NSView) -> CGPoint

    private let session: RDPSession
    private let mapPoint: PointMapper
    private var trackingArea: NSTrackingArea?
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    /// RemoteApp windows: the view sits where the remote window is, so map through screen coordinates.
    static let screenMapper: PointMapper = { point, view in
        guard let window = view.window else { return .zero }
        let inWindow = view.convert(point, to: nil)
        return RemoteAppWindow.desktopPoint(forScreenPoint: window.convertPoint(toScreen: inWindow))
    }

    init(session: RDPSession, scalesToFit: Bool = false, mapPoint: @escaping PointMapper = RemoteContentView.screenMapper) {
        self.session = session
        self.mapPoint = mapPoint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = scalesToFit ? .resize : .topLeft
        layer?.isGeometryFlipped = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func show(_ image: CGImage?) {
        guard let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        layer?.contentsScale = 1
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Mouse

    private func desktopPoint(_ event: NSEvent) -> CGPoint {
        mapPoint(convert(event.locationInWindow, from: nil), self)
    }

    override func mouseMoved(with event: NSEvent) { session.mouseMove(to: desktopPoint(event)) }
    override func mouseDragged(with event: NSEvent) { session.mouseMove(to: desktopPoint(event)) }
    override func rightMouseDragged(with event: NSEvent) { session.mouseMove(to: desktopPoint(event)) }
    override func otherMouseDragged(with event: NSEvent) { session.mouseMove(to: desktopPoint(event)) }

    override func mouseDown(with event: NSEvent) {
        let p = desktopPoint(event)
        session.mouseMove(to: p)
        session.mouseButton(PSTSC_MOUSE_LEFT, down: true, at: p)
    }

    override func mouseUp(with event: NSEvent) { session.mouseButton(PSTSC_MOUSE_LEFT, down: false, at: desktopPoint(event)) }

    override func rightMouseDown(with event: NSEvent) {
        let p = desktopPoint(event)
        session.mouseMove(to: p)
        session.mouseButton(PSTSC_MOUSE_RIGHT, down: true, at: p)
    }

    override func rightMouseUp(with event: NSEvent) { session.mouseButton(PSTSC_MOUSE_RIGHT, down: false, at: desktopPoint(event)) }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        session.mouseButton(PSTSC_MOUSE_MIDDLE, down: true, at: desktopPoint(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        session.mouseButton(PSTSC_MOUSE_MIDDLE, down: false, at: desktopPoint(event))
    }

    override func scrollWheel(with event: NSEvent) {
        let p = desktopPoint(event)
        // Windows: 120 units per notch. Trackpads report points, wheels report lines.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 40
        scrollRemainderY += event.scrollingDeltaY * scale
        scrollRemainderX += -event.scrollingDeltaX * scale
        let dy = Int(scrollRemainderY), dx = Int(scrollRemainderX)
        if dy != 0 {
            session.mouseWheel(horizontal: false, delta: dy, at: p)
            scrollRemainderY -= CGFloat(dy)
        }
        if dx != 0 {
            session.mouseWheel(horizontal: true, delta: dx, at: p)
            scrollRemainderX -= CGFloat(dx)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { KeyboardBridge.shared.key(event, down: true, session: session) }
    override func keyUp(with event: NSEvent) { KeyboardBridge.shared.key(event, down: false, session: session) }
    override func flagsChanged(with event: NSEvent) { KeyboardBridge.shared.flagsChanged(event, session: session) }

    /// Command shortcuts go to the remote side (as Ctrl) instead of this app's menus, except Cmd+Q.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command) && event.keyCode == KeyboardBridge.keyQ { return false }
        KeyboardBridge.shared.key(event, down: true, session: session)
        return true
    }
}
