# TestFlightで自分のiPhoneに入れるまで

Macがなくても、GitHub ActionsのMacでビルド・署名し、TestFlightへ送れるようにしてあります。Apple側とGitHub側の設定は本人のアカウントでしかできないため、以下を一度だけ行ってください。所要30分ほどです。

PCのブラウザで進めるのが楽です。iPhoneだけでも可能ですが、手順4のファイルの扱いに一手間かかります。

## 1. チームIDを控える

1. https://developer.apple.com/account を開く。
2. 「メンバーシップの詳細」にある **チームID**（英数字10文字）を控える。

## 2. Bundle IDを登録する

アプリの識別子です。コードには `io.github.reiji55.threedays` を設定済みです。

1. https://developer.apple.com/account/resources/identifiers/list を開き、「＋」。
2. 「App IDs」→「App」を選んで続ける。
3. Description に `3日間タスク`、Bundle ID は「Explicit」で `io.github.reiji55.threedays` を入力。
4. Capabilities は何も追加せず、「Continue」→「Register」。

別のIDにしたい場合は、`scripts/generate-project.py` の `PRODUCT_BUNDLE_IDENTIFIER` と `scripts/simulator-smoke.sh` を同じ値に変更し、`python3 scripts/generate-project.py` を実行します。一度TestFlightに出したあとで変えると、別アプリ扱いになりデータも引き継がれません。

## 3. App Store Connectにアプリを作る

1. https://appstoreconnect.apple.com/apps を開き、「＋」→「新規App」。
2. プラットフォーム：iOS
3. 名前：App Storeで表示される名前。ほかのアプリと重複すると登録できません（例：「3日間タスク」が使えなければ「3日間タスク ノート」など）。ホーム画面の表示名はこれとは別で、「3日間タスク」のままです。
4. プライマリ言語：日本語
5. バンドルID：手順2で登録した `io.github.reiji55.threedays` を選ぶ。
6. SKU：自分用の管理番号。`threedays-001` などで可。
7. ユーザアクセス：フルアクセス

ここで公開はされません。TestFlightだけ使う間は、審査用の説明文やスクリーンショットも不要です。

## 4. App Store Connect APIキーを作る

GitHub ActionsがAppleへログインせずに署名・アップロードするための鍵です。

1. App Store Connect →「ユーザとアクセス」→「統合」→「App Store Connect API」。
2. 初回は「アクセスをリクエスト」が出るので同意する。
3. 「チームキー」の「＋」（キーを生成）。名前は `GitHub Actions`、アクセスは **Admin**。
   - クラウド署名（証明書を手元に置かない方式）にはAdminが必要です。
4. 表示される **Issuer ID** と、作ったキーの **キーID** を控える。
5. 「APIキーをダウンロード」で `AuthKey_XXXXXXXXXX.p8` を保存する。**ダウンロードは1回しかできません。**

この鍵があればアプリのアップロードや設定変更ができます。人に渡したり、リポジトリに入れたりしないでください。漏れたときは同じ画面で「取り消す」を押せば無効になります。

iPhoneでダウンロードした場合は、ファイルアプリで名前を `AuthKey.txt` に変えると中身を表示してコピーできます。

## 5. GitHubにSecretsを登録する

1. https://github.com/reiji55/Todo-for-adhd-iOS.-/settings/secrets/actions を開く。
2. 「New repository secret」で、次の4つを1つずつ登録する。

| Name | 値 |
| --- | --- |
| `APPLE_TEAM_ID` | 手順1のチームID |
| `ASC_ISSUER_ID` | 手順4のIssuer ID |
| `ASC_KEY_ID` | 手順4のキーID |
| `ASC_KEY_P8` | `.p8` ファイルの中身すべて（`-----BEGIN PRIVATE KEY-----` から `-----END PRIVATE KEY-----` まで） |

Secretsは登録後に誰も読み出せず、Actionsのログにも伏せ字で出ます。

## 6. ビルドを送る

1. https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/workflows/testflight.yml を開く。
2. 「Run workflow」→ ブランチは `main` →「Run workflow」。
3. 15分ほどで緑のチェックになれば送信完了です。そのあとApple側の処理に5〜30分かかります。

ビルド番号は実行ごとに自動で増えます。見た目のバージョン（0.1.0）を上げたいときは `scripts/generate-project.py` の `MARKETING_VERSION` を変えて再生成します。

## 7. iPhoneに入れる

1. App Store Connect → 作ったアプリ →「TestFlight」タブ。ビルドが「テスト可能」になるまで待つ。
2. 左の「内部テスト」の「＋」でグループを作り（名前は「自分」など）、テスターに自分を追加し、ビルドを追加する。
3. iPhoneにApp Storeから「TestFlight」アプリを入れ、届いた招待メール（またはTestFlightアプリ）から「インストール」。

内部テストはAppleの審査なしで使えます。TestFlightのビルドは90日で期限切れになるので、それまでに新しいビルドを送ってください。

## うまくいかないとき

Actionsの失敗した手順を開き、赤いエラー行を確認します。

| エラーの例 | 対処 |
| --- | --- |
| `GitHubのSecretsが未設定です` | 手順5の名前が一字一句合っているか確認 |
| `No profiles for 'io.github.reiji55.threedays' were found` / `No Accounts` | 手順2のBundle ID登録と、手順4のキーがAdminか確認 |
| `Cloud signing permission error` | 手順4のキーをAdminで作り直し、`ASC_KEY_ID` と `ASC_KEY_P8` を差し替える |
| `No suitable application records were found` | 手順3のアプリ作成と、そのバンドルIDが一致しているか確認 |
| `The bundle version must be higher` | もう一度実行すれば番号が増えます |
| `SDK version issue`（iOS 26 SDK） | 2026年4月からXcode 26以降でのビルドが必須です。ワークフローは `macos-26` ランナー（Xcode 26）を使っています |

この手順でのアップロードは、まだ実際のApple アカウントで通したことがありません。初回で失敗した場合は、エラー行をそのまま共有してもらえれば直します。
