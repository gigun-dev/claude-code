---
name: review
description: 自分の Claude Code / Codex セッションを実データで振り返り、時間・トークン・ツールの内訳・親子関係・worktree の扱いを確認する。ローカル JSONL だけで答える機能と、要求されたときだけ Langfuse のトレースを引く機能を備える(前者は資格情報もネットワークも要らない)。「セッションを振り返って」「subagent が遅い」「何に時間を使ってる?」「いくら使った?」「worktree がおかしい」「テレメトリ見て」「/telemetry:review」で発火。
---

# telemetry:review — 自分のセッションを観測データから振り返る

このスキルは読み込み時にコマンドを自動実行しない。対象を選んでから、スキルの配置場所にある
`../../bin/session-breakdown` を明示的に実行する。対象が決まっていない場合は、利用可能な
セッション ID を先に調べ、全期間・全プロジェクトを暗黙に読み込まない。

## どの道具を使うか

答えたい問いによって使う道具が違う。**上から順に試し、足りないときだけ下へ降りる。**

| 問い | 道具 |
|---|---|
| 「あの作業はどのセッションだったか」「いつ何をしたか」 | **cman**(`search_all` で Claude Code・Pi・Codex を横断)。探すのに使う |
| 「体ごとに何分かかったか」「Bash の内訳」「同じコマンドを何回走らせたか」「worktree の外へ書いたか」 | **`bin/session-breakdown`**。数えるのに使う。資格情報もネットワークも要らない |
| コスト・LLM 応答の中身・ツール別レイテンシ | 下の `summary.sh` / `query.sh`(Langfuse。資格情報が要る) |
| 上のどれでも答えられない | 生の JSONL を直接読む |

**ログの形はエージェントによって違う。** Claude Code は `~/.claude/projects/<project>/<session-id>.jsonl` で、
subagent の行は `isSidechain` が真の行として本線に混ざる場合と `subagents/agent-*.jsonl` に分かれる
場合がある。Codex は `~/.codex/sessions/**/rollout-*.jsonl` などの JSONL に
`session_meta`、`response_item`、`event_msg`、`token_usage_record` を記録する。
`session_meta.parent_thread_id` から親子を辿り、`token_usage_record.response_id` を重複排除して集計する。
Codex の usage は input / cached input / output / reasoning output / total を表示し、cached input と
reasoning output はそれぞれの部分集合として扱う。期間内に usage が無ければ `unavailable`、親子の
一部だけなら `partial` として、0 と誤認しない。

**セッションを指すときはセッション ID を使う。** パスはエージェントごとに違い、cman を使う経路では
不要になる。ID なら両方から辿れる。

## 使い方

1. 上の集計を読み、**費用のかかる所・時間のかかる所・失敗している所**を特定する。
2. 個別の裏取りは `scripts/query.sh`:
   ```sh
   scripts/query.sh errors 7       # 失敗したツール実行の一覧
   scripts/query.sh slow 7 10      # 取得した標本内で遅い順
   scripts/query.sh cost 7 10      # 取得した標本内で高い順
   scripts/query.sh trace <id>     # 1ターンを時系列で
   scripts/query.sh gen <obs_id>   # LLM 応答の中身(入出力・usage・コスト)
   ```
   Langfuse を使う場合も、対象期間・trace ID を選んだ後に要求されたサブコマンドだけを実行する。
3. 見つけた傾向から改善の要否を判断する。変更が必要なら根拠と対象を示し、根拠が足りなければ
   **変更不要 / 判断保留**と明記して終える:
   - 特定ツールの失敗が多い → CLAUDE.md / rules に予防を書く、または Hook で強制する
   - キャッシュ読み取りが伸びず入力トークンが毎回膨らんでいる → 常時ロードの設定を削る
   - 同じ外部リクエストを繰り返している → 手順を skill 化して固定する
   - 特定操作が毎回遅い → コマンドを変える、キャッシュする、subagent に渡す
   - 権限プロンプトで止まっている → `/fewer-permission-prompts` で allowlist を整える
   - 使われ方の実測は `/cclens:doctor`

送信側の仕組み(hook と observation の対応、generation を transcript から復元している理由)は
`plugins/telemetry/README.md`。

## 読むときの注意(データの癖)

- 中身を見るときは単体取得を使う。一覧 API `/api/public/v2/observations` のレスポンスには
  model / usage / input / output が**含まれない**。一覧だけ見て「コストが送れていない」と誤診
  しやすい(実際に一度誤診した)。`query.sh gen <id>` が単体取得
  `/api/public/observations/{id}` を使うので、中身はそちらで見る。
- 単位が非対称で、metrics API はミリ秒、observations API は秒(Langfuse 側の仕様)。
- API のバージョン表記が紛らわしい。製品の Langfuse v3 が非推奨で v4 が現行、そして v4 では
  `/api/public/v2/*` を使う。パス無し(`/api/public/traces`)は旧世代。
- 2026-08-08 より前のデータは信用しない。それ以前は (a) generation を送っておらずコストが全部 0、
  (b) ツール失敗は PostToolUseFailure を購読していなかったので1件も記録されず、代わりに出力の
  "rror" 文字列一致で誤検知したものが ERROR として積まれていた(実測で実際の 64 倍)。古い期間を
  集計に混ぜると嘘の傾向が出る。
- 未設定・ネットワーク不通なら Langfuse の集計はスキップされる(その旨を報告する)。資格情報は
  `~/.config/claude-code/langfuse.env`(600・git 管理外)、接続先は dotfiles 管理の
  `~/.config/claude-code/langfuse-endpoints.env`。REST API の `LANGFUSE_BASE_URL` と送信専用の
  `LANGFUSE_OTLP_ENDPOINT` は別設定。読み取りスクリプトは Metrics / Observations API を直接使い、
  グローバルCLIを要求しない。
- ローカル集計の例: `bin/session-breakdown --source claude --session <session-id> --from <ISO> --to <ISO> --main --json`
- Codex 集計の例: `bin/session-breakdown --source codex --session <thread-id> --from <ISO> --to <ISO> --json`
- 出力の `elapsed` は記録区間、`tool` は対応付けた tool の和集合、`wait` は明示的な待機、
  `unattributed` は分類できない残りを表す。残りをモデル思考時間や費用と解釈しない。
