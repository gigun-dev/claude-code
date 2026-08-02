# Claude Code / Codex 共有ハーネス(ios-skills スコープ)

Claude Code 側を正典にし、同じ内容を表現できる Codex surface は symlink で共有する。
caldav リポジトリの `.codex/` と同じ方式だが、**この repo には caldav にある
`CLAUDE.md`・SessionStart フック・project `.mcp.json`・`.claude/skills` が無い**
(単なるプラグイン集合 repo で、caldav のような単一アプリではないため)。
存在しないものまで空の設定として作ると保守対象が増えるだけなので、**実在する
対応関係だけ**をここに置く。

| Codex | 正典 | 方式 |
| --- | --- | --- |
| `plugins/ios-skills/AGENTS.md` | `.claude/rules/ios-skills.md` | symlink |
| `evaluations/AGENTS.md` | `.claude/rules/ios-skills.md` | symlink |

`.claude/rules/ios-skills.md` は**安定した pointer だけ**を持つ薄い rule で、
「作業前に `evaluations/next-directions.md` を読め」としか書いていない。
**現在地・次の作業そのもの(揮発性が高く、作業のたびに更新される内容)は
rule には置かない** —— caldav の `docs/next-directions.md` が `CLAUDE.md`
(安定した instruction)とは別ファイルで、専用のフック経由で注入されるのと同じ分離。
rule は「常にこうする」という指示のための機構であり、頻繁に変わる状態ログを
そこに直接書くと、rule を触るたびに状態更新のノイズが instruction の差分に混ざる。

## コンテキストの正典

1. `evaluations/next-directions.md`: ios-skills の現在地と次の作業(正典。
   頻繁に更新される)。**自動ロードはされない** —— この repo には caldav のような
   SessionStart フックが無いため、`.claude/rules/ios-skills.md`(下記)の pointer を
   見てから明示的に読む一手が要る。
2. `.claude/rules/ios-skills.md`: 上記への pointer だけを持つ薄い rule。
   `plugins/ios-skills/**` / `evaluations/**` を編集するときだけ自動ロードされる
   (Claude 側は path-scoped rule、Codex 側は上記 `AGENTS.md` 経由)。
3. `evaluations/README.md`, `evaluations/CLAUDE-RUNTIME-CONSTRAINTS.md`: 評価ハーネスの
   設計・Claude ランタイム固有の実測制約。
4. `evaluations/ios-skills/results/`: A/B の測定結果。

## 対象外(この repo には存在しない)

- リポジトリ全体の instruction(`CLAUDE.md`/`AGENTS.md`)—— このマーケットプレイス repo
  全体を1つのアプリとして扱う正典は無い。プラグインごとに独立している。
- SessionStart フック —— Claude 側に無いので Codex 側にも作っていない。
  caldav ではこれが `docs/next-directions.md` の「頭」を自動注入していたが、
  この repo では `.claude/rules/ios-skills.md` の pointer を見て明示的に読む形で代替する
  (読む一手が増える代わりに、rule 機構の意味を歪めない)。
- project 共通の MCP サーバー設定(`.mcp.json`)—— 各プラグインが自分の
  `mcpServers` を宣言する(`plugins/*/​.claude-plugin/plugin.json`)。
- `.agents/skills/*` —— skill は `plugins/*/skills/` 配下でプラグインごとに管理され、
  project-level の `.claude/skills/` は無い。

## 保守

- **現在地・次の作業の更新は `evaluations/next-directions.md` を直接編集する。**
  `.claude/rules/ios-skills.md` は pointer なので、更新のたびに触る必要はない。
- `.claude/rules/ios-skills.md` を編集したら、この README の対応表は
  そのまま有効(symlink なので中身は自動的に追従する)。
- rule ファイルの `paths:` を変えたら、対応する `AGENTS.md` symlink をここに追加/削除する。
- caldav 側の `.codex/` に新しい仕組みが増えたら、この repo にも要るかをその都度判断する
  (無条件に複製しない —— この repo の実態に合うものだけを持ち込む)。
