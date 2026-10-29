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
