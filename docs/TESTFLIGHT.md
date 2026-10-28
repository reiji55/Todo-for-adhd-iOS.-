# Macを使わずTestFlightで試す

このリポジトリには `Upload to TestFlight` ワークフローを用意しています。GitHubのMacで署名・アーカイブ・Appleへのアップロードを行います。アプリの登録と4つのSecretsの設定を、最初に一度行ってください。

## 1. Appleにアプリを登録する

[DeveloperのIdentifiers](https://developer.apple.com/account/resources/identifiers/list)を開き、＋ → App IDs → Appで登録します。

| 項目 | 入力する値 |
| --- | --- |
| Description | ThreeDays |
| Bundle ID | Explicitを選択し、`io.github.reiji55.threedays` |
| Capabilities | 追加の選択は不要 |

続いて[App Store ConnectのマイApp](https://appstoreconnect.apple.com/apps)で＋ → 新規Appを開きます。

| 項目 | 入力する値 |
| --- | --- |
| プラットフォーム | iOS |
| 名前 | 3日間タスク（使用済みなら「3日間タスク Reiji」など） |
| プライマリ言語 | 日本語 |
| バンドルID | `io.github.reiji55.threedays` |
| SKU | `ThreeDays-iOS-001` |
| ユーザアクセス | フルアクセス |

アプリ名の空き状況はApple側で確認されます。Bundle IDはコードと同じ値を選んでください。作成しただけではApp Storeに公開されません。

## 2. AppleのチームAPIキーを作る

[ユーザとアクセス](https://appstoreconnect.apple.com/access/users) → 統合（Integrations） → App Store Connect API → チームキー（Team Keys）を開きます。APIのアクセス申請が表示される場合は申請し、承認後に続けます。

キー名を `ThreeDays GitHub`、権限を **Admin** としてAPIキーを作成します。自動で配布証明書とプロビジョニングを作るため、この権限を使います。個人キーではなくチームキーを使用します。

Issuer ID、Key IDを控え、`AuthKey_XXXXXXXXXX.p8` をダウンロードします。Appleからの鍵のダウンロードは一度限りです。

## 3. GitHubに4つのSecretsを保存する

[このリポジトリのActions Secrets](https://github.com/reiji55/Todo-for-adhd-iOS.-/settings/secrets/actions)を開き、`New repository secret` から次の4件を追加します。

| Name（この文字列のまま） | Secretに入れる内容 |
| --- | --- |
| `ASC_ISSUER_ID` | Appleに表示されたIssuer ID |
| `ASC_KEY_ID` | Appleに表示された10文字のKey ID |
| `ASC_KEY_P8` | ダウンロードした `.p8` をテキストで開いた全文 |
| `CERTIFICATE_PRIVATE_KEY` | 別途用意した署名用 `certificate-private-key.pem` をテキストで開いた全文 |

旧手順の `APP_STORE_CONNECT_ISSUER_ID`、`APP_STORE_CONNECT_KEY_IDENTIFIER`、`APP_STORE_CONNECT_PRIVATE_KEY` も利用できます。 保存済みの `ASC_ISSURE_ID` という表記もIssuer IDとして読み取ります（`ASC_ISSUER_ID` が空の場合）。両方を保存している場合は上表の `ASC_...` を優先します。ワークフロー内ではCLIが要求する `APP_STORE_CONNECT_...` に渡します。`APPLE_TEAM_ID` はこの構成では使用せず、署名プロファイルからチームを取得します。

鍵は `-----BEGIN ...-----` から `-----END ...-----` まで、改行を含めて保存します。ファイル名だけ、Base64への再変換、チャットやリポジトリへの貼り付けは不要です。

署名用の `.pem` はAppleの `.p8` とは別のRSA鍵です。一度作った同じ鍵を使い続けることで、アップロードのたびに証明書を増やさずに済みます。手元で生成する場合はOpenSSLで `openssl genrsa -out certificate-private-key.pem 2048` を実行します。Macは不要です。

このワークフローはGitHub上で無料のオープンソースCLIを実行します。Codemagicのサービスへの登録は不要です。

## 4. アップロードする

[Upload to TestFlight](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/workflows/testflight.yml)を開き、`Run workflow` → `main` → `Run workflow` を実行します。

ワークフロー修正後は、上記の `Run workflow` で新しく実行してください。過去の失敗した実行を `Re-run jobs` で再実行すると、その実行時点の古いコード・設定が使われます。

処理は、入力の検証 → Appleでのアプリ存在確認 → 証明書・プロビジョニングの取得／初回作成 → 署名付きビルド → Appleへのアップロードの順です。通常のコード更新ではアップロードを実行しません。

Appleへの送信成功後も、Apple側の処理が終わるまでTestFlightに表示されない場合があります。App Store Connectで処理状況を確認してください。初回の署名・送信は、Secrets設定後に確認する必要があります。

## 5. 自分のiPhoneで試す

App Store Connectで対象アプリ → TestFlight → 内部テストを開き、グループを作成して自分のアカウントを追加します。処理済みビルドをグループに追加し、iPhoneの[TestFlight](https://apps.apple.com/jp/app/testflight/id899247664)で招待を受け入れてインストールします。

自分だけの内部テストから始められます。このワークフローは外部テストの審査申請やApp Store公開を行いません。

## 実装と確認の範囲

- Xcode 26.3 / iOS SDK 26.2を使用します。[Appleのアップロード要件](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)に合わせ、旧Xcode 16.4から更新しています。アプリの最低対応OSはiOS 17のままです。
- 一度のワークフロー実行ごとにビルド番号を更新し、再実行も別番号にします。
- 署名の素材は使い捨てランナーの一時ディレクトリに保存し、終了時に削除します。署名済みIPAと秘密鍵はArtifactsにアップロードしません。
- 現在のアプリは端末内のJSON保存が中心で、独自の暗号化機能はないため、`ITSAppUsesNonExemptEncryption = NO` を設定しています。今後暗号化機能を加える場合は見直してください。
- `CERTIFICATE_PRIVATE_KEY` に対応する配布証明書を作成・再利用します。既存証明書の自動失効は行いません。証明書数が上限の場合は、既存証明書の利用状況を確認して対処します。

Appleの初回登録やAPIのアクセス申請・契約同意は、アカウント所有者が行う必要があります。公式の[APIキー作成手順](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)も参照してください。
