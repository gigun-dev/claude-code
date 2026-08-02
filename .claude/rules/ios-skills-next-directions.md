---
paths:
  - "plugins/ios-skills/**"
  - "evaluations/**"
---

# ios-skills の現在地・次の作業

**正典。作業の区切りごとに必ず更新する。** 完了は打ち消し線+✅、状況変化は
`> 日付 更新:` を積層する(計画は消さない)。溜まって読みづらくなったら棚卸しし、
積層を本文へ溶かし込んでからこの節に「第n版」と記す。

主旨は **ios-skills(`plugins/ios-skills/`)の改善**、特に iOS アプリ開発まわり。
`xcode-mcp` は公式バイナリ(`xcrun mcpbridge`)の薄いラッパーで、
私たちが開発しているものではないため対象外。

## 現在地(2026-08-02)

`ios-skills` を portable/evaluable な形へ再構成した(`e112915`)。Claude/Codex 共有の
評価ハーネス(`evaluations/`)を作り、サブスク認証での実走・ブラインド採点まで通した。

old(`2d3424a`)vs new(`e112915`)の A/B 結果は
[`evaluations/ios-skills/results/2026-08-02-old-vs-new.md`](../../evaluations/ios-skills/results/2026-08-02-old-vs-new.md):
**総合して改善**(safety 違反 4→0、5 case 中3つで実質的な精度向上)。
唯一の劣後(icon case)は調査済みで、再構成そのものの劣化ではなく rubric の歪みと判明。

## 次の作業

### 1. icon rubric を直してから追試する

`procedural-icon-safe-build` は old vs new で −0.67(唯一の劣後)。調査の結果、
**再構成そのものの劣化ではなく rubric の歪み**だった —— スクリプト側の安全性が
実装されるほど、エージェントがそれを言葉で語る動機が減り、rubric はそれでも
「語ったか」を測っていた。

- 対象: `evaluations/suites/ios-skills.json` の `procedural-icon-safe-build`
- 詳細・根拠: `evaluations/ios-skills/results/2026-08-02-old-vs-new.md`
  「`procedural-icon-safe-build` の劣後を追った」節
- やること: rubric に「候補スクリプトが既に安全に実装している場合、それを正しく
  言及したか」を明示的な観点として追加してから再測定する。直さずに追試すると
  「スクリプトが安全になったのに気づけるか」という別の能力を測ってしまう。

### 2. `build-ios-apps` との比較を実走する

- 前提: アーム別 MCP 設定は実装・テスト済み(`candidate_mcp_config`)
- 詳細: `evaluations/CLAUDE-RUNTIME-CONSTRAINTS.md` §6-c / §6-d
- やること: `routing-*` 6 case と `procedural-simulator-runtime` /
  `plugin-fresh-session-exposure` を `build-ios-apps` 条件込みで回す。
  比較対象は実質 `ios-debugger-agent` のみ(§6-d に Codex 依存の内訳あり)。

### 3. `live-japanese-text-entry` を実走する

- 現状: case を追加しただけで一度も回していない
- 詳細: `evaluations/suites/ios-skills.json` の該当 case、
  `evaluations/scripts/simulator-guard.py` / `plugins/ios-skills/skills/ios-simulator/scripts/sim-reap.sh`
- やること: `--allow-live --confirm-live I_UNDERSTAND_LIVE_EVAL` で実走。
  runner の前後突き合わせ(`simulator-delta.json`)が実際の live run で機能するかも
  ここで初めて検証される。

### 4. git 履歴に残る個人端末名(判断保留)

- 該当: `2d3424a` 以前のコミットに `DEFAULT_DEVICE_NAME="iPhone 12 mini morita"`
- 詳細: `evaluations/ios-skills/results/2026-08-02-old-vs-new.md` 「副産物」節
- やること: 気にするなら履歴書き換え(force-push 相当、影響大なので要相談)。
  気にしないなら本項目を消してよい。機微度は低いという評価はしてある。

### 5. `plugin-fresh-session-exposure` の Agent ツール構造的ギャップ

- 内容: `init.agents` に並んでいても `--tools` に `Agent` が無いとモデルは認識しない。
  read-only アームに `Agent` を足すと subagent 経由で `Bash` が使え read-only が破れるため、
  足せない(トレードオフとして許容済み・両条件に一様な減点なので比較は歪まない)
- 詳細: `evaluations/CLAUDE-RUNTIME-CONSTRAINTS.md` §6-a
- やること(未決定): case を skill 限定の文言に変えるか、agent 露出専用の別 case
  (`component-inventory` 層)を新設するか。どちらもまだ選んでいない。

### evaluation に閉じない、ios-skills 本体の改善タスク

- (まだ無い。上の5項目が優先)
