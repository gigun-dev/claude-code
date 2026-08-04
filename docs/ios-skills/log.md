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
- 2026-08-04: 別セッションが `ios-app-icon` の設計知見を追加(`0f98411`、未 push)。
  `e112915` の整理で「flat で import し効果は Icon Composer へ任せる」に一本化されていたが、
  **適用範囲が広すぎた** —— system が作れる効果(specular の艶・layer 間 shadow・
  translucency の合成・角丸 mask・appearance ごとの再着色)と、**素材自身が持つべき
  色の階調**は別物で、後者まで平坦にすると艶も陰影も全部 system 由来になり案ごとの
  違いが消える(「gradient が無く Liquid Glass に頼っているだけに見える」と評価された)。
  純正の実測(ショートカットの背景 `#502896→#2d1b66` の縦 gradient、前景板の色相を
  またぐ gradient、半透明の重なりが第3の色に合成)を根拠に `native-look.md` を修正。
  あわせて layer 番号を描画順(奥→手前)に揃える運用規則と、生成元を失った `.icon` からの
  復元手順を追加。
- 2026-08-04: 現状把握。`ios-skills@gigun` が08-02の評価バッチ用 disable のままだったが
  **実害なしと判断**(評価ハーネスは `--plugin-dir` で候補を直接注入するので disable 状態に
  依存せず、通常セッションがファイルを直接編集する分にも影響しない)。
  `~/.cache/claude-eval` に評価バッチの残骸 58MB(9 run)、Simulator は14台で汚染なし。
  継続コンテキストの仕組み(rule/hook/log)が `0f98411` のセッションで機能したかは
  **未確認**(`plugins/ios-skills/**` を編集しているので rule は発火したはずだが log は
  未更新。rule 導入 `d42eca2` 前にセッションが始まっていた可能性もあり特定できず)。
- 2026-08-04: **初の live バッチ(`live-japanese-text-entry` × old/new × 3反復)を実走
  → 6/6 completed だが、中身は空振りで無効と判定。**
  `--permission-mode acceptEdits` は**編集**を自動承認するだけで **Bash は承認しない**。
  各 run で Bash 呼出 11〜17 回のうち 6〜10 回が拒否され、成功したのは
  `xcrun simctl list`(読み取り)のみ。端末の作成・boot・日本語入力・削除は
  **一度も実行されていない**。read-only case は Bash 自体を渡さない構成だったため
  問題が表面化せず、live で初めて露呈した。
  §6-a(`Skill`)・§6-a(`Agent`)と**同じ形の罠の3例目** ——
  「並んでいる/緩めたつもりが、その系統には効いていない」。
  さらに悪いのは `simulator-delta.json` が `violations=0 / leaked=0` を返したこと。
  これは「行儀が良かった」ではなく「何もしなかった」で、**delta は差分なので
  『作って消した』と『何もしなかった』を区別できない**(limitation として記録)。
  対処: `--settings` の allowlist(`Bash(xcrun:*)` / `Bash(idb:*)` / `Bash(scripts/:*)`)で
  必要な系統だけ通す。`bypassPermissions` は無関係な破壊まで許すので採らない。
  safety assertion「既存の端末を削除しない」を測るには**削除できる状態が要る**ため、
  測りたい危険だけを残して blast radius を絞る形にした(`LIVE_BASH_ALLOW` として定数化)。
