# Agent component evaluation

このディレクトリを skill / plugin / MCP 評価の正典とする。`.claude/` と
`.codex/` は provider 固有の薄い adapter に留め、rubric、case、fixture、結果はここで共有する。

## 評価レイヤー

下位レイヤーが失敗した run を、上位レイヤーの精度比較へ混ぜない。

| 対象 | 独立して判定するレイヤー |
|---|---|
| skill | static validation → trigger/routing → old/new procedural non-inferiority → deterministic script contract → live E2E → human-in-the-loop |
| plugin | manifest validation → host native load → component inventory → fresh-session exposure → task E2E |
| MCP | process startup/handshake → tool registration/schema → harmless deterministic call → error/timeout/permission → product E2E |

plugin startup failure、skill未露出、MCP tool未登録は、それぞれ exposure 以前の障害として記録する。
被験skillの回答品質を0点に置換しない。live E2Eは静的・手続き評価の合格後だけ実施する。

### 判定規約

- safety-critical assertion の regression は許容 **0件**。平均点で相殺しない。
- 通常タスクの non-inferiority margin は結果を見る前にcaseへ登録する。既定値は `-0.34` で、
  case固有値を優先する。**margin は観測分解能と突き合わせて決める** ——
  スコアが整数で反復が `n` なら、条件間の平均差は `1/n` 刻みでしか観測できない。
  `|margin| < 1/n` にすると、許容幅として書いてあるのに**実質ゼロ許容**になる
  (満点5・反復3の現構成では、旧既定の `-0.25` が該当した。`(-0.333, 0]` に取りうる値は 0 だけ)。
  採点者はLLMで同じ回答でも1点ぶれるため、ゼロ許容は採点ノイズをそのまま「退行」として出す。
  `-0.34` は反復3で意味を持つ最小の許容幅(3本中1本の1点落ちまで許容、2本落ちは不合格)。
  **反復を増やすなら margin も締め直す**(反復6なら分解能 0.167 なので `-0.17` が対応する)。
- provider、CLI version、modelの完全なIDを固定する。同じprompt、fixture、output schemaを使う。
- conditionごとにfresh workspaceを作り、前runのSimulator、DerivedData、生成物を再利用しない。
- condition順を乱数seed付きでrandomizeし、原則3回以上runする。打ち切り条件も事前登録する。
- raw stdout、stderr、final response、CLI version、command、duration、artifactをrun directoryへ保存する。
- 採点者にはcondition名と期待回答を伏せ、実行と採点を別session/agentで行う。
- transcript上の自己申告ではなく、実ファイル、exit code、実行commandで裏を取る。

既存Simulator評価で実際に踏んだ測定上の罠は
[`ios-skills/ios-simulator/evals/METHODOLOGY.md`](ios-skills/ios-simulator/evals/METHODOLOGY.md)
を参照する。特にA/B必須、到達可能な閾値、打ち切り、層別、answer leakage、環境汚染を重複して
再発明しない。

過去に**一度スキル本文へ書かれ、実験で誤りと判明して撤回された記述**は
[`ios-skills/ios-simulator/retracted-2026-08-01.md`](ios-skills/ios-simulator/retracted-2026-08-01.md)
にある。runtime skillには載せない(誤った記述をエージェントに読ませないため)が、
**削除もしない** —— 同じ症状から同じ誤診へ落ちるのを防ぐカタログとして残す。
「座標系がpxだと結論した」「AXが壊れたと診断してshutdown/bootを第一手にした」など、
いずれも**もっともらしく、実験するまで気づけなかった**もの。

Claude ランタイム側の制約(`--bare`とサブスク認証、プラグインスキルを無効化できない件、
バッチ単位でのみ成立する隔離手順)は [`CLAUDE-RUNTIME-CONSTRAINTS.md`](CLAUDE-RUNTIME-CONSTRAINTS.md)
にある。**実走の前に必ず読むこと**。runnerは§6-bに従い、サブスク認証、空MCP構成、
`slash_commands`によるcondition検算を行うが、installed comparison pluginのdisable/restoreは
共有状態を変更するため人間がバッチ境界で実施する。

## ios-skills と build-ios-apps の役割

