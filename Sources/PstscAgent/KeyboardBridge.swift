import AppKit

/// Turns Mac key events into remote key presses.
/// Left Command acts as Ctrl (so Cmd+C/V/Z/S behave like on a Mac) and Right Command toggles 한/영.
final class KeyboardBridge {
    static let shared = KeyboardBridge()
    static let keyQ: UInt16 = 12

    private static let leftCommand: UInt16 = 55
    private static let rightCommand: UInt16 = 54
    private static let leftControl: UInt16 = 59
    private static let capsLock: UInt16 = 57

    /// Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) so left and right keys are told apart.
    private static let modifierMasks: [UInt16: UInt] = [
        56: 0x0002, 60: 0x0004, // shift
        59: 0x0001, 62: 0x2000, // control
        58: 0x0020, 61: 0x0040, // option
        55: 0x0008, 54: 0x0010, // command
    ]

    /// Remote key codes (after mapping) currently held down.
    private var pressed = Set<UInt16>()
    private weak var session: RDPSession?

    func key(_ event: NSEvent, down: Bool, session: RDPSession) {
        send(event.keyCode, down: down, session: session)
    }

    func flagsChanged(_ event: NSEvent, session: RDPSession) {
        let code = event.keyCode
        if code == Self.capsLock {
            send(code, down: true, session: session)
            send(code, down: false, session: session)
            return
        }
        guard let mask = Self.modifierMasks[code] else { return }
        let down = event.modifierFlags.rawValue & mask != 0

        if code == Self.rightCommand {
            if down {
                session.hangulKey(down: true)
                session.hangulKey(down: false)
            }
            return
        }
        send(code, down: down, session: session)
    }

    /// Lifts every held key, e.g. when the user switches to another Mac app mid-shortcut.
    func releaseAll() {
        guard let session else { pressed.removeAll(); return }
        for code in pressed {
            session.key(code, down: false)
        }
        pressed.removeAll()
    }

    private func send(_ macCode: UInt16, down: Bool, session: RDPSession) {
        self.session = session
        let code = macCode == Self.leftCommand ? Self.leftControl : macCode
        session.key(code, down: down)
        if down {
            pressed.insert(code)
        } else {
            pressed.remove(code)
        }
    }
}
