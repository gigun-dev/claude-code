# claude-code

gigun の Claude Code / Codex プラグイン・マーケットプレイス。

skill / plugin / MCP の回帰評価とClaude/Codex共通runnerは
[`evaluations/README.md`](evaluations/README.md)を入口とする。

## 使い方

### Claude Code

```bash
claude plugin marketplace add gigun-dev/claude-code
claude plugin enable <plugin>@gigun
```

### Codex

Codex ネイティブのカタログ定義は [`.agents/plugins/marketplace.json`](.agents/plugins/marketplace.json) にあります。Claude Code 互換の [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) も維持しています。
MCP定義の正典は各pluginルートの `.mcp.json` とする。例外は、公式が直接設定を案内する製品MCPとCodexデスクトップ内部機能だけである。
Claude用 `.claude-plugin/plugin.json` は正典から生成するadapterであり、変更後は `python3 scripts/sync_mcp_wrappers.py --check` を通す。修正が必要な場合だけ `--write` を実行する。

```bash
# マーケットプレイス登録は初回のみ
codex plugin marketplace add gigun-dev/claude-code
codex plugin add <plugin>@gigun
```

skill だけでできたもの(自前の japanese-tech-writing、上流の worktree・cross-agent・edit-skills・commit・emil・unslop・hallmark・langfuse・modern-web-guidance・yomiyasu・swift-concurrency-pro・swift-testing-pro・swiftui-pro)は plugin にせず、dotfiles の agent-skills-nix が版を `flake.lock` に固定して各ホストの skill ディレクトリへ置く(ADR 0007、[`skills/README.md`](skills/README.md))。npm で配られる外部 plugin(REA)は marketplace に載せず、この flake がビルドしたものを dotfiles の home-manager module が各ホストへ置く(下の「外部 plugin」)。marketplace に残る外部 plugin は上流の Git リポジトリを `sha` で固定したもの(visual-explainer)。どちらの版も週次の workflow(`.github/workflows/external-plugins.yml`)が `scripts/update_external_plugins.py` で公開から 3 日以上経った版へ進めて自動 merge する(ADR 0007)。上流のソースはこのリポジトリへ複製しない。

### Antigravity CLI (agy)

スキルと MCP だけを agy ネイティブ形式で生成している(`scripts/generate_manifests.py`)。`plugins/<name>/.antigravity-plugin/plugin.json` と、MCP を持つ plugin は直下の `mcp_config.json`(`.mcp.json` から変換。http は `serverUrl`、`${CLAUDE_PLUGIN_ROOT}` は `${PLUGIN_ROOT}`)。`skills/` は Claude と同じ `SKILL.md` をそのまま読ませる。`.claude-plugin/` があっても `.antigravity-plugin/` を持つディレクトリはネイティブ plugin として扱われ、リポジトリ内のファイルは書き換えられない。
hooks は agy とイベント・ツール名が違うため対象外。commands は未対応。`agents/` は agy が直接読む(`agy plugin validate` で確認)。

`agy plugin import` / `install` はコピーを作って UI 管理の `config.json` に記録するため使わず、`~/.gemini/config/plugins.json` でこのリポジトリを指す。dotfiles(`nix/modules/home/dotfiles.nix`)が Claude の `enabledPlugins` から読ませる plugin を導いて配る。`entries[].path` は絶対パスで書く。agy 1.5.5 は文書と違って `~/` を展開せず、その entry を飛ばす(環境変数も展開されない)。

```json
{ "entries": [{ "path": "/Users/<user>/ghq/github.com/gigun-dev/claude-code/plugins", "include_only": ["todo", "t3"] }] }
```

単体検証は `agy plugin validate plugins/<name>`(認証不要・読み取りのみ)。

### 外部 plugin(Nix で 3 ホストへ)

npm で配られる外部 plugin は、この flake の `external-plugins`(`nix/external-plugins.nix`、overlay も同名)が 1 回だけビルドし、dotfiles の home-manager module が各ホストの読む場所へ置く(ADR 0007)。版と SRI ハッシュは `nix/npm-sources.json` だけに固定する。出力は次のとおり。

| パス | 中身 | 置く先 |
| --- | --- | --- |
| `bin/<server>-mcp` | 固定した node を絶対パスで使い、`mcpEnv` を設定して上流の launcher を起動する | 全ホストの MCP がこれを指す。Codex は `config.toml` の `[mcp_servers.<server>]` |
| `share/agent-plugins/<name>/` | Agent Plugins 1.0 の `plugin.json`・`mcp.json`、`.claude-plugin/plugin.json`、上流のままの `skills/` | Claude は `~/.claude/skills/<name>`(skills ディレクトリの plugin)。Codex は `skills/<skill>` を `~/.agents/skills` へ |
| `share/agy-plugins/<name>/` | `.antigravity-plugin/`、`mcp_config.json`、24,000 バイトを超える節を `references/` へ移した `skills/` | `~/.gemini/config/plugins.json` の 1 entry |
| `lib/<name>/` | 上流の npm パッケージそのもの | 直接は置かない |

agy 版を分けるのは、agy も Claude・Codex と同じ `skills/` を読み、別の場所を指す設定が無いためである。分割を共有ディレクトリでやると Claude と Codex も分割後の本文を読む。dotfiles はパスを書かず `passthru` から引く(`plugins.<name>.dir`・`.mcpServers`・`.skills`、`agy.dir`・`agy.names`)。Ghidra などの環境は `mcpEnv` で渡す。

