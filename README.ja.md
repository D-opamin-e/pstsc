# Pstsc

[한국어](README.md) | [English](README.en.md) | **日本語**

**リモートの Windows PC のアプリを Mac のアプリのように使える、macOS 向け RemoteApp(RDP)クライアント。Parallels の Coherence モードのように、アプリのウィンドウだけを Mac に表示します。**

![MacBook Air のデスクトップに、リモート Windows PC の 3DMark のウィンドウだけが表示されている画面](docs/images/hero.webp)

*MacBook Air(M2、メモリ 8GB)で、Ryzen 7 7800X3D と RX 6900 XT を搭載したリモート Windows PC の 3DMark をウィンドウ 1 つで動かしている様子です。Windows のデスクトップは表示されず、アプリのウィンドウだけが Mac のウィンドウとして開きます。Dock には Pstsc(Windows アイコン)と 3DMark のアイコンが別々に並びます。*

Pstsc は、すでに持っている Windows PC のアプリを 1 つずつ Mac に呼び出し、独立したウィンドウとして表示します。Parallels Desktop の Coherence モードに近い使い心地ですが、Mac の中に Windows をインストールするのではなく、リモートデスクトップ(RDP RemoteApp)で Windows PC に接続します。アプリごとに Dock アイコンができ、Windows 11 風のスタートメニューや Spotlight・Launchpad からの起動にも対応しています。

> 個人プロジェクトです。Microsoft、Parallels とは関係ありません。

> アプリの画面は Mac の言語設定に合わせて**日本語・英語・韓国語**で表示されます(その他の言語は英語)。

## スクリーンショット

| Dock アイコンから開くスタートメニュー | Mac のウィンドウとして開いたリモートのメモ帳 | リモートの電卓 |
|:---:|:---:|:---:|
| <img src="docs/images/start-menu.png" width="320" alt="Windows 11 風のスタートメニュー"> | <img src="docs/images/notepad.png" width="420" alt="リモートのメモ帳ウィンドウ"> | <img src="docs/images/calculator.png" width="160" alt="リモートの電卓ウィンドウ"> |

スタートメニューは Pstsc が Mac 上で描画しているウィンドウで、メモ帳と電卓はリモートの Windows PC で動いているアプリです。それぞれが Mac の独立したウィンドウとして開きます。

## 主な機能

**ウィンドウと画面**
- リモートアプリのウィンドウ 1 つが Mac のウィンドウ 1 つになります(RDP RemoteApp)。リモートのデスクトップは表示されません。
- ウィンドウをドラッグすると Mac 側ですぐに動き、手を離したときだけリモートに位置を伝えます。
- デュアルモニター対応。Mac のディスプレイ配置をそのままリモートに伝えるので、ディスプレイ間でウィンドウを移動できます。
- デスクトップモードでは、リモートのデスクトップ全体を 1 つのウィンドウで表示します。アプリモードといつでも切り替えられます。

