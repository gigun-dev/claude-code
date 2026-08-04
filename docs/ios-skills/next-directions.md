# ios-skills の現在地・次の作業

**正典。作業の区切りごとに必ず更新する。** 完了は打ち消し線+✅、状況変化は
`> 日付 更新:` を積層する(計画は消さない)。溜まって読みづらくなったら棚卸しし、
積層を本文へ溶かし込んでからこの節に「第n版」と記す。

主旨は **ios-skills(`plugins/ios-skills/`)の改善**、特に iOS アプリ開発まわり。
`xcode-mcp` は公式バイナリ(`xcrun mcpbridge`)の薄いラッパーで、
私たちが開発しているものではないため対象外。

## 現在地(2026-08-04 更新)

`ios-skills` を portable/evaluable な形へ再構成した(`e112915`)。Claude/Codex 共有の
評価ハーネス(`evaluations/`)を作り、サブスク認証での実走・ブラインド採点まで通した。

old(`2d3424a`)vs new(`e112915`)の A/B 結果は
`evaluations/ios-skills/results/2026-08-02-old-vs-new.md`(repo ルート相対):
**総合して改善**(safety 違反 4→0、5 case 中3つで実質的な精度向上)。
唯一の劣後(icon case)は調査済みで、再構成そのものの劣化ではなく rubric の歪みと判明。

> **2026-08-04 更新:** 別セッションが `ios-app-icon` の設計知見を追加(`0f98411`、未 push)。
> 「効果は system(Icon Composer)へ任せる」の適用範囲が広すぎたと判明 —— specular/shadow/
> translucency 等の**system が作れる効果**と、**素材自身が持つべき色の階調**(gradient)は別物で、
> 後者まで平坦にすると案ごとの違いが消える。純正アイコンの実測(gradient・半透明合成)を根拠に
> `native-look.md` を修正。あわせて layer 番号の運用規則(描画順に揃える)と `.icon` 復元手順を
> 追加。evaluations の外側で起きた ios-skills 本体の改善で、下の「evaluation に閉じない」節に
> 反映(詳細は `docs/ios-skills/log.md`)。
>
> `ios-skills@gigun` プラグインは08-02の評価バッチ用 disable のままだったが実害なし
> (評価ハーネスは `--plugin-dir` で候補を直接注入するため、disable 状態に依存しない。
> 通常セッションがファイルを直接編集する分にも影響しない)。判断は保留 — どちらでもよい。

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

- ~~`ios-app-icon`: 「効果は system へ任せる」の適用範囲の切り分け~~ ✅(`0f98411`、未 push)。
  push 判断は保留。
- この節が今後埋まっていく想定 —— 継続コンテキストの仕組み(rule/hook/log)がここに
  拾えるかが実地テストになる。08-04 時点では **拾えなかった**(下記参照)。

> **2026-08-04 更新: 継続コンテキストの仕組みが機能したか未確認。**
> `0f98411` を作ったセッションは `plugins/ios-skills/skills/ios-app-icon/SKILL.md` を
> 編集しており、`.claude/rules/ios-skills.md`(該当 paths)は発火していたはずだが、
> `docs/ios-skills/log.md` は更新されていない。原因は不明(rule を無視した/読んだが
> log 更新までは指示に従わなかった/そもそも rule 導入(`d42eca2`)前にセッションが
> 開始していた、のいずれか未特定)。次にここへ書き込むセッションが出たら、
> 実際に機能したかの一次データになる。
