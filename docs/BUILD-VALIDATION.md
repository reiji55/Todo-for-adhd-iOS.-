# ビルド検証結果

## 最新：2026年10月23日（Xcode 26）

[GitHub Actions](https://github.com/reiji55/Todo-for-adhd-iOS.-/actions/runs/39943886578) が `completed / success` で終了しました。ブランチ `claude/testflight-setup`、コミット `e783676`。

- 環境: GitHubの `macos-26` ランナー、Xcode 26.6（17F113）。App Store Connectへのアップロードに必要なiOS 26 SDKでビルドしています。
- 対応OS: iOS 17以降

| 検証 | 結果 |
| --- | --- |
| `swift test` | 24件成功、失敗0件 |
| iPhone Simulator向けDebugビルド | `BUILD SUCCEEDED` |
| iPhone向けReleaseビルド（署名なし） | `BUILD SUCCEEDED` |
| シミュレータへのインストールと起動 | 成功。ログに `io.github.reiji55.threedays: 7508` |

TestFlightへのアップロード（`testflight.yml`）は、Apple側の設定とSecrets登録が済むまで実行できないため未検証です。

## 初回：2026年10月22日（Xcode 16.4）

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
