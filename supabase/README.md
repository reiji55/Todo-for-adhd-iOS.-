# Claude連携（Supabase）

Hormeのデータを、Claudeのカスタムコネクタ（MCP）から読み書きできるようにする仕組み。

- `migrations/` … データを置く表 `horme_records` と、項目ごとに統合する関数 `horme_merge`。アプリとiCloudの同期と同じ形式（項目ごとの時刻つき）なので、iPhone・iPad・Claudeが同時に書いても互いの変更を消さない。
- `functions/horme/` … Edge Function。`/functions/v1/horme/<HORME_KEY>/sync` がアプリの同期先、`/mcp` がClaudeのコネクタの接続先。URLの最後の鍵だけで守る（task-3daysのTodoコネクタと同じ考え方）。鍵が違えば404。
  - `records.ts` … アプリの同期レコードの読み書き（TaskCore/SyncReplica.swift と同じ形）
  - `tools.ts` … MCPのツール（今日・日付指定・日付なしを読む、タスクの追加・修正・完了・削除、ルーティンのチェック、ボード、アイデア）
  - `tools.test.ts` … `node --test supabase/functions/horme/tools.test.ts` で動くテスト

## 設定

1. マイグレーションを適用する。
2. Edge Function `horme` をJWT検証なし（`verify_jwt: false`）でデプロイする。
3. シークレット `HORME_KEY` に32文字以上のランダムな文字列を設定する。
4. アプリの「設定とデータ」→「Claudeとの連携」に `https://<project>.supabase.co/functions/v1/horme/<HORME_KEY>` を貼って接続する。
5. 同じ画面の「Claudeのコネクタ用URLをコピー」で出る `…/mcp` を、claude.ai の「設定 → コネクタ → カスタムコネクタを追加」に登録する。
