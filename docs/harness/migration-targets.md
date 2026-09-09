# 対象プロジェクトへの引き継ぎ

2026-09-10 に `ghq list --full-path` の 174 リポジトリを読み取り専用で調査した。
確認したのは CLAUDE.md / AGENTS.md、既知の Git・SessionStart フックと旧文書の配置。
この一覧は候補であり、独自の配置や ghq 管理外のプロジェクトを網羅したものではない。
フックの実際の実行内容・稼働状態・最新タスクは各プロジェクトのセッションで調べる。
他リポジトリのファイルと Git 設定は変更していない。

| プロジェクト（github.com 以下） | 検出根拠 | 入口の例 | core.hooksPath |
| --- | --- | --- | --- |
| `gigun-dev/caldav` | harness の刻印・呼び出しあり | `.claude/hooks/session-start.sh`, `.codex/hooks/session-start.sh` | `.githooks` |
| `gigun-dev/cf-fireboard` | harness の刻印・呼び出しあり | `.githooks/pre-commit`, `.githooks/pre-push` | `.githooks` |
| `gigun-dev/dotfiles` | harness の刻印・呼び出しあり | `.claude/hooks/session-start.sh`, `.codex/hooks/session-start.sh` | `git/hooks` |
| `gigun-dev/esp32-airdrop-poc` | harness の刻印・呼び出しあり | `CLAUDE.md`, `AGENTS.md` | `.githooks` |
| `gigun-dev/figmate` | 旧文書あり。由来は未確認 | `docs/next-directions.md` | `.githooks` |
| `gigun-dev/hub` | 旧文書あり。由来は未確認 | `docs/next-directions.md` | `未設定` |
| `gigun-dev/store-redirect` | harness の刻印・呼び出しあり | `.githooks/pre-push`, `.claude/hooks/session-start.sh` | `.githooks` |
| `gigun-dev/swift-mcp-app` | 旧文書あり。由来は未確認 | `docs/next-directions.md` | `.githooks` |
| `gigun-dev/tdr-concierge` | 旧文書あり。由来は未確認 | `docs/next-directions.md` | `.githooks` |
| `gigun-dev/tdr-map-comparison` | 旧文書あり。由来は未確認 | `docs/next-directions.md` | `.githooks` |
| `gigun-dev/tiktok-fetcher` | harness の刻印・呼び出しあり | `CLAUDE.md`, `AGENTS.md` | `.githooks` |
| `realbind/cf-asc-dashbord` | harness の刻印・呼び出しあり | `CLAUDE.md`, `AGENTS.md` | `.githooks` |
| `realbind/gensan-system` | 旧文書あり。由来は未確認 | `docs/next-directions.md` | `未設定` |

`esp32-airdrop-poc` では上記の固定配置に旧文書がなかった。未導入という意味ではなく、
各プロジェクトの設定から実際の保存先を確認する。
`dotfiles` の hooksPath は `.githooks` ではなく `git/hooks`。一括置換はしない。

## 各プロジェクトで渡す依頼文

> このリポジトリを harness から todo・adr へ移行して。
> 通常の導入には todo の doctor スキルを使って。旧設定の撤去とデータ移行はこのプロジェクトの実物に合わせて行って。
> 旧タスク・依存・判断・未検証事項を保存し、旧 ID の対応を残して。
> pre-push は由来と実行内容を確認し、CI 相当の検証を残す形を基本にして。
> このプロジェクト内で実施し、他リポジトリやグローバル設定は変更しない。
> コミット・push はせず、移行差分と実際の検証結果を報告して。

この依頼文は今回の移行専用。プラグインには通常の導入・点検だけを含める。
