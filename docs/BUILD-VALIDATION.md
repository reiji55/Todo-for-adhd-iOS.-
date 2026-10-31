# 2026年10月31日：0.3.0のTestFlightアップロード成功

- **Horme 0.3.0（ビルド1.6.1）のAppleへのアップロードが成功しました。** [配信実行](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41189182977)は `completed / success`。対象ソースは [`3eed539`](https://github.com/reiji55/Todo-for-adhd-iOS.-/commit/3eed539929715c5b10cfd6e67de97f09520fbf9d) です。
- コア62件＋配布設定15件のテスト、iCloudを含む署名権限の確認、署名付きアーカイブ、IPA書き出し、Appleの検証・アップロードが成功しています。アップロードログは `UPLOAD SUCCEEDED with no errors`。別途、同じソースの[ビルド確認](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41177422947)も成功し、iPhone・iPad両シミュレータの起動・データ移行を通過しています。
- 前回失敗時と同じ配布プロファイルを使用し、App ID・iCloudコンテナ・CloudKit・Production環境・Push権限がすべてOKでした。CloudKitの許可方式は `all services (*)` と確認でき、独自チェックの誤判定を修正したことで配信を完了できました。
- Apple側のスキーマ設定は利用者から完了報告を受けています。Appleでのアップロード後の処理、TestFlightでの表示・実機への更新、異なるApple Accountの2台での招待・同期はまだ確認していません。Apple側の処理完了後、両端末を更新し、[共有の使い方](ICLOUD-SHARING.md#使い方)に沿って確認します。

# 2026年10月31日：配布プロファイルの判定修正

- [0.3.0の最初の配信実行](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41166633467)では、コア62件とApple APIの認証が成功し、新しい配布プロファイルも作成されました。その後、独自のiCloud権限チェックで停止しています。アーカイブ・Appleへのアップロードには進んでいません。
- 確認処理が、Appleの[TN2415](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)に記載された `com.apple.developer.icloud-services = "*"`（全サービスの許可）を不許可と判定する不具合を修正しました。上記の再配信で同じプロファイルの許可方式を確認し、配信成功まで検証しました。
- 修正後も、対象App ID・iCloudコンテナの一致・Production環境・配布用Push権限をすべて検証します。ログには各項目のOK/MISSINGと許可方式だけを出し、秘密鍵・プロファイル本文・アカウント情報は出しません。
- 配布スクリプトのテスト15件がローカルとTestFlight用ワークフローの両方で成功しました。実機2台の同期確認は引き続き未実施です。

# 2026年10月30日：0.3.0のiCloud共有

- ソース [`d6e2d92`](https://github.com/reiji55/Todo-for-adhd-iOS.-/commit/d6e2d92d95df83f0b9ee2a1585eb8e1306edce8f) の[検証実行](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41073478624)は **success**。Xcode 26.3 / Swift 6.2.4で、コア62件＋配布設定9件のテスト、シミュレータDebug／署名なし実機Releaseのビルド、iPhone・iPadの起動確認がすべて成功しました。Linuxでもコア62件が成功しています。
- 以前の保存ファイルからタスク・ボード・ルーティンを引き継ぎ、共有の接続先が未設定のままであることを両シミュレータで確認しました。オフライン変更、競合の統合、削除記録、再起動、保存失敗、同じアイデアの同時タスク化、ボードの並び順、ルーティンの日別チェック、共有参加時の重複防止などはコアテストの対象です。
- [画面と起動記録](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41073478624/artifacts/12986902438)のiPhone・iPadの共有設定画面を目視確認しました。共有対象にタスク・アイデア・ボード・ルーティンが表示され、端末ごとの画面に収まっています。招待の確認画面や共有開始後の操作は、実際のApple Accountが必要なため未検証です。
- [シミュレータ用アプリ](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41073478624/artifacts/12986677581)のInfo.plistから、表示名Horme、バージョン0.3.0、既存Bundle ID、端末種別1,2、CloudKit招待対応、remote-notificationを確認しました。シミュレータ用アプリは実機へインストールする配布物ではありません。Artifactsの保存期限は2026年11月6日です。
- 10月30日時点では0.3.0の署名付きアップロードは未実施でした。10月31日に上記の配信が成功しています。別々のApple Accountを使う実機2台の同期・共有権限・実際の通知配信は、引き続き確認が必要です。

# 2026年10月30日：Hormeの名前と正式アイコン

- 利用者が選んだ「03 ORGANIZE」のアイコンを、透過なし・1024×1024のRGB PNGとして採用しました。ホーム画面の表示名、iPhoneの見出し、iPadのサイドバー、設定の名前をHormeに変更しています。
- ソース `c70c93100f46d062a96d2b80fa6c37758e9d6ae3` の[ビルド確認](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41001780895)が成功しました。コア22件＋配布設定6件、シミュレータ／実機向けビルド、iPhone・iPadの起動確認を通過しています。
- [画面の記録](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41001780895/artifacts/12953099843)でHormeの見出しとiPadレイアウトを目視確認しました。ビルドしたアプリのInfo.plistは表示名Horme・バージョン0.2.1・端末種別1,2で、iPhone/iPad用AppIconへの参照と実際の小サイズアイコンも確認しました。
- **0.2.1（ビルド1.4.1）のAppleへのアップロードが成功しました。** [送信結果](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/41002442763)。署名付きアーカイブ、IPA書き出し、Appleの検証・アップロード、ワークフロー全体が正常終了しています。Apple側の処理完了後にTestFlightから更新できます。
- Bundle ID `io.github.reiji55.threedays`、データ保存先、バックアップ形式を維持し、既存アプリへの更新として配布しています。新しい版の実機インストール・全操作の確認は利用者側で行います。

# 2026年10月29日の更新

- **0.2.0（ビルド1.3.1）のTestFlight送信が成功しました。** [送信結果](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40898562813)。ソース253a382、コア22件、署名付きアーカイブ、IPA書き出し、Appleの検証とアップロードが正常終了しています。Apple側の処理完了後にTestFlightから更新できます。
- 0.1.0（ビルド1.2.4）は署名・アーカイブ・検証・Appleへの送信が成功しました。[実行記録](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40859151910/attempts/4)
- 実行全体の失敗表示は送信後の完了メッセージによるもので、9093fc6で修正済みです。利用者がTestFlightからインストールできたことを確認しました。
- 0.2.0のiPad対応では、iPhone・iPad両方の端末種別、iPadの4方向とマルチタスク設定を、ビルドしたInfo.plistで検証します。両シミュレータにサンプルを入れて起動し、画面を保存します。
- [iPad対応の検証](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40896399166)で、コア22件・配布設定6件、シミュレータ／実機向けビルド、iPhone・iPad両方の起動確認が成功しました。[画面](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40896399166/artifacts/12908081570)を目視し、iPad Air 13-inch (M2)でサイドバーと2列のタスク表示、iPhoneで1列の表示を確認しました。サイドバーの見出しの省略を避けるため、最終調整でインライン表示に変更しています。
- iPad実機、回転中・ウインドウ変更中の操作、全タブの操作はまだ未確認です。回転・マルチタスクについては、この段階ではビルド設定とInfo.plistの検証です。
- 下記は初期版の検証履歴です。

# ビルド検証結果

## 2026年10月26日: TestFlight準備とXcode更新

[GitHub Actions 40266983396](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40266983396)は `completed / success` で終了しました。対象コードは [`a99bb936a363ba55beb60db416c555fc2511d799`](https://github.com/reiji55/Todo-for-adhd-iOS.-/commit/a99bb936a363ba55beb60db416c555fc2511d799) です。

- Xcode 26.3 / Swift 6.2.4 / iOS SDK 26.2。
- コアの22テストと配布設定の6テストが成功。
- iPhone SimulatorのDebug、署名なしiPhoneのReleaseが両方 `BUILD SUCCEEDED`。
- `io.github.reiji55.threedays` のシミュレータ起動とPNG保存が成功。
- [画面・起動記録](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40266983396/artifacts/12627041165)と[シミュレータ用アプリ](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/40266983396/artifacts/12626667151)を7日間保存。

TestFlight用の手動ワークフローと[初回設定手順](TESTFLIGHT.md)を追加しました。APIキー・署名用鍵をGitHub Secretsに設定する必要があるため、Appleへの認証・配布署名・アップロードはまだ実行していません。ビルドの成功はTestFlightへの配信成功を意味しません。画面全体の操作テストと実機テストも未実施です。

## 2026年10月22日: 初回ビルド

2026年10月22日（UTC）に実行した[GitHub Actions](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/39791244400)は `completed / success` で終了しました。2026年10月23日に最終状態を確認しています。

- 対象コミット: [`5cfde6601ae09211d2ef71a9799468074e2fdcbd`](https://github.com/reiji55/Todo-for-adhd-iOS.-/commit/5cfde6601ae09211d2ef71a9799468074e2fdcbd)
- 環境: GitHubの `macos-15` ランナー、Xcode 16.4（16F6）、Swift 6.1.2、iOS SDK 18.5
- 対応OS: iOS 17以降

| 検証 | 結果 |
| --- | --- |
| `swift test` | 22件成功、失敗0件 |
| iPhone Simulator向けDebugビルド | `BUILD SUCCEEDED` |
| iPhone向けReleaseビルド（署名なし） | `BUILD SUCCEEDED` |
| シミュレータへのインストールと起動 | 成功。ログに `jp.local.threedays: 8189` |
| シミュレータ画面のPNG保存 | 成功。`ci-results/today.png` |
| ビルドと画面のArtifactsへの保存 | 成功 |

## ダウンロード

- [ThreeDays-screen](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/39791244400/artifacts/12432395195): `today.png` と起動記録。
- [ThreeDays-simulator](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/39791244400/artifacts/12430878759): シミュレータ用アプリ。ダウンロードしたアーカイブ内の `ThreeDays-simulator.zip` を展開して利用します。

Artifactsの保存期間は7日間です。期限切れの場合はActionsの `Run workflow` から再生成できます。ダウンロードにはGitHubへのログインが必要な場合があります。

## 検証の範囲

起動と画面保存は自動処理の成功を確認したものです。画面の目視確認と、全操作を通したUIテストは未実施です。タスクの優先づけ・中断・切り替え・保存・取り込みなどはコアの単体テストで確認しています。

iPhone実機へのインストール、実機での操作、Appleの配布署名、TestFlightへのアップロードは未実施です。シミュレータ用アプリや署名なしのビルドを、そのままiPhoneにインストールすることはできません。

TestFlightで配布するには、原則有料の[Apple Developer Program](https://developer.apple.com/jp/programs/)とApp Store Connectでの登録・署名設定が必要です。TestFlight自体の追加利用料や、テスター側の登録料はありません。無料アカウントでXcodeから自分のデバイスへ入れる方法はありますが、[署名の有効期間は7日間](https://developer.apple.com/help/account/basics/about-your-developer-account)です。