| 領域 | ios-skills | OpenAI `build-ios-apps` | 比較 |
|---|---|---|---|
| 実機build/install/launch | 主担当 | 対象外 | 比較しない |
| Icon Composer `.icon` 生成 | 主担当 | 対象外 | 比較しない。デザインは人間評価 |
| App Store Connect archive/upload | 主担当 | 対象外 | 比較しない |
| SimulatorのOS状態投入とCLI固有罠 | 主担当 | 一部重複 | runtime caseだけ比較 |
| XcodeBuildMCP debugger | 補助 | 主担当 | runtime caseだけ比較 |
| SwiftUI設計・リファクタ | 対象外 | 主担当 | routingのみ確認 |
| App Intents / Liquid Glass | 対象外 | 主担当 | routingのみ確認 |
| performance / leak | 対象外 | 主担当 | routingのみ確認 |
| Simulator browser mirror | 対象外 | 主担当 | routingのみ確認 |

役割外を「負け」と数えない。競合比較の主対象はSimulator runtimeだけで、それ以外は正しいrouteを
選べるかを測る。`none` conditionは、一般知識だけでも解けるcaseでskillが不要な手順や危険な操作を
増やさないかを見るbaselineである。

## Runner

[`scripts/run-agent-eval.py`](scripts/run-agent-eval.py) はPython標準ライブラリだけで動く。
標準はread-onlyで、CLIを呼ばない確認には `--dry-run` を使う。

```bash
python3 evaluations/scripts/run-agent-eval.py \
  --provider codex \
  --suite evaluations/suites/ios-skills.json \
  --case procedural-device-build-plan \
  --condition ios-skills-new \
  --skill-path ios-skills-new=/absolute/path/to/plugins/ios-skills \
  --model MODEL_ID \
  --repetitions 3 \
  --output-dir /absolute/path/to/eval-runs \
  --dry-run
```

Claude adapterは `claude -p ... --plugin-dir ... --output-format stream-json --verbose
--no-session-persistence --strict-mcp-config --mcp-config '{"mcpServers":{}}'`、Codex adapterは
`codex exec --ephemeral --ignore-user-config --sandbox read-only --json --output-schema ...` を
組み立てる。Codexでは候補skillを
`-c 'skills.config=[{path="...",enabled=true}]'` で明示する。

Claudeの実走では採点前にunscored preflightを1回行う。subscription認証、`system/init`の存在、
比較対象pluginの非露出を確認し、各runでも候補skillの欠落・別conditionの混入を検出したら
`condition-error`で停止する。dry-runはCLIを呼ばないため、この検算を実行した証拠にはならない。

`live` / `write` caseは `--allow-live --confirm-live I_UNDERSTAND_LIVE_EVAL` の両方がなければ
拒否する。実機、Simulator、network、App Store Connectに副作用を起こす評価は、対象、credential、
rollbackを人間が確認してから個別に実行する。runnerは秘密値をmetadataやconsoleへ書かない。

各batchの `condition-map.json` はsealed analyst-only対応表であり、採点者・HITL評価者へ渡さない。
採点bundleは各runの `stdout.jsonl`、`stderr.log`、`final.json`、blinded `metadata.json` と、
conditionを含まない `schedule.json` だけにする。`workspace/` も候補の版を推測できるため共有しない。

## Human-in-the-loop

icon/UXはautomated technical validationの後に、**独立したHITL gate**として扱う。同じbrief・制約で
生成した候補へconditionを含まない匿名ラベルを割り当て、seed付きで提示順をrandomizeする。
小サイズ可読性、識別性、独自性、light/dark/tinted適合、総合選好をraw 1〜5 scoreで保存する。

評価者、評価日時、seed、提示順、raw score、自由記述を結果に残す。technical passと人間の
design preferenceを合算しない。人間評価が未完なら、technical結果にかかわらずdesign結論は
`pending` のままとする。CLI成功だけをデザイン品質の合格にしない。

入力は [`schemas/suite.schema.json`](schemas/suite.schema.json)、agent最終応答は
[`schemas/agent-response.schema.json`](schemas/agent-response.schema.json)、採点結果は
[`schemas/result.schema.json`](schemas/result.schema.json) に従う。
