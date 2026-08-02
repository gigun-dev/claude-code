# ios-skills 作業ログ(時系列アーカイブ)

> **位置づけ**: 追記専用の時系列アーカイブ(何をしたかの生記録)。作業の区切りごとに末尾へ追記する。
> セッション引き継ぎの正典は `docs/ios-skills/next-directions.md`(そちらの現在地・次の作業も同時に更新する)。
> 通常は全文ロードしない — 経緯を掘るときだけ読む。

- 2026-08-02: Codex が `e112915` で ios-skills を portable/evaluable な形へ再構成。
  4スキル(`ios-simulator`/`ios-device-build`/`ios-app-icon`/`appstoreconnect-upload`)の
  SKILL.md を合計約1,095行から292行へ圧縮、詳細を `references/` へ分離。
  `~/.claude/skills` や `AskUserQuestion` への直接依存を除去、個人端末設定を削除。
  同時に `evaluations/` を新設(共有評価ハーネス、rubric、runner)。
- 2026-08-02: Claude 側で `evaluations/scripts/run-agent-eval.py` を実走してみたところ、
  `--bare` がサブスク認証(OAuth)と両立しないことが判明(`Not logged in`)。
  `--bare` を撤去し、代わりに `--strict-mcp-config` 空 MCP・unscored preflight・
  `slash_commands` の condition assert を実装。
- 2026-08-02: `clean_environment` の allowlist に `USER` が無く、全 run が `Not logged in` に
  なる不具合を発見(macOS Keychain の `Claude Code-credentials` は `acct`=ユーザー名で引く。
  `LOGNAME` では代替不可)。`USER` を追加して解消。
- 2026-08-02: `--json-schema` に `$schema`(draft 2020-12)を含めると Claude CLI が起動前に
  落ちる不具合を発見(`no schema with key or ref ...`)。adapter 側で `$schema` を除去して解消。
- 2026-08-02: 30 run の old(`2d3424a`)vs new(`e112915`)バッチを実走 → 全て `completed`。
  ただしブラインド採点の途中で、read-only の `--tools` に `Skill` が無いことが判明
  (`slash_commands` には並ぶがモデルは呼べず、SKILL.md を `Glob` で探し回っていた)。
  **このバッチは無効と判断し破棄**(30 run 中 11 run が候補ファイルへ一度も到達していなかった)。
  `--tools` に `Skill` を追加し、`assert_condition_took_effect` が `init.tools` も
  検査するよう修正して再走(v2)。
- 2026-08-02: v2 バッチで `Agent` ツールにも同じ罠があることを発見
  (`init.agents` に並んでいても `--tools` に `Agent` が無いとモデルは認識しない)。
  read-only に `Agent` を足すと subagent 経由で `Bash` が使え read-only が破れるため、
  トレードオフとして許容(両条件に一様な減点なので比較は歪まない。未解決タスクとして残す)。
- 2026-08-02: v2 バッチ(30 run、5 case × old/new × 3反復)を5並列ブラインド採点。
  結果: 合計平均 3.47→3.93(+0.47)、safety assertion 違反 old 4件/new 0件
  (`procedural-device-build-plan` の old 3 run 全てが違反 — global DerivedData の
  古い `.app` を実機へ入れる手順、dry-run 段階での個別端末問い合わせ)。
  唯一の劣後は `procedural-icon-safe-build`(−0.67)。
  副産物: old に実在の個人端末名(`DEFAULT_DEVICE_NAME="iPhone 12 mini morita"`)が
  残存していたことを発見(new では削除済み。git 履歴には残る)。
- 2026-08-02: icon case の劣後を調査 → **再構成そのものの劣化ではなかった**。
  `build_icon.sh`/`render_icon.sh` を old/new で直接読み比べたところ、new の方が
  スクリプト実体として安全(atomic 化 `mktemp`+`trap`、render 失敗の
  `|| true` 握り潰しを修正)。old の高得点は実バグを発見して回避策を語ったことへの
  加点で、new の低得点は安全性が実装に埋め込まれたことで語る動機が減った結果と判明。
  rubric に「候補スクリプトの安全性を正しく言及したか」の観点が無いのが原因。
  結果は `evaluations/ios-skills/results/2026-08-02-old-vs-new.md` に記録
  (測定結果は評価ハーネスの成果物として `evaluations/` に残す。継続コンテキストだけ
  `docs/ios-skills/` へ切り出した——この2つの区別は次の項目でさらに整理した)。
- 2026-08-02: `evaluations/scripts/simulator-guard.py`(live case 前後の Simulator 状態
  突き合わせ)と `plugins/ios-skills/skills/ios-simulator/scripts/sim-reap.sh`
  (使い捨て端末の回収)を追加。端末の命名契約(`seed-*`/`w-*`/`EVAL-*`)を
  `references/state-provisioning.md` に明記。
  この機械に溜まっていた CalDAV アカウント保持の seed 端末9台
  (`CalDAV-Golden` 等、既定名 `iPhone 17` 含む)を実データで特定して削除
  —— 放置された種端末が過去の baseline の近道になり、eval の `none` アームを
  無効化していた実例があったため(§METHODOLOGY.md 参照)。
- 2026-08-02: セッション継続コンテキストの仕組みを整備。当初 `.claude/rules/` に
  現在地・次の作業を直接書いていたが、rule(安定した instruction のための機構)と
  next-directions(揮発性の高い状態ログ)を混同していたと指摘を受け分離。
  さらに `evaluations/` へ置いたのも評価ハーネスとの関心混在と指摘を受け、
  `docs/ios-skills/`(next-directions.md + このログ)へ再配置。
  `.claude/rules/ios-skills.md` は pointer だけを持つ薄い rule に、
  SessionStart フック(Claude + Codex 両対応)で軽量な pointer を常時注入するよう整備。
