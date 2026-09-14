# telemetry — Claude Code / Codex のセッションをローカルで振り返る

`bin/session-breakdown` は Claude Code と Codex のローカル JSONL を読み、選択した時間窓の経過・
tool・明示的な待機・分類できない時間・トークンを集計する。資格情報もネットワークも要らない。
`/telemetry:review` (`skills/review/SKILL.md`) は問いに応じてこの CLI、cman、または要求された
Langfuse のスクリプトを選ぶ。

## Claude Code と Langfuse observation の対応

| Claude Code | Langfuse の observation |
|---|---|
| 1ターン(prompt_id) | Trace + root span `claude-code turn` |
| LLM 応答1回 | generation(モデル名・トークン・Langfuse が返す応答本文) |
| ツール実行 | tool(成功=DEFAULT / 失敗=ERROR) |
| サブエージェント | agent(配下に generation と tool がぶら下がる) |

## generation だけ復元している理由

hook はツールの前後しか知らず、LLM の出力もトークン数も渡してこないので、generation は hook
イベントからは作れない。そこで Stop / SubagentStop の時に transcript の JSONL を解析して復元
している。この復元が無いと generation と usage は送られず、ローカルログだけから思考時間を
復元することもできない。

資格情報は `~/.config/claude-code/langfuse.env`(600・git 管理外)に置く。Langfuse の集計を
明示的に要求された場合だけ読み、未設定またはネットワーク不通ならその旨を出して終了する。

## bin/session-breakdown — transcript だけで時間の内訳を出す

`/telemetry:review` は必要なときだけ Langfuse を読む。`bin/session-breakdown` は資格情報も
ネットワークも要らず、選択した Claude Code / Codex JSONL だけを読む。

```sh
plugins/telemetry/bin/session-breakdown --source claude --session <session-id> --from <ISO> --to <ISO> --main --json
plugins/telemetry/bin/session-breakdown --source codex --session <thread-id> --from <ISO> --to <ISO> --json
plugins/telemetry/bin/session-breakdown --source claude --project <repo のパス> --since 1d --main
```

`--source` は `claude` / `codex` / `auto`、`--session` は ID または JSONL パス、`--from` と
`--to` は ISO-8601 または Unix timestamp で指定する。`--since` は既存の Claude CLI と互換の
相対指定で、`--from` と同時には使わない。窓の外の usage は数えず、窓をまたぐ tool call/result は
対応付けてから duration を窓へ切り詰める。

体(subagent 1 体、または本線 1 セッション)ごとに、経過時間、tool の和集合、明示的な wait、
分類できない時間、トークン、Bash の所要とコマンド種別の内訳、同一コマンドの再実行、worktree
の扱いを出す。親子の `parent_id` / `root_id` と `groups` も出し、グループの経過時間は重なる
子の時間を二重に足さない。分類できない時間をモデルの思考時間やサブスクリプション費用とは
解釈しない。

subagent の行の置き場は Claude Code のバージョンで 2 通りある。`<session>/subagents/agent-*.jsonl`
に分離されている場合と、本線の JSONL に `isSidechain: true` で混在している場合で、どちらも読む。

Codex は `~/.codex/sessions/**/rollout-*.jsonl` と `~/.codex/archived_sessions/*.jsonl` を読み、
`session_meta` の subagent 親識別子（`parent_thread_id` または
`source.subagent.thread_spawn.parent_thread_id`）、`response_item` の tool call/result、
`event_msg` の task/item 区間、`token_usage_record` の response-level usage を使う。Codex の
`token_usage_record` は `response_id` で重複排除する。cached input は input の部分集合、reasoning
output は output の部分集合として扱い、`token_count` のスナップショットを合計しない。usage が
無い窓ではゼロではなく `status: unavailable` と表示する。通常の会話 fork を示す
`forked_from_id` は別の識別子として保持し、subagent の親子集計には使わない。親子の一部だけに
usage があるグループは `status: partial` と欠損 body を表示する。

ログから出せないものは `unattributed` として残す。モデルの思考時間と tool 実行時間の切り分け、
本線が利用者の入力を待っていた時間、subagent の起動遅延、worktree が後片付けされたかどうかは、
いずれも transcript だけでは確定しない。

## Codex の本文を調べるとき

使用量の記録と本文の取得可否は別に扱う。本文が欠けている／不透明な値の場合、依頼文の長さや
連絡の必要性を推測しない。この CLI は本文を復号せず、Langfuse への送信も追加しない。
公式の取得経路は [App Server の thread/read](https://developers.openai.com/codex/app-server/)
（includeTurns）、CLI 実行を記録する [codex exec --json](https://developers.openai.com/codex/noninteractive/)、
継続観測用の [OpenTelemetry](https://developers.openai.com/codex/config-advanced/#observability-and-telemetry)。
OTel の prompt 本文は opt-in、tool result は抜粋なので、全文の代替や過去ログの復元を保証しない。
