import AppKit
import PstscRDP

/// Keeps one Mac window per visible remote window, in step with the server's window orders.
final class RemoteWindowManager: NSObject, NSWindowDelegate {
    private let session: RDPSession
    private(set) var windows: [UInt32: RemoteAppWindow] = [:]
    private var focusingProgrammatically = false
    /// The helper's invisible keep-alive window (see AppCatalog.helperScript): never shown here.
    static let keepAliveTitle = "PstscKeepAlive"
    private var ignored = Set<UInt32>()

    /// A non-popup window appeared on the Mac for the first time (used to look up its program).
    var onFirstShown: ((RemoteAppWindow) -> Void)?
    var onTitleChanged: ((UInt32, String) -> Void)?
    var onRemoved: ((UInt32) -> Void)?
    /// A window appeared on or left the screen (hidden to the tray, closed, …).
    var onPresenceChanged: ((UInt32) -> Void)?

    init(session: RDPSession) {
        self.session = session
    }

    func apply(_ info: RemoteWindowInfo) {
        if info.title == Self.keepAliveTitle || ignored.contains(info.id) {
            ignored.insert(info.id)
            remove(info.id)
            return
        }
        let window = windows[info.id] ?? makeWindow(info)
        let oldTitle = window.info.title
        window.update(info)
        present(window)
        if window.hasBeenShown && oldTitle != info.title {
            onTitleChanged?(info.id, info.title)
        }
    }

    /// Shows the window only once the server sends pixels for it (its GFX surface), like xfreerdp.
    /// Shell windows such as the taskbar and "Program Manager" never get one and so stay hidden;
    /// the shared desktop framebuffer would only show stale logon screens for them.
    private func present(_ window: RemoteAppWindow) {
        let info = window.info
        let hidden = info.showState == RemoteWindowInfo.showHidden
            || info.showState == RemoteWindowInfo.showMinimized
            || info.frame.isEmpty
            || (session.surface(for: info.id) == nil && !window.hasFreshDesktopPixels)
        if hidden {
            let wasVisible = window.isVisible
            window.orderOut(nil)
            if wasVisible || info.showState == RemoteWindowInfo.showHidden {
                onPresenceChanged?(info.id)
            }
            return
        }

        window.refresh(from: session)
        guard !window.isVisible else { return }
        let firstTime = !window.hasBeenShown
        if firstTime && !info.isPopup {
            // The server already decides which remote window is active; don't echo focus back.
            focusingProgrammatically = true
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            focusingProgrammatically = false
        } else if info.isPopup && NSApp.isActive && !(NSApp.keyWindow?.isVisible ?? false) {
            // e.g. the Start menu opened from the Dock: nothing else holds the keyboard yet.
            focusingProgrammatically = true
            window.makeKeyAndOrderFront(nil)
            focusingProgrammatically = false
        } else {
            window.orderFront(nil)
        }
        window.hasBeenShown = true
        if firstTime && !info.isPopup {
            onFirstShown?(window)
        }
        onPresenceChanged?(info.id)
    }

    /// Whether a window counts as open for its program: shown at least once and not hidden by the
    /// server (minimized still counts, like a Mac window in the Dock).
    func isPresent(_ id: UInt32) -> Bool {
        guard let window = windows[id], !window.info.isPopup, window.hasBeenShown else { return false }
        return window.info.showState != RemoteWindowInfo.showHidden
    }

    func remove(_ id: UInt32) {
        session.removeSurface(for: id)
        if windows[id] == nil { ignored.remove(id) }
        guard let window = windows.removeValue(forKey: id) else { return }
        onRemoved?(id)
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    func removeAll() {
        for id in Array(windows.keys) {
            remove(id)
        }
    }

    func refresh(_ dirty: CGRect, windowIds: Set<UInt32>) {
        for window in windows.values {
            if windowIds.contains(window.remoteId) {
                // The first surface update is what makes a window appear.
                window.isVisible ? window.refresh(from: session) : present(window)
            } else if !dirty.isNull && window.info.frame.intersects(dirty) {
                if window.isVisible {
                    window.refresh(from: session)
                } else if session.surface(for: window.remoteId) == nil && !window.hasFreshDesktopPixels
                            && !window.info.isPopup {
                    // Popups are skipped: invisible full-screen helper windows (e.g. "SNB") would cover everything.
                    window.hasFreshDesktopPixels = true
                    present(window)
                }
            }
        }
    }

    /// Whether Explorer runs as the shell in this session (needed for the Start menu).
    var hasRemoteShell: Bool {
        windows.values.contains { $0.info.title == "Program Manager" }
    }

    /// Windows a user would want to pick from a menu (no popups), sorted by title.
    var appWindows: [RemoteAppWindow] {
        windows.values.filter { !$0.info.isPopup && $0.hasBeenShown }.sorted { $0.info.title < $1.info.title }
    }

    /// The server asks us to move/size a window locally (RAIL local move/size): the Mac drags the
    /// window itself, so it follows the mouse with no network round trip. Afterwards the remote
    /// side gets the button-up that ends its move loop and the window's new frame.
    func beginLocalMoveSize(windowId: UInt32, type: UInt16) {
        guard let window = windows[windowId], window.isVisible, (1...9).contains(type),
              window.info.showState != 3, // maximized: Windows restores it while dragging, leave that to it
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let info = window.info
        let visible = window.trackLocalMoveSize(type: type)

        let mouse = RemoteAppWindow.desktopPoint(forScreenPoint: NSEvent.mouseLocation)
        session.mouseButton(PSTSC_MOUSE_LEFT, down: false, at: mouse)

        // Report the whole window, invisible resize borders included.
        let left = info.frame.minX - info.origin.x
        let top = info.frame.minY - info.origin.y
        let right = info.origin.x + info.windowSize.width - info.frame.maxX
        let bottom = info.origin.y + info.windowSize.height - info.frame.maxY
        let whole = CGRect(x: visible.minX - left, y: visible.minY - top,
                           width: visible.width + left + right, height: visible.height + top + bottom)
        session.moveWindow(windowId, to: whole)
    }

    /// Brings all of one program's open windows forward, like clicking an app in the Mac Dock.
    /// Returns false when the program has none (e.g. it only sits in the tray).
    @discardableResult
    func bringToFront(windowIds: Set<UInt32>) -> Bool {
        let targets = windowIds.filter(isPresent).compactMap { windows[$0] }
        guard !targets.isEmpty else { return false }
        NSApp.activate()
        let visible = targets.filter(\.isVisible)
        visible.forEach { $0.orderFront(nil) }
        bringToFront(visible.first ?? targets[0])
        return true
    }

    /// Never shows a window the server hid: it would come back with stale pixels and fight the
    /// program (e.g. KakaoTalk hiding itself to the tray on X).
    func bringToFront(_ window: RemoteAppWindow) {
        switch window.info.showState {
        case RemoteWindowInfo.showHidden:
            return
        case RemoteWindowInfo.showMinimized:
            // Shown again once the server reports it restored.
            session.command(windowId: window.remoteId, RDPSession.commandRestore)
            session.activate(windowId: window.remoteId)
        default:
            session.activate(windowId: window.remoteId)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow(_ info: RemoteWindowInfo) -> RemoteAppWindow {
        let window = RemoteAppWindow(info: info, session: session)
        window.delegate = self
        windows[info.id] = window
        return window
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard !focusingProgrammatically, let window = notification.object as? RemoteAppWindow,
              !window.info.isPopup else { return }
        session.activate(windowId: window.remoteId)
    }

    func windowDidResignKey(_ notification: Notification) {
        KeyboardBridge.shared.releaseAll()
    }
}
