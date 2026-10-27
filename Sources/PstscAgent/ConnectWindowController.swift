import AppKit

struct Credentials {
    var host: String
    var username: String
    var password: String
}

/// Asks for the remote PC and account. Everything except the password is remembered.
final class ConnectWindowController: NSWindowController {
    /// remember: save the password in the Keychain and connect automatically from now on.
    var onConnect: ((Credentials, _ remember: Bool) -> Void)?

    private let hostField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "연결", target: nil, action: nil)
    private let rememberBox = NSButton(checkboxWithTitle: "비밀번호를 키체인에 저장하고 다음부터 자동 연결", target: nil, action: nil)

    private enum Key {
        static let host = "host"
        static let user = "username"
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pstsc — 원격 PC 연결"
        super.init(window: window)

        let defaults = UserDefaults.standard
        hostField.stringValue = defaults.string(forKey: Key.host) ?? ""
        userField.stringValue = defaults.string(forKey: Key.user) ?? ""
        hostField.placeholderString = "192.168.0.10 또는 pc.example.com"
        userField.placeholderString = "사용자 이름 또는 MicrosoftAccount\\메일주소"

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .push

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "원격 PC 주소"), hostField],
            [NSTextField(labelWithString: "사용자"), userField],
            [NSTextField(labelWithString: "비밀번호"), passwordField],
            [NSGridCell.emptyContentView, rememberBox],
        ])
        rememberBox.state = .on
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 1).width = 300

        let buttons = NSStackView(views: [statusLabel, connectButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        window.initialFirstResponder = hostField.stringValue.isEmpty ? hostField : passwordField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setBusy(_ busy: Bool, status: String) {
        connectButton.isEnabled = !busy
        statusLabel.stringValue = status
    }

    @objc private func connect() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !user.isEmpty, !passwordField.stringValue.isEmpty else {
            setBusy(false, status: "주소, 사용자, 비밀번호를 모두 입력하세요.")
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(host, forKey: Key.host)
        defaults.set(user, forKey: Key.user)

        let credentials = Credentials(host: host, username: user, password: passwordField.stringValue)
        passwordField.stringValue = ""
        setBusy(true, status: "연결 중…")
        onConnect?(credentials, rememberBox.state == .on)
    }
}
