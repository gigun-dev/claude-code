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