**Dock と起動**
- Pstsc の Dock アイコンをクリックすると、Windows 11 風のスタートメニューが開きます。検索、ピン留め、すべてのアプリ(#、A–Z、ㄱ–ㅎ でグループ化)、最近使ったアプリ、電源メニューがあります。
- 起動中のリモートアプリごとに、その名前とアイコンで Dock アイコンができます。クリックでウィンドウを前面に、右クリックでウィンドウ一覧、終了でリモートのアプリを閉じます。
- リモートのスタートメニューのアプリが `~/Applications/Pstsc 앱/`(「Pstsc アプリ」)に登録され、Spotlight や Launchpad から直接起動できます。Pstsc が起動していなければ、先に起動して接続してからアプリを開きます。

**接続**
- パスワードを macOS のキーチェーンに保存し、Pstsc を起動するとすぐに接続します。Mac へのログイン時に自動で開くこともできます。
- ネットワークが切れたときや Mac がスリープから復帰したときに、自動で再接続します。
- リモートのアプリをすべてタスクトレイに隠しても、リモートのセッションはサインアウトしません。メッセンジャーのようなトレイ常駐アプリも動き続けます。

**その他**
- リモートの音を Mac で再生します。
- Mac のホームフォルダーが、リモートのエクスプローラーに `Mac` ドライブとして表示され、ファイルをやり取りできます。
- リモートのトレイアイコンのバルーン通知を、Mac の通知センターに表示します。
- キーボード: 左 ⌘ は Ctrl として送るので、⌘C・⌘V が Mac と同じように使えます。右 ⌘ は IME 切り替えキー(スキャンコード 0x72: 日本語版 Windows ではかな、韓国語版ではハングル)を送ります。
- メニューの **リモート PC のリソース使用量** で、この接続がリモート PC で使っている CPU とメモリを測定できます。

## 動作環境

| 項目 | 内容 |
|---|---|
| Mac | **Apple シリコン**(M1 以降)の Mac、macOS 14 以降。Intel Mac にはまだ対応していません。 |
| リモート PC | リモートデスクトップを有効にできる Windows 10/11 **Pro** 以上、または Windows Server。Home エディションは RDP のホストになれません。 |

## インストール

### DMG でインストール(推奨)

1. [Releases](https://github.com/D-opamin-e/pstsc/releases/latest) から `Pstsc-<バージョン>.dmg` をダウンロードします。
2. DMG を開き、**Pstsc** を右側の **Applications(アプリケーション)** フォルダへドラッグします。
3. アプリケーションフォルダから Pstsc を起動します。Dock アイコンを右クリック → オプション → **Dock に追加** を選ぶと便利です。

必要なライブラリ(FreeRDP、OpenSSL)はアプリに含まれているので、ほかにインストールするものはありません。

**初回起動時に「開発元を確認できません」と表示されたら**: Pstsc は Apple の開発者証明書で署名されていません。警告を閉じ、**システム設定 → プライバシーとセキュリティ** の下にある **このまま開く** を押してください。ターミナルで次のコマンドを一度実行しても構いません。

```bash
xattr -dr com.apple.quarantine /Applications/Pstsc.app
```

初回起動時、macOS が次の許可を求めることがあります。関連機能を使うにはすべて許可してください。
- 通知: リモートの通知を Mac の通知として受け取る
- キーチェーンへのアクセス: 保存したパスワードで自動接続する
- デスクトップ・書類・ダウンロードフォルダへのアクセス: リモート PC から `Mac` ドライブを開くとき

### アップデート

Pstsc を終了(⌘Q)してから、新しい DMG で同じ手順でインストールし「置き換える」を選びます。設定と保存したパスワードはそのまま残ります。

### アンインストール

Pstsc を終了してから次を削除します。保存したパスワードはキーチェーンアクセスで `com.pstsc.agent` の項目を削除してください。

```bash
rm -rf /Applications/Pstsc.app "$HOME/Applications/Pstsc 앱" \
  "$HOME/Library/Application Support/Pstsc" "$HOME/Library/Logs/Pstsc"
defaults delete com.pstsc.agent
```

### ソースからビルド

Xcode コマンドラインツール(`xcode-select --install`)と [Homebrew](https://brew.sh) が必要です。

```bash
brew install cmake ninja
git clone https://github.com/D-opamin-e/pstsc.git
cd pstsc
scripts/build-app.sh      # ビルドして /Applications/Pstsc.app にインストール
scripts/build-dmg.sh      # 配布用の build/Pstsc-<バージョン>.dmg を作成
```

初回ビルド時は `scripts/build-freerdp.sh` が FreeRDP と OpenSSL のソースを取得し、アプリに同梱できるようにビルドします(数分かかり、`build/deps` に保存されます)。Homebrew の `freerdp` パッケージは使いません。GPL コーデック(x264、x265)が付いてくるため一緒に配布できず、ビルドした macOS のバージョンでしか動かないためです。

コードを編集しながらすぐ試すときは `swift build && swift run PstscAgent` を使います。この場合も `build/deps` が必要なので、先に `scripts/build-freerdp.sh` を一度実行してください。

## リモート PC の準備

Mac へのインストール後、接続する Windows PC で一度だけ設定します。

1. **設定 → システム → リモートデスクトップ** をオンにします。
2. このリポジトリの [`remote/enable-remoteapp.reg`](remote/enable-remoteapp.reg) をリモート PC にコピーしてダブルクリックします(管理者権限が必要)。RemoteApp として登録されていないアプリも起動できるようにする設定です。
3. (推奨)[`remote/single-session.reg`](remote/single-session.reg) も同じ方法で適用します。同じアカウントで再接続したとき、常に既存のセッション 1 つにつながるようにする設定です。
4. リモート PC を再起動します。
5. 外部から接続する場合は、ルーターで RDP ポート(既定 3389)をリモート PC に転送する必要があります。安全のため、VPN や Tailscale などの利用をおすすめします。

## 使い方

1. Pstsc を起動し、リモート PC のアドレス、ユーザー名、パスワードを入力します。Microsoft アカウントの場合は、ユーザー名に `MicrosoftAccount\メールアドレス` を、パスワードには PIN ではなくアカウントのパスワードを使います。
2. 接続したら Dock の Pstsc アイコンをクリックし、スタートメニューからアプリを起動します。
3. リモートのデスクトップ全体が必要なときは、スタートメニューの電源ボタン → **Windows デスクトップを表示** を選びます。

| 操作 | 方法 |
|---|---|
| アプリの起動 | Dock の Pstsc アイコン → スタートメニュー、または Spotlight でアプリ名を検索 |
| ピン留め/解除 | スタートメニューでアプリを右クリック |
| リモートのウィンドウ一覧 | メニューバーの **ウインドウ** メニュー、または Dock アイコンを右クリック |
| IME の切り替え | 右 ⌘ |
| ファイルのやり取り | リモートのエクスプローラーの `Mac` ドライブ(`\\tsclient\Mac`) |
| 切断、リモート PC の再起動 | スタートメニューの電源ボタン |

## 仕組み

```
[リモートの Windows PC]
   ├─ RemoteApp セッション: アプリのウィンドウごとに画面を個別に送信(RDP グラフィックスパイプライン)
   └─ Pstsc ヘルパー PowerShell(ウィンドウなしで実行)
        スタートメニューの一覧・アイコンを書き出し、セッション維持用の 1×1 ウィンドウを開く
        │
        │  RDP 接続 1 本(FreeRDP)          共有フォルダー \\tsclient\pstsc
        ▼
[Pstsc.app — Mac]
   ├─ リモートのウィンドウ 1 つ = 枠なしの Mac ウィンドウ 1 つ、マウス・キーボードを転送
   ├─ Windows 11 風スタートメニュー、接続・再接続・モード切り替え
   └─ アプリごとの小さな代理アプリ(Dock アイコン、Launchpad・Spotlight からの起動用)
```

- RDP 接続と RemoteApp の処理には [FreeRDP](https://www.freerdp.com) ライブラリを使っています。薄い C のラッパー([`Sources/PstscRDP`](Sources/PstscRDP))を Swift/AppKit のアプリから使います。
- アプリごとの Dock アイコンは、アプリごとに小さな .app を作って起動する方式です。ウィンドウ自体は Pstsc 本体が描画します。

### リモート PC で Pstsc が行うこと

透明性のために明記します。すべて Pstsc が接続したセッションの中だけで行われます。

- 接続時に、共有フォルダーの `helper.ps1` をウィンドウなしで実行します(`conhost --headless powershell`)。
  - `Get-StartApps` でスタートメニューの一覧を書き出します。
  - アプリのアイコン(96px)を書き出します。受け取り済みのものは飛ばします。
  - セッション維持用の 1×1 のウィンドウを 1 つ開いておきます。表示中のアプリのウィンドウがないと、Windows が RemoteApp セッションをサインアウトするためです。
  - 同じセッションに前回の接続の Pstsc ヘルパーが残っていれば、終了させて引き継ぎます。
- 常時のメモリ使用量は約 25MB です(PowerShell 約 10MB と conhost)。
- **リモート PC のリソース使用量** メニューを選ぶと、固定の測定スクリプト(`resources.ps1`)を 1 回実行します。

## Mac に保存されるもの

| 項目 | 場所 |
|---|---|
| パスワード | キーチェーン、サービス名 `com.pstsc.agent` |
| アドレス・ユーザー・設定 | `defaults read com.pstsc.agent` |
| 共有フォルダー、アプリ一覧、アイコン | `~/Library/Application Support/Pstsc/` |
| アプリごとの Dock 代理アプリ | `~/Library/Application Support/Pstsc/Apps/` |
| Launchpad・Spotlight 起動用アプリ | `~/Applications/Pstsc 앱/` |
| ログ | `~/Library/Logs/Pstsc/agent.log`(起動のたびに書き直し) |

## セキュリティについて

- サーバー証明書は初回接続時に信頼して保存します(TOFU)。その後、証明書が変わった場合は接続を拒否します。
- ホームフォルダーの共有をオンにしていると、リモート PC から Mac のホームフォルダーにアクセスできます。不要ならメニューでオフにしてください。
- ビルドしたアプリは開発者証明書ではなく ad-hoc 署名です。別の Mac にコピーして使うと Gatekeeper の警告が出ることがあります。

## 既知の制限

- **本物の Windows スタートメニュー、検索、アクションセンターは RemoteApp では送られてきません。** そのため、Pstsc は Mac 側で似たスタートメニューを描画しています。デスクトップモードでは本物のスタートメニューが開きます。
- Windows 11 のトースト通知は届きません。トレイアイコンのバルーン通知だけが Mac の通知になります。
- リモートのトレイアイコンを直接クリックすることはできません。トレイに隠れたアプリは、スタートメニューや Spotlight からもう一度起動すると開きます。
- リモートのウィンドウを直接クリックすると、Dock や ⌘Tab ではそのアプリではなく Pstsc がアクティブなアプリとして表示されます。
- Windows 11 のウィンドウのサイズ変更ハンドルは見えている枠の外側にあるため、つかめないことがあります。
- クリップボードの共有、リモートのマウスカーソルの形、Retina 解像度にはまだ対応していません。画面は Mac の 1 ポイントあたり 1 ピクセルで受け取ります。
- ディスプレイの接続・取り外しは、再接続するまで反映されません。
- Intel Mac にはまだ対応していません。配布用ビルドは Apple シリコン(arm64)のみが対象です。
- Apple の開発者証明書による署名・公証をしていないため、初回起動時に一度許可が必要です(インストールを参照)。

## トラブルシューティング

- **接続が切れてはつながるのを繰り返す**: 別の機器(Microsoft の Windows App など)が同じアカウントで接続していると、セッションを奪い合います。どちらか一方だけを使ってください。
- **「リモート PC はすでに使用中です」と表示される**: 誰か(または同じアカウント)がリモート PC の前でサインインして使っています。Windows Pro は同時に 1 セッションしか使えないため、アプリウィンドウモードでは接続できません。接続ウィンドウに出る **デスクトップモードで接続** ボタンを押すと、そのセッションを引き継げます(リモート PC はロックされます)。2 人が同時に使うのは Windows Pro では不可能で、Hyper-V の仮想マシンや Windows Server が必要です。
- **「already running」と表示されてすぐ終了する**: Pstsc がすでに起動しています。Pstsc は同時に 1 つしか起動できません。
- **アプリが起動しない**: リモート PC に `enable-remoteapp.reg` を適用したか確認してください。
- **その他**: `~/Library/Logs/Pstsc/agent.log` を確認してください。プライバシー保護のため、接続状態とエラーだけを記録し、ウィンドウのタイトル、起動したアプリ、リモート PC のアドレス、アカウントは記録しません。FreeRDP 自体のログにはリモート PC 名とアカウントが含まれるため、既定でオフです。デバッグするときだけ `WLOG_LEVEL=INFO swift run PstscAgent` のように有効にし、そのログは公開しないでください。

## プロジェクト構成

| パス | 内容 |
|---|---|
| `Sources/PstscRDP/` | FreeRDP を包む C コード: 接続スレッド、RemoteApp のウィンドウ情報、ウィンドウごとの画面、入力、アイコン、通知 |
| `Sources/PstscAgent/` | Mac アプリ本体(Swift/AppKit) |
| `Sources/PstscDockProxy/` | アプリごとの Dock アイコンと Launchpad 起動用の補助アプリ |
| `scripts/build-app.sh` | `Pstsc.app` のビルド(FreeRDP・OpenSSL 同梱)とインストール |
| `scripts/build-freerdp.sh` | 同梱する FreeRDP と OpenSSL をソースからビルド(GPL コーデックなし、macOS 14 以降) |
| `scripts/build-dmg.sh` | 配布用 DMG の作成 |
| `scripts/test-remoteapp.sh` | xfreerdp で RemoteApp の動作だけを確認するスクリプト |
| `remote/` | リモート PC に適用するレジストリファイル、テスト用 `.rdp` |
| `docs/images/` | README のスクリーンショット |
| `PLAN.md`、`PROGRESS.md` | 設計と開発記録(韓国語) |

## ライセンス

[MIT License](LICENSE)

## クレジット

- [FreeRDP](https://github.com/FreeRDP/FreeRDP)(Apache License 2.0): RDP プロトコルの実装
- [OpenSSL](https://www.openssl.org)(Apache License 2.0): TLS。どちらもアプリに同梱され、ライセンス全文は `Pstsc.app/Contents/Resources` にあります。
