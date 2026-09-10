# telemetry — 自分の Claude Code セッションを Langfuse で観測する

Claude Code のフック(`~/.claude/hooks/langfuse-otlp.sh`)が、セッションの中身を OTLP トレースと
して Langfuse へ送る。`/telemetry:review`(`skills/review/SKILL.md`)はそれを集計して読む側で、
このファイルは送る側の対応関係を書いておく場所。

## Claude Code と Langfuse observation の対応

| Claude Code | Langfuse の observation |
|---|---|
| 1ターン(prompt_id) | Trace + root span `claude-code turn` |
| LLM 応答1回 | generation(モデル名・トークン・コスト・thinking を含む出力) |
| ツール実行 | tool(成功=DEFAULT / 失敗=ERROR) |
| サブエージェント | agent(配下に generation と tool がぶら下がる) |

## generation だけ復元している理由

hook はツールの前後しか知らず、LLM の出力もトークン数も渡してこないので、generation は hook
イベントからは作れない。そこで Stop / SubagentStop の時に transcript の JSONL を解析して復元
している。この復元が無いと、コストも思考の連鎖も一切見えない。

資格情報は `~/.config/claude-code/langfuse.env`(600・git 管理外)に置く。未設定またはネット
ワーク不通なら、集計はスキップされてその旨が出る。

## bin/session-breakdown — transcript だけで時間の内訳を出す

`/telemetry:review` は Langfuse を読む。`bin/session-breakdown` は資格情報もネットワークも
要らず、`~/.claude/projects/**/*.jsonl` だけを読む。hook が落ちていた区間や、Langfuse を
設定していないマシンでも走る。

```sh
plugins/telemetry/bin/session-breakdown --project <repo のパス> --since 1d
plugins/telemetry/bin/session-breakdown --project <repo のパス> --since 3d --main --json
```

体(subagent 1 体、または本線 1 セッション)ごとに、実時間・ツール呼び出し数・トークン・
Bash の所要とコマンド種別の内訳・同一コマンドの再実行・worktree の扱いを出す。数え方の定義と
Bash の分類規則は毎回出力の先頭に印字される(分類を変えたら過去の数字と比べられなくなるため)。

subagent の行の置き場は Claude Code のバージョンで 2 通りある。`<session>/subagents/agent-*.jsonl`
に分離されている場合と、本線の JSONL に `isSidechain: true` で混在している場合で、どちらも読む。

ログから出せないものは出さない。モデルの思考時間とツール実行時間の切り分け、本線が利用者の
入力を待っていた時間、subagent の起動遅延、worktree が後片付けされたかどうかは、いずれも
transcript に無い。
