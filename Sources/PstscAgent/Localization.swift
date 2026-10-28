import Foundation

/// The interface language, picked from the Mac's preferred languages (System Settings →
/// General → Language & Region): Korean, Japanese or English, falling back to English.
enum UILanguage {
    case korean, english, japanese

    static let current: UILanguage = {
        for identifier in Locale.preferredLanguages {
            if identifier.hasPrefix("ko") { return .korean }
            if identifier.hasPrefix("ja") { return .japanese }
            if identifier.hasPrefix("en") { return .english }
        }
        return .english
    }()
}

/// Translates a Korean UI string (the source language of the code) into the interface language.
/// Strings with placeholders use String(format:) syntax, e.g. L("연결 끊김: %@", reason).
func L(_ korean: String, _ arguments: CVarArg...) -> String {
    let text: String
    switch UILanguage.current {
    case .korean:
        text = korean
    case .english:
        text = Translations.table[korean]?.en ?? korean
    case .japanese:
        text = Translations.table[korean]?.ja ?? korean
    }
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}

private enum Translations {
    static let table: [String: (en: String, ja: String)] = [
        // Connect window
        "Pstsc — 원격 PC 연결": ("Pstsc — Connect to Remote PC", "Pstsc — リモート PC に接続"),
        "원격 PC 주소": ("Remote PC address", "リモート PC のアドレス"),
        "사용자": ("User", "ユーザー"),
        "비밀번호": ("Password", "パスワード"),
        "연결": ("Connect", "接続"),
        "비밀번호를 키체인에 저장하고 다음부터 자동 연결": (
            "Save the password in the Keychain and connect automatically next time",
            "パスワードをキーチェーンに保存し、次回から自動接続"),
        "192.168.0.10 또는 pc.example.com": ("192.168.0.10 or pc.example.com", "192.168.0.10 または pc.example.com"),
        "사용자 이름 또는 MicrosoftAccount\\메일주소": (
            "User name or MicrosoftAccount\\email", "ユーザー名または MicrosoftAccount\\メールアドレス"),
        "주소, 사용자, 비밀번호를 모두 입력하세요.": (
            "Enter the address, user and password.", "アドレス、ユーザー、パスワードをすべて入力してください。"),
        "연결 중…": ("Connecting…", "接続中…"),
        "연결됨": ("Connected", "接続済み"),
        "연결 설정을 만들지 못했습니다. 주소 형식을 확인하세요.": (
            "Couldn't set up the connection. Check the address format.",
            "接続を設定できませんでした。アドレスの形式を確認してください。"),
        "비밀번호 또는 계정을 확인하세요.": (
            "Check the password or account.", "パスワードまたはアカウントを確認してください。"),
        "연결 끊김: %@": ("Disconnected: %@", "切断されました: %@"),
        "연결이 끊겼습니다.": ("Disconnected.", "切断されました。"),
        "연결을 끊었습니다.": ("Disconnected.", "切断しました。"),
        "데스크톱 모드로 접속": ("Connect in Desktop Mode", "デスクトップモードで接続"),
        "데스크톱 모드로 연결 중…": ("Connecting in desktop mode…", "デスクトップモードで接続中…"),
        "원격 PC가 이미 사용 중입니다(다른 사용자이거나, PC 앞에서 로그인한 같은 계정). 앱 창 모드로는 연결할 수 없습니다. 데스크톱 모드로 접속하면 그 세션을 넘겨받을 수 있습니다. 넘겨받으면 원격 PC는 잠깁니다.": (
            "The remote PC is already in use (another user, or the same account signed in at the PC). App window mode can't connect. Desktop mode can take over that session; when it does, the remote PC is locked.",
            "リモート PC はすでに使用中です(別のユーザー、または PC の前でサインインした同じアカウント)。アプリウィンドウモードでは接続できません。デスクトップモードで接続すると、そのセッションを引き継げます。引き継ぐと、リモート PC はロックされます。"),

        // Menus
        "Windows 시작": ("Windows Start", "Windows スタート"),
        "Windows 데스크톱 보기": ("Show Windows Desktop", "Windows デスクトップを表示"),
        "앱 창 모드로 돌아가기": ("Back to App Window Mode", "アプリウィンドウモードに戻る"),
        "경로로 원격 프로그램 실행…": ("Run Remote Program by Path…", "パスを指定してリモートのプログラムを実行…"),
        "Mac 홈 폴더를 원격 PC와 공유 ('Mac' 드라이브)": (
            "Share Mac Home Folder with Remote PC ('Mac' drive)",
            "Mac のホームフォルダーをリモート PC と共有(「Mac」ドライブ)"),
        "실행하면 자동 연결 (키체인에 저장)": (
            "Connect Automatically at Launch (Saved in Keychain)", "起動時に自動接続(キーチェーンに保存)"),
        "로그인 시 Pstsc 열기": ("Open Pstsc at Login", "ログイン時に Pstsc を開く"),
        "Launchpad 앱 폴더 열기": ("Open Launchpad Apps Folder", "Launchpad 用アプリのフォルダーを開く"),
        "원격 PC 리소스 사용량…": ("Remote PC Resource Usage…", "リモート PC のリソース使用量…"),
        "원격 PC 리소스 사용량": ("Remote PC Resource Usage", "リモート PC のリソース使用量"),
        "연결 끊기": ("Disconnect", "切断"),
        "Pstsc 종료": ("Quit Pstsc", "Pstsc を終了"),
        "편집": ("Edit", "編集"),
        "잘라내기": ("Cut", "カット"),
        "복사": ("Copy", "コピー"),
        "붙여넣기": ("Paste", "ペースト"),
        "전체 선택": ("Select All", "すべてを選択"),
        "창": ("Window", "ウインドウ"),
        "열린 원격 창 없음": ("No Open Remote Windows", "開いているリモートのウィンドウはありません"),
        "(제목 없음)": ("(Untitled)", "(タイトルなし)"),
        " (최소화됨)": (" (Minimized)", "(最小化)"),
        "원격 PC 연결…": ("Connect to Remote PC…", "リモート PC に接続…"),
        "다시 연결하는 중… (취소)": ("Reconnecting… (Cancel)", "再接続中…(キャンセル)"),

        // Dialogs
        "확인": ("OK", "OK"),
        "취소": ("Cancel", "キャンセル"),
        "실행": ("Run", "実行"),
        "원격 PC에서 로그아웃할까요?": ("Sign out of the remote PC?", "リモート PC からサインアウトしますか?"),
        "열려 있는 원격 프로그램이 모두 닫힙니다.": (
            "All open remote programs will close.", "開いているリモートのプログラムはすべて閉じます。"),
        "원격 PC를 다시 시작할까요?": ("Restart the remote PC?", "リモート PC を再起動しますか?"),
        "열려 있는 원격 프로그램이 모두 닫히고 연결이 끊깁니다.": (
            "All open remote programs will close and the connection will end.",
            "開いているリモートのプログラムはすべて閉じ、接続が切れます。"),
        "원격 PC를 끌까요?": ("Shut down the remote PC?", "リモート PC をシャットダウンしますか?"),
        "다시 켜기 전까지 원격 PC에 연결할 수 없습니다.": (
            "You won't be able to connect until it is turned on again.",
            "再び電源を入れるまで、リモート PC に接続できなくなります。"),
        "프로그램을 실행하지 못했습니다": ("Couldn't start the program", "プログラムを起動できませんでした"),
        "%@\n오류 코드: %d\n%@": ("%@\nError code: %d\n%@", "%@\nエラーコード: %d\n%@"),
        "이 원격 PC는 아직 Pstsc 연결 준비가 되어 있지 않습니다. 저장소의 enable-remoteapp.reg를 원격 PC에서 실행하고 재시작한 뒤 다시 연결하세요.": (
            "This remote PC isn't set up for Pstsc yet. Run enable-remoteapp.reg from the repository on the remote PC, restart it, then connect again.",
            "このリモート PC はまだ Pstsc 接続の準備ができていません。リポジトリの enable-remoteapp.reg をリモート PC で実行し、再起動してから再接続してください。"),
        "원격 PC에서 RemoteApp이 허용되어 있지 않습니다. enable-remoteapp.reg를 적용하세요.": (
            "RemoteApp isn't allowed on the remote PC. Apply enable-remoteapp.reg.",
            "リモート PC で RemoteApp が許可されていません。enable-remoteapp.reg を適用してください。"),
        "원격 PC에서 그 경로의 프로그램을 찾지 못했습니다.": (
            "The program wasn't found at that path on the remote PC.",
            "リモート PC のそのパスにプログラムが見つかりませんでした。"),
        "원격 PC에서 RemoteApp 허용 설정과 프로그램 경로를 확인하세요.": (
            "Check the RemoteApp setting on the remote PC and the program path.",
            "リモート PC の RemoteApp の許可設定とプログラムのパスを確認してください。"),
        "로그인 항목을 바꾸지 못했습니다": ("Couldn't change the login item", "ログイン項目を変更できませんでした"),
        "응용 프로그램 폴더의 Pstsc.app으로 실행했을 때만 설정할 수 있습니다.\n%@": (
            "This only works when Pstsc runs as Pstsc.app from the Applications folder.\n%@",
            "アプリケーションフォルダーの Pstsc.app として起動したときだけ設定できます。\n%@"),
        "앱 창 모드로 연결된 상태에서만 측정할 수 있습니다.": (
            "Measuring works only while connected in app window mode.",
            "アプリウィンドウモードで接続しているときだけ測定できます。"),
        "Pstsc 연결 세션의 프로세스와 원격 데스크톱 서비스를 3초 동안 측정했습니다.": (
            "Measured the processes of the Pstsc session and the Remote Desktop service over 3 seconds.",
            "Pstsc の接続セッションのプロセスとリモートデスクトップサービスを 3 秒間測定しました。"),
        "원격 프로그램 실행": ("Run Remote Program", "リモートのプログラムを実行"),
        "원격 PC에 있는 실행 파일의 전체 경로를 입력하세요.": (
            "Enter the full path of the program on the remote PC.",
            "リモート PC にある実行ファイルのフルパスを入力してください。"),

        // Desktop mode
        "Windows 데스크톱": ("Windows Desktop", "Windows デスクトップ"),

        // Start menu
        "앱, 설정 및 문서 검색": ("Search for apps, settings, and documents", "アプリ、設定、ドキュメントの検索"),
        "고정됨": ("Pinned", "ピン留め済み"),
        "모두  ›": ("All  ›", "すべて  ›"),
        "맞춤": ("Recommended", "おすすめ"),
        "‹  뒤로": ("‹  Back", "‹  戻る"),
        "모든 앱": ("All apps", "すべてのアプリ"),
        "검색 결과": ("Search results", "検索結果"),
        "'%@'에 대한 결과가 없습니다": ("No results for '%@'", "「%@」の検索結果はありません"),
        "원격 PC에서 앱 목록을 받아오는 중입니다…": (
            "Getting the app list from the remote PC…", "リモート PC からアプリの一覧を取得しています…"),
        "앱 아이콘 받는 중… %d%% (%d/%d)": (
            "Getting app icons… %d%% (%d/%d)", "アプリのアイコンを取得中… %d%%(%d/%d)"),
        "고정된 앱이 없습니다. '모두'에서 앱을 우클릭해 고정하세요.": (
            "No pinned apps. Right-click an app in 'All' to pin it.",
            "ピン留めしたアプリはありません。「すべて」でアプリを右クリックしてピン留めしてください。"),
        "최근에 실행한 앱이 여기에 표시됩니다. 고정하려면 앱을 우클릭하세요.": (
            "Recently opened apps appear here. Right-click an app to pin it.",
            "最近使ったアプリがここに表示されます。ピン留めするにはアプリを右クリックしてください。"),
        "시작 화면에 고정": ("Pin to Start", "スタートにピン留めする"),
        "시작 화면에서 고정 해제": ("Unpin from Start", "スタートからピン留めを外す"),
        "전원": ("Power", "電源"),
        "원격 PC 로그아웃…": ("Sign Out of Remote PC…", "リモート PC からサインアウト…"),
        "원격 PC 다시 시작…": ("Restart Remote PC…", "リモート PC を再起動…"),
        "원격 PC 시스템 종료…": ("Shut Down Remote PC…", "リモート PC をシャットダウン…"),

        // Per-program Dock icons
        "Windows 앱": ("Windows App", "Windows アプリ"),
    ]
}
