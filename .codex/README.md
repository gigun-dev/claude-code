# Claude Code / Codex 共有ハーネス(ios-skills スコープ)

Claude Code 側を正典にし、同じ内容を表現できる Codex surface は symlink で共有する。
caldav リポジトリの `.codex/` と同じ方式だが、**この repo には caldav にある
`CLAUDE.md`・project `.mcp.json`・`.claude/skills` が無い**(単なるプラグイン集合
repo で、caldav のような単一アプリではないため)。存在しないものまで空の設定として
作ると保守対象が増えるだけなので、**実在する対応関係だけ**をここに置く。
SessionStart フックだけは(下記の理由で)Claude/Codex 両方に用意した。

| Codex | 正典 | 方式 |
| --- | --- | --- |
| `evaluations/AGENTS.md` | `.claude/rules/ios-skills.md` | symlink |
| `.codex/hooks/session-start.sh` | `.claude/hooks/session-start.sh` | symlink |

> **`plugins/ios-skills/AGENTS.md` は置かない(2026-08-05 撤去)。**
> `plugins/` 配下は**配布物**で、marketplace 経由でインストールされた先へそのまま渡る。
> repo 外(`../../.claude/`)を指す symlink を置くと**インストール先でリンク切れになる**。
> 実際、評価ハーネスの安全チェック
> (`candidate/fixture may not contain symlinks`)が候補プラグインに混入したこの
> symlink を検出して停止し、発覚した。
> **配布物に repo 内部の運用ファイルを持ち込まない。**
> Codex が `plugins/ios-skills/**` を編集するときは、SessionStart フックの pointer と
> `evaluations/AGENTS.md` から辿る。

## コンテキストの正典(3層)

1. **`docs/ios-skills/next-directions.md`**: 現在地と次の作業(正典。頻繁に更新される)。
   SessionStart フックが軽量な pointer 一行を毎セッション注入する(下記)。
   実際に ios-skills を触るときは `.claude/rules/ios-skills.md`(下記)がより強く
   思い出させる。
2. **`docs/ios-skills/log.md`**: 時系列の生記録(追記専用アーカイブ)。自動ロードは
   されない —— 経緯を掘るときだけ読む。
3. **`.claude/rules/ios-skills.md`**: 1・2 への pointer だけを持つ薄い rule。
   `plugins/ios-skills/**` / `evaluations/**` を編集するときだけ自動ロードされる
   (Claude 側は path-scoped rule、Codex 側は上記 `AGENTS.md` 経由)。

`evaluations/` は評価ハーネス専用の関心(rubric・case・runner・測定結果)であり、
継続コンテキストはここには置かない。詳細は下記「対象外」ではなく
`.claude/rules/ios-skills.md` 本文を参照(評価とプラグイン改善は別の関心という
判断そのものは rule 側に書いてある)。

- `evaluations/README.md`, `evaluations/CLAUDE-RUNTIME-CONSTRAINTS.md`: 評価ハーネスの
  設計・Claude ランタイム固有の実測制約。
- `evaluations/ios-skills/results/`: A/B の測定結果。

## SessionStart フック(軽量 pointer)

caldav の `docs/next-directions.md` は「頭(現在地)」を毎セッション全文注入するが、
それは caldav が単一プロダクトの repo で、どのセッションもその現在地を知りたがる
前提があるから成立する。**この repo は複数の独立したプラグインの寄せ集めで、
ios-skills はその一つに過ぎない。** 全文注入すると無関係な作業のセッションにまで
毎回コストを強制するため、注入は `docs/ios-skills/next-directions.md` /
`docs/ios-skills/log.md` への pointer 一行だけに絞った
(`.claude/hooks/session-start.sh` / `.codex/hooks/session-start.sh`)。

- 予防型(セッションを開いた瞬間に気づく): SessionStart フックの軽量 pointer。
- 反応型(実際に触ったら気づく): `.claude/rules/ios-skills.md` のフルの pointer。

両方揃えることで、ios-skills に触れる予定が無かったセッションが途中で pivot した
場合でも、最初の一行で気づける。

## 対象外(この repo には存在しない)

- リポジトリ全体の instruction(`CLAUDE.md`/`AGENTS.md`)—— このマーケットプレイス repo
  全体を1つのアプリとして扱う正典は無い。プラグインごとに独立している。
- project 共通の MCP サーバー設定(`.mcp.json`)—— 各プラグインが自分の
  `mcpServers` を宣言する(`plugins/*/​.claude-plugin/plugin.json`)。
- `.agents/skills/*` —— skill は `plugins/*/skills/` 配下でプラグインごとに管理され、
  project-level の `.claude/skills/` は無い。

## 保守

- **現在地・次の作業の更新は `docs/ios-skills/next-directions.md` を直接編集する。**
  作業の区切りごとに `docs/ios-skills/log.md` へも追記する。
  `.claude/rules/ios-skills.md` は pointer なので、更新のたびに触る必要はない。
- `.claude/rules/ios-skills.md` を編集したら、この README の対応表は
  そのまま有効(symlink なので中身は自動的に追従する)。
- rule ファイルの `paths:` を変えたら、対応する `AGENTS.md` symlink をここに追加/削除する。
- caldav 側の `.codex/` に新しい仕組みが増えたら、この repo にも要るかをその都度判断する
  (無条件に複製しない —— この repo の実態に合うものだけを持ち込む)。
