---
name: review
description: 自分の Claude Code セッションを Langfuse のトレースから振り返り、ツール別の実行数・レイテンシ・失敗の傾向を見て設定改善につなげる。「セッションを振り返って」「どのツールで時間を使ってる?」「テレメトリ見て」「/telemetry:review」で発火。
---

# telemetry:review — 自分のセッションを観測データから振り返る

```!
bash "${CLAUDE_SKILL_DIR}/scripts/summary.sh" 7
```

## 何を見ているか

Claude Code のフック(`~/.claude/hooks/langfuse-otlp.sh`)が、ターン・ツール実行・
サブエージェントを **OTLP トレース**として Langfuse へ送っている。上はその集計。

- **Trace = 1ターン**(prompt_id 単位)、**子 span = ツール実行 / サブエージェント**
- ツール失敗は `level=ERROR` で送っている

## 使い方

1. 上の集計を読み、**時間を食っている所と失敗が多い所**を特定する。
2. 個別の裏取りは `scripts/query.sh`:
   ```sh
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" errors 7        # 失敗した観測の一覧
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" slow 7 10       # 遅い順
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" trace <id>      # 1ターンを時系列で
   "${CLAUDE_SKILL_DIR}/scripts/query.sh" raw 'v2/observations?limit=5'
   ```
3. **見つけた傾向を設定変更に落とす**(ここが本題。観測しただけでは何も改善しない):
   - 特定ツールの失敗が多い → CLAUDE.md / rules に予防を書く、または Hook で強制する
   - 同じ外部リクエストを繰り返している → 手順を skill 化して固定する
   - 特定操作が毎回遅い → コマンドを変える、キャッシュする、subagent に逃がす
   - 権限プロンプトで止まっている → `/fewer-permission-prompts` で allowlist を整える
   - 設定そのものの健全性は `/harness:doctor`、方針の再検討は `/harness:audit`

## 読むときの注意(データの癖)

- **ERROR は上振れする。** 判定はツール出力に `rror` を含むかの粗い一致なので、
  出力に error の語が出るだけの成功も拾う。件数の傾向は使えるが、絶対値は信じない。
- **コストは載っていない。** フックが usage/cost を送っていないので `totalCost` は 0。
  トークン・コストの推移は Grafana Cloud 側(組み込み OTel メトリクス)を見る。
- **単位が非対称。** metrics API はミリ秒、observations API は秒(Langfuse 側の仕様)。
- **API のバージョン表記が紛らわしい。** 製品の Langfuse v3 が非推奨で v4 が現行、
  そして v4 では `/api/public/v2/*` を使う。パス無し(`/api/public/traces`)は旧世代。
- 未設定・ネットワーク不通なら集計はスキップされる(その旨が上に出る)。
  資格情報は `~/.config/claude-code/langfuse.env`(600・git 管理外)。
