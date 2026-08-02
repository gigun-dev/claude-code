# Claude Code / Codex 共有ハーネス(ios-skills スコープ)

Claude Code 側を正典にし、同じ内容を表現できる Codex surface は symlink で共有する。
caldav リポジトリの `.codex/` と同じ方式だが、**この repo には caldav にある
`CLAUDE.md`・SessionStart フック・project `.mcp.json`・`.claude/skills` が無い**
(単なるプラグイン集合 repo で、caldav のような単一アプリではないため)。
存在しないものまで空の設定として作ると保守対象が増えるだけなので、**実在する
対応関係だけ**をここに置く。

| Codex | 正典 | 方式 |
| --- | --- | --- |
| `plugins/ios-skills/AGENTS.md` | `.claude/rules/ios-skills-next-directions.md` | symlink |
| `evaluations/AGENTS.md` | `.claude/rules/ios-skills-next-directions.md` | symlink |

## コンテキストの正典

1. `.claude/rules/ios-skills-next-directions.md`: ios-skills の現在地と次の作業。
   `plugins/ios-skills/**` / `evaluations/**` を編集するときだけ読む
   (Claude 側は path-scoped rule として自動ロード、Codex 側は上記 `AGENTS.md` 経由)。
2. `evaluations/README.md`, `evaluations/CLAUDE-RUNTIME-CONSTRAINTS.md`: 評価ハーネスの
   設計・Claude ランタイム固有の実測制約。
3. `evaluations/ios-skills/results/`: A/B の測定結果。

## 対象外(この repo には存在しない)

- リポジトリ全体の instruction(`CLAUDE.md`/`AGENTS.md`)—— このマーケットプレイス repo
  全体を1つのアプリとして扱う正典は無い。プラグインごとに独立している。
- SessionStart フック —— Claude 側に無いので Codex 側にも作っていない。
  ios-skills の現在地は上記 rule ファイルが path-scoped で担う。
- project 共通の MCP サーバー設定(`.mcp.json`)—— 各プラグインが自分の
  `mcpServers` を宣言する(`plugins/*/​.claude-plugin/plugin.json`)。
- `.agents/skills/*` —— skill は `plugins/*/skills/` 配下でプラグインごとに管理され、
  project-level の `.claude/skills/` は無い。

## 保守

- `.claude/rules/ios-skills-next-directions.md` を編集したら、この README の対応表は
  そのまま有効(symlink なので中身は自動的に追従する)。
- rule ファイルの `paths:` を変えたら、対応する `AGENTS.md` symlink をここに追加/削除する。
- caldav 側の `.codex/` に新しい仕組みが増えたら、この repo にも要るかをその都度判断する
  (無条件に複製しない —— この repo の実態に合うものだけを持ち込む)。