```nix
(pkgs.external-plugins.override {
  mcpEnv.rea.rea = { GHIDRA_INSTALL_DIR = "${ghidra}/lib/ghidra"; JAVA_HOME = "${pkgs.jdk21}"; };
})
```

marketplace の Git plugin のうち上流の構造を確認したもの(Nix の `gitNames`)は、従来どおり `share/agy-plugins/` に agy 版だけを作る。`nix/npm-sources.json` の `url`・`hash`・`mcpServers`・`skills` は `scripts/update_external_plugins.py --write` が registry と tarball から書く。手で書くのは plugin を足すときの `package` と `version` だけ。

## Claude Code / Codex 共通の構成

| 内容 | 置き場 | 扱い |
| --- | --- | --- |
| スキル本文・参照資料 | `plugins/<name>/skills/` | 両ホストで同じファイルを読む |
| 実行する CLI | `plugins/<name>/bin/` | スキルの配置場所から解決し、対象リポジトリで実行する |
| Claude 向け登録 | `.claude-plugin/plugin.json` | Claude 固有の定義 |
| Codex 向け登録 | `.codex-plugin/plugin.json` | Codex 固有の定義 |
| MCP 接続定義 | `plugins/<name>/.mcp.json` | 共通の正典。Claude 側の定義は生成して照合する |

共通スキルはホスト固有の環境変数・自動コマンド展開・PATH 注入を前提にしない。
ホスト別のスキル本文や CLI を複製せず、登録形式の差だけを各 manifest に置く。
導入時の指示ファイルは対象が使う `AGENTS.md` / `CLAUDE.md` に合わせる。
todo・adr の実行依存は POSIX sh と awk。harness やホスト専用ランタイムには依存しない。

## 外部MCPラッパー

既存の外部MCPを配布・有効化するための薄いパッケージです。実装本体は持たず、manifestと `.mcp.json` のみを正典とします。
プラグインの enable/disable でMCPサーバーが一括起動・停止されます。

| プラグイン | MCPサーバー | 用途 |
|---|---|---|
| `chrome-devtools-mcp` | `chrome-devtools-mcp` | ブラウザ操作・Web検証 |
| `deepwiki-mcp` | DeepWiki (http) | GitHubリポジトリのドキュメントQ&A |
| `markitdown-mcp` | `markitdown-mcp` | ファイル→Markdown変換(dotfiles の packages.nix から nix で入れる) |

Context7はClaude/Codexともに `context7@claude-plugins-official` を使う。OpenAI Developer Docs MCPは[公式の直接設定](https://developers.openai.com/learn/docs-mcp)を使う。開発中のTDR MCPは将来ChatGPT pluginとして扱い、このmarketplaceには含めない。

## 自前MCP実装

MCPサーバーのコード・テスト・配布方法までこのリポジトリで保守するものを置く区分です。現在は該当なしです。Gemini MCPの代替候補であるAntigravity CLI（agy）のPython MCP化を着手する場合は、この区分に追加します。

## スキルプラグイン

| プラグイン | スキル | 用途 |
|---|---|---|
| `todo` | todo, adr, doctor | todo.txt でタスクと依存関係を、docs/adr/ で決定を管理 |
| `telemetry` | review | Langfuse のトレースから自分のセッションを実測し、設定改善に回す |
| `ios-skills` | ios-app-icon, ios-simulator, ios-device-build, appstoreconnect-upload | 実行先の能力判定・Macへのリモート実行・アイコン・Simulator・実機build・ASC upload |
| [`ios-ota`](plugins/ios-ota/README.md) | ios-ota | iOSアプリの自動Ad Hocプロビジョニング、ローカル/リモートOTA配布、ASC CLI Code Mode |
| [`t3`](plugins/t3/README.md) | t3-delegate, t3-limits | T3 Code 内の子タスク委譲と quota 確認 + T3 Code MCP(ryoppippi、MIT)

Supabase・Vercel など公式マーケットプレイスに既にMCP内包プラグインがあるものは重複させず、`claude-plugins-official` 側を使う方針。

`t3` の skill は ryoppippi/dotfiles と ryoppippi/t3-limits から原本のまま写しており(MCP と一緒に配るため plugin に残す)、出典と固定 commit は [`vendor/upstream-skills.json`](vendor/upstream-skills.json) にある。`scripts/sync_upstream_skills.py`(既定は dry-run、`--write` で写し直し)と週次の `.github/workflows/upstream-skills.yml` が差分を確認する。

### harness から todo・ADR へ移行

harness の配布を終了し、タスク管理と決定の記録は [todo](plugins/todo/README.md)
プラグインに切り替えました(adr は 2026-09-10 に todo へ統合)。
経緯はコミットメッセージ、知識は docs に置きます。
このリポジトリのタスクは `todo.txt`、決定は `docs/adr/` にあります。

導入済みのプロジェクトにはコピー済みのフックが残るため、プラグインを外すだけでは移行できません。
[移行手順と旧タスクの対応](docs/harness/migration.md)を参照してください。

### telemetry — 自分の使い方を実測する

`/telemetry:review` は Langfuse のトレースからツール別の時間・失敗・サブエージェントを集計する。
セッションで**実際にどう使われたか**を確認します。
作った直後に自分のフックのバグを2つ暴いた(サブエージェント span の duration が 0、型名が空)。
