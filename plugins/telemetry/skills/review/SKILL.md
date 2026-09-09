---
name: review
description: 自分の Claude Code セッションを Langfuse のトレースから振り返り、コスト・トークン・ツール別レイテンシ・失敗・サブエージェントの傾向を見て設定改善につなげる。「セッションを振り返って」「どのツールで時間を使ってる?」「いくら使った?」「テレメトリ見て」「/telemetry:review」で発火。
---

# telemetry:review — 自分のセッションを観測データから振り返る

```!
bash "${CLAUDE_SKILL_DIR}/scripts/summary.sh" 7
```

## 使い方

1. 上の集計を読み、**金を食っている所・時間を食っている所・失敗している所**を特定する。
2. 個別の裏取りは `scripts/query.sh`:
   ```sh
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" errors 7       # 失敗したツール実行の一覧
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" slow 7 10      # 遅い順
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" cost 7 10      # 高い LLM 応答の順
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" trace <id>     # 1ターンを時系列で
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" gen <obs_id>   # LLM 応答の中身(入出力・usage・コスト)
   ```
3. 見つけた傾向を設定変更に落とす。観測しただけでは何も改善しないので、ここまでやって終わりとする:
   - 特定ツールの失敗が多い → CLAUDE.md / rules に予防を書く、または Hook で強制する
   - キャッシュ読み取りが伸びず入力トークンが毎回膨らんでいる → 常時ロードの設定を削る
   - 同じ外部リクエストを繰り返している → 手順を skill 化して固定する
   - 特定操作が毎回遅い → コマンドを変える、キャッシュする、subagent に逃がす
   - 権限プロンプトで止まっている → `/fewer-permission-prompts` で allowlist を整える
   - 使われ方の実測は `/cclens:doctor`

送信側の仕組み(hook と observation の対応、generation を transcript から復元している理由)は
`plugins/telemetry/README.md`。

## 読むときの注意(データの癖)

- 中身を見るときは単体取得を使う。一覧 API `/api/public/v2/observations` のレスポンスには
  model / usage / input / output が**含まれない**。一覧だけ見て「コストが送れていない」と誤診
  しやすい(実際に一度誤診した)。`query.sh gen <id>` が単体取得
  `/api/public/observations/{id}` を叩くので、中身はそちらで見る。
- 単位が非対称で、metrics API はミリ秒、observations API は秒(Langfuse 側の仕様)。
- API のバージョン表記が紛らわしい。製品の Langfuse v3 が非推奨で v4 が現行、そして v4 では
  `/api/public/v2/*` を使う。パス無し(`/api/public/traces`)は旧世代。
- 2026-08-08 より前のデータは信用しない。それ以前は (a) generation を送っておらずコストが全部 0、
  (b) ツール失敗は PostToolUseFailure を購読していなかったので1件も記録されず、代わりに出力の
  "rror" 文字列一致で誤検知したものが ERROR として積まれていた(実測で実際の 64 倍)。古い期間を
  集計に混ぜると嘘の傾向が出る。
- 未設定・ネットワーク不通なら集計はスキップされる(その旨が上に出る)。資格情報は
  `~/.config/claude-code/langfuse.env`(600・git 管理外)。
