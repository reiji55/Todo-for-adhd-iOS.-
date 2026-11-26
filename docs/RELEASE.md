# App Storeに公開する（App Store版 `com.hormeapp.ios`）

自分用のフル機能版（`io.github.reiji55.threedays`、アイコンにTEST）はいままでどおりTestFlightで使い続けます。
App Storeに出すのは、Claude連携とファイルのバックアップを含まない **App Store版** です。中身のコードは同じで、ビルドのときに分けています。

チームAPIキーとGitHubのSecretsは、フル機能版のときに設定したもの（docs/TESTFLIGHT.md）をそのまま使います。

## あなたがAppleのサイトでやること

### 1. 契約・税・口座（有料で出すのに必須）

[App Store Connect](https://appstoreconnect.apple.com/) → ビジネス（契約、税金、および口座情報）

- **有料App契約**に同意する
- **税務情報**を入力する（日本在住の個人。米国の税務フォームは画面の案内に従う）
- **銀行口座**を登録する（売上の振込先）

ここが「有効」になるまで、有料の価格は設定できません。

### 2. 手数料を15%にする（Small Business Program）

[App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/) に申し込む。年間売上100万ドル未満の間、手数料が30%から15%になります。

### 3. IDとiCloudの保存場所を作る

[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) で:

1. ＋ → **iCloud Containers** → Identifier に `iCloud.com.hormeapp.ios`（Descriptionは `Horme`）
2. ＋ → **App IDs** → App → Bundle ID を Explicit で `com.hormeapp.ios`（Descriptionは `Horme`）
   - Capabilities で **iCloud**（CloudKit）にチェック → Configure で 1 の `iCloud.com.hormeapp.ios` を選ぶ
   - **Push Notifications** にチェック（iCloud同期の知らせに使います）

ウィジェット（`com.hormeapp.ios.widgets`）と共有の拡張（`com.hormeapp.ios.share`）のIDは、最初の送信のときに自動で作られます。

### 4. App Store Connectにアプリを作る

[マイApp](https://appstoreconnect.apple.com/apps) → ＋ → 新規App

| 項目 | 値 |
| --- | --- |
| プラットフォーム | iOS |
| 名前 | Horme（使われていたら「Horme ‐ やり抜くタスク管理」など） |
| プライマリ言語 | 日本語 |
| バンドルID | `com.hormeapp.ios` |
| SKU | `Horme-iOS-001` |

ホーム画面に出る名前は、ここで付けた名前に関係なく「Horme」のままです。

### 5. iCloudの保存場所に、データの形を登録する

[CloudKit Console](https://icloud.developer.apple.com/) → `iCloud.com.hormeapp.ios` を選ぶ

1. **Schema** → 開発環境（Development）で **Import Schema** → リポジトリの `docs/cloudkit-schema.ckdb` を読み込む
2. **Deploy Schema Changes** で本番（Production）に反映する

これをしないと、App Store版でiCloud同期が動きません。

## ここまで済んだら（Claudeがやること）

6. GitHubの「iPhoneに送る（TestFlight）」を **edition: store** で実行し、App Store版をTestFlightに送る
7. App Store版を実機で一通り確かめてもらう（フル機能版と並べて入れられます）
8. 提出用のスクリーンショットを作る（iPhone 6.9インチ・iPad 13インチ）
9. ストアの文章を用意する（説明文・キーワード・サブタイトル・宣伝文）

## 最後にあなたがやること

10. App Store Connectで、8と9を入れ、次を設定する
    - サポートURL: `https://horme-indol.vercel.app`
    - プライバシーポリシーURL: `https://horme-indol.vercel.app/privacy.html`
    - カテゴリ: 仕事効率化
    - 年齢区分: 質問にすべて「なし」で4+
    - Appのプライバシー: 「データを収集する」→ **カスタマーサポート**（問い合わせの内容）。ユーザーに紐づけない・トラッキングに使わない
    - 価格: 350円（無料期間を設けるなら、価格の変更日を予約する）
    - 輸出コンプライアンス: 暗号化なし（ビルドに設定済み）
11. 審査に提出する（ふつう1〜3日）。通ったら公開日を選んで公開
