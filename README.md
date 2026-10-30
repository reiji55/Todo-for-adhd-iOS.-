# Horme — iPhone・iPadネイティブアプリ

SwiftUIで作成したiOS 17以降向けのタスク管理アプリ、Hormeです。「必須タスクを見失わず、そのときできるものから始められる」を中心に、既存の3日間タスクとHormeの考え方を組み合わせました。

## 0.3.0：iCloudで端末間のデータ共有

別々のApple AccountのiPhone/iPadで、タスク・アイデア・メモ・完了状態を共有する機能を追加しました。初回は「設定とデータ」から共有を開始し、もう片方の端末でiCloudの招待を承認します。入力は端末に保存し、未送信の変更を保持して再接続時に同期します。既存データは移行し、共有開始時に件数を確認して統合します。

**Apple側のiCloud権限・Productionスキーマ設定と、異なるApple Accountの実機2台での確認が必要です。** [設定・使い方・競合の扱い](docs/ICLOUD-SHARING.md)。下記の0.2.1の配布実績は、0.3.0の実機同期が検証済みであることを意味しません。

**Horme 0.2.1（ビルド1.4.1）の署名・ビルド・Appleへのアップロードが完了しました。採用アイコンとHormeの表示名を反映しています。iPhone・iPadシミュレータの起動・画面と、ビルド済みアプリのアイコンを確認済みです。** [検証結果](docs/BUILD-VALIDATION.md)

## 名前とアイコン（0.2.1）

アプリの表示名をHormeに変更しました。内発的な原動力を表すケンタウロスと、思いつきをタスクに整理する重なった面を組み合わせた、利用者が選んだ「03 ORGANIZE」のオレンジのアイコンを採用しています。

同じアプリへの更新として配布します。Bundle ID・保存先・バックアップ形式を維持し、既存のタスクとアイデアを引き継ぎます。

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

## iPadの表示（0.2.0）

- iPhone・iPadの両方にネイティブ対応。iPadではサイドバーで今日・すべて・アイデアを切り替えます。
- 今日の画面は、表示領域が広いと必須・締切と候補・予定を2列に表示します。左右は別々にスクロールできます。
- 狭いウインドウや大きいアクセシビリティ文字サイズでは1列に戻ります。iPadの縦横回転とマルチタスクに対応する設定です。
- 全タスクは幅に応じたカード一覧、アイデアは読みやすい行幅で表示します。
- 同じBundle IDと保存形式を使います。TestFlightで更新すると、この端末内のタスクを引き継ぎます。

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

ActionsはSwiftのテスト、シミュレータ向けビルド、署名なしのiPhone向けビルド、iPhone・iPadシミュレータの起動・画面キャプチャを行います。保存する `ThreeDays-simulator.zip` はシミュレータ用です。実機向けもAppleの配布署名を付けるまではiPhoneにインストールできません。

iPhoneへ配布するための `iPhoneに送る（TestFlight）` ワークフローを追加しています。[初回設定の手順](docs/TESTFLIGHT.md)に沿って、Appleでのアプリ登録とGitHub Secretsを設定すると、クラウドで署名してアップロードできます。署名・Appleへの送信は、認証情報の設定後に実行・確認する必要があります。

[Apple Developer Program](https://developer.apple.com/jp/programs/)は原則年額99米ドル相当で、TestFlightの利用は会費に含まれます。テスターは無料です。

## Mac／Xcodeで開く場合

1. Xcode 26.3以降で `ThreeDays.xcodeproj` を開く。
2. Schemeは `ThreeDays`、実行先はiPhone Simulatorを選ぶ。
3. Runで起動。設定の「サンプルで試す」で画面を確認できる。
4. 実機の場合はSigning & Capabilitiesで自分のTeamを選ぶ。Bundle Identifierは `io.github.reiji55.threedays`。自分のAppleアカウントに同じIDを登録する。

CLIでの署名なしビルド：

```sh
xcodebuild -project ThreeDays.xcodeproj -scheme ThreeDays \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## 検証済みの範囲

2026年10月26日の[Xcode 26.3での再検証](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40266983396)も正常終了しています。コア22件＋配布設定6件のテスト、シミュレータ／署名なしiPhone向けビルド、シミュレータ起動と画面保存が成功しました。その後、2026年10月29日に0.1.0（ビルド1.2.4）の署名付きアップロードが成功しました。

2026年10月22日の[GitHub Actions](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/39791244400)が正常終了しました。Xcode 16.4 / Swift 6.1.2で、コアの22テスト、シミュレータ向けDebugビルド、署名なしのiPhone向けReleaseビルド、シミュレータへのインストール・起動・PNG保存に成功しています。Linuxでの22テストも成功済みです。

コアのテストは優先づけ、日付境界、提案の保留、工程なしでの開始、中断・切り替え、保存と復旧、既存タスク取り込みを検証しています。0.1.0は配布署名・TestFlightアップロードと利用者によるインストールまで確認済みです。画面操作全体やiPadでの実機確認は別途必要です。証跡とダウンロード先は[検証結果](docs/BUILD-VALIDATION.md)に記録しています。

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
