# 3日間タスク — iPhoneネイティブ試作

SwiftUIで作成したiOS 17以降向けのアプリです。「必須タスクを見失わず、そのときできるものから始められる」を中心に、既存の3日間タスクとHormeの考え方を組み合わせました。

**現状はソースの試作です。iOSアプリのビルド・署名・実機での動作確認は未実施です。インストール用のIPAは含みません。**

## 入っている機能

- **今日**：必須・今日までの締切、最大3件の着手候補、これからの締切、昨日／今日／明日の予定。
- **すべて**：日付なしや過去・未来を含む全タスク、検索、完了済みの表示。
- **アイデア**：文章をそのまま保存・編集。今日または日付なしのタスクへ変換。
- タイトルだけで追加。直接開始・完了・編集・予定日変更・削除・直前の操作の取り消し。
- 予定日と締切を別々に保存。MUSTに相当する「必須」は本人が指定。
- 任意の工程と次の一手、タスクごとの再開メモ、途中での切り替え。
- メモ・やり方と、AIへの引き継ぎを別々に保存。引き継ぎは共有シートで書き出し。
- 端末内への自動保存、JSONバックアップの書き出しと復元。
- 既存の `tasks.txt` からの追加取り込み（オンライン側への書き込みなし）。

通知、週のカレンダー表示、独立したガイド、端末間同期、AI自動連携はこの試作には含みません。

## 提案のルール

1. 今日までの締切と、予定日が来た必須タスクは上段に全件表示する。必須で日付なしなら今日から表示する。
2. それ以外から「明日締切 → 今日の予定 → 再開メモあり → その他」の順に最大3件。
3. 同じ段階の中で、選んだ調子に近い負荷を先にする。残りは最後に始めた日時／作成日時が古い順。並びの同点はIDで固定する。
4. 未来に予定したタスクはその日まで候補に入れない。未来の締切はホームの「これからの締切」に表示する。
5. 「候補から1時間外す」は提案だけに作用する。必須と全件一覧には影響しない。
6. アイデアは本人がタスクに変えるまで候補に混ぜない。

候補には理由を表示します。調子は任意で、初期値は指定なし。工程が0件でもそのまま開始できます。

## Macがない場合

専用リポジトリ [reiji55/Todo-for-adhd-iOS.-](https://github.com/reiji55/Todo-for-adhd-iOS.-) の `.github/workflows/ios.yml` で、GitHubのMacランナーを使って検証します。アプリのコードをmainへ更新すると自動実行されます。[Actions](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions) から結果を確認できます。

ActionsはSwiftのテスト、シミュレータ向けビルド、署名なしのiPhone向けビルド、シミュレータ起動・画面キャプチャを行います。保存する `ThreeDays-simulator.zip` はシミュレータ用です。実機向けもAppleの配布署名を付けるまではiPhoneにインストールできません。

iPhoneへ配布する次の段階では、Apple側の署名と配布環境が必要です。TestFlightを使うなら、Apple Developer Program、App Store Connectのアプリ登録、証明書／プロビジョニングと配布用CIの設定が必要になります。秘密情報はソースに書かず、CIのSecrets等で管理します。この試作には配布用の署名やTestFlightアップロードは設定していません。

## Mac／Xcodeで開く場合

1. Xcode 16以降で `ThreeDays.xcodeproj` を開く。
2. Schemeは `ThreeDays`、実行先はiPhone Simulatorを選ぶ。
3. Runで起動。設定の「サンプルで試す」で画面を確認できる。
4. 実機の場合はSigning & Capabilitiesで自分のTeamを選び、Bundle Identifierを自分用に変更する。現在の `jp.local.threedays` は仮の識別子。

CLIでの署名なしビルド：

```sh
xcodebuild -project ThreeDays.xcodeproj -scheme ThreeDays \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## 検証済みの範囲

Swift 6.1.2のLinux環境で `swift test` を実行し、22件のテストが成功しました。優先づけ、日付境界、提案の保留、工程なしでの開始、中断・切り替え、保存と復旧、既存タスク取り込みを検証しています。

SwiftUIファイルは構文チェック済みです。LinuxにはiOS SDKがないため、SwiftUIの型検査・iOSビルド・画面操作の検証はまだです。クラウドでの最新結果は上記Actionsを参照してください。

## 構成

```text
App/                    SwiftUIの画面と保存の仲介
Sources/TaskCore/        iOSに依存しないデータ・優先づけ・保存・取り込み
Tests/TaskCoreTests/     コア処理のテスト
ThreeDays.xcodeproj/     Xcodeプロジェクトと共有Scheme
.github/workflows/       クラウドのMacでの検証設定
```

Swiftファイルを増やした場合は `python3 scripts/generate-project.py` でプロジェクト参照を更新できます。

## データについて

端末内のApplication SupportにJSONを保存します。保存エラー時は変更前の状態を維持し、直前の保存を別ファイルに残します。読み取れないファイルは自動上書きしません。アプリ削除前にはバックアップを書き出してください。

`tasks.txt` の予定日、時間帯、種類、案件名、タイトル、完了、MUST、memo、next（AIへの引き継ぎ）を読み込みます。対応していない行は取り込み前に警告します。同じ予定日・時間帯・案件名・タイトルは重複として追加しません。ガイドの `board.json`、カレンダーの `week.json`、HormeのSupabaseデータの自動取り込みは含みません。

## 参考にした既存アプリ

- https://reiji55.github.io/task-3days/
- https://to-do-for-adhd.vercel.app

既存アプリ・オンラインデータには変更していません。
