import AppKit

/// Desktop mode: the whole remote Windows desktop in one ordinary Mac window.
final class DesktopWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let session: RDPSession
    private let desktopSize: CGSize
    private let remoteView: RemoteContentView

    /// Desktop size that fits in the screen's visible area below a standard title bar.
    static func desktopSize(for screen: NSScreen) -> CGSize {
        let content = NSWindow.contentRect(forFrameRect: screen.visibleFrame, styleMask: [.titled])
        // Even sizes keep codecs happy.
        return CGSize(width: Int(content.width) & ~1, height: Int(content.height) & ~1)
    }

    init(session: RDPSession, desktopSize: CGSize) {
        self.session = session
        self.desktopSize = desktopSize
        // The view may be resized; scale both the picture and the mouse to the remote desktop.
        remoteView = RemoteContentView(session: session, scalesToFit: true) { point, view in
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return .zero }
            return CGPoint(x: (point.x / bounds.width * desktopSize.width).rounded(.down),
                           y: ((bounds.height - point.y) / bounds.height * desktopSize.height).rounded(.down))
        }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: desktopSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("Windows 데스크톱")
        window.contentAspectRatio = desktopSize
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = remoteView
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + (visible.width - window.frame.width) / 2, y: visible.maxY))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(remoteView)
    }

    func refresh() {
        remoteView.show(session.frames.image(of: CGRect(origin: .zero, size: desktopSize)))
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        KeyboardBridge.shared.releaseAll()
    }
}
