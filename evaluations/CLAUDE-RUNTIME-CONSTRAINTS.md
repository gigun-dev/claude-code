# Claude ランタイム側の制約(2026-08-02 実測 / CLI 2.1.220)

**この文書の位置づけ**: `run-agent-eval.py` の Claude アームは、いまのままでは
**サブスク枠で1本も完走しない。** 原因は設計の誤りではなく、
**Claude Code 側の挙動がドキュメントから読み取れない**ことにある。
ここに実測値と再現コマンドを置くので、**信用せず自分で再現してから**直してほしい。

**大前提**: 評価は **API キーではなくサブスクリプション枠**で回す。
`ANTHROPIC_API_KEY` を使う設計は採れない。

> **2026-08-02 runner反映:** `run-agent-eval.py` は§6-bに従って`--bare`を外し、
> strictな空MCP構成、unscored preflight、runごとの`slash_commands` assertを実装した。
> 以下の失敗記録は設計理由と再現証拠として残す。

---

## 1. 🔴 `--bare` はサブスク枠と両立しない

`run-agent-eval.py:218` の `["claude", "--bare", "-p", prompt, ...]`。

```bash
claude --bare -p "テスト" --output-format stream-json --verbose < /dev/null
# → RESULT success / result = "Not logged in · Please run /login"
ANTHROPIC_API_KEY=sk-ant-invalid-probe claude --bare -p "テスト" ... 
# → result = "Invalid API key · Fix external API key"   ← キー経路を使っている証拠
```

公式ドキュメント(authentication.md / headless.md)にも
「bare mode は OAuth と keychain 読み取りをスキップする。`ANTHROPIC_API_KEY` か
`apiKeyHelper` を使え」と明記がある。**仕様。**

> ⚠️ **この失敗は exit code に出ない。** `returncode 0` かつ `RESULT subtype=success` を返す。
> 救いは本文が JSON でないため `validate_final` が落ち `artifact-error` になること
> (`run-agent-eval.py:452-458`)。**全 run が同じ型で落ちるので気づけはする。**

**→ `--bare` を外すこと。**

## 2. 🔴 `CLAUDE_CONFIG_DIR` は「設定するだけ」で認証が切れる

代替案として検討されがちなので先に潰しておく。

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude" claude -p "テスト" ...   # ← 既定パスを明示しただけ
# → "Not logged in · Please run /login"
```

**別ディレクトリに向けたときだけでなく、既定パスを明示しても切れる。**
OAuth 資格情報は macOS Keychain(service `Claude Code-credentials`)にあり、
`~/.claude` の全エントリを symlink して `plugins` だけ空にしても読めなかった。

## 2-b. 🔴 環境変数を絞るなら `USER` を必ず残す

`--bare` を外しても**まだ `Not logged in` になる**場合はこれ。
runner が環境変数を allowlist で絞っており、そこに `USER` が無いと認証が解決できない。

```bash
env -i PATH="$PATH" HOME="$HOME" LANG="$LANG" claude -p "テスト" ...  # → Not logged in
env -i PATH="$PATH" HOME="$HOME" USER="$USER"  claude -p "テスト" ...  # → 通常応答 ✅
env -i PATH="$PATH" HOME="$HOME" LOGNAME="$USER" claude -p "テスト" ... # → Not logged in(代替不可)
```

macOS の Keychain エントリ(service `Claude Code-credentials`)は **`acct` = ユーザー名**で
引かれる(`security find-generic-password -s "Claude Code-credentials"` で確認できる)。
`USER` が無いとアカウントを特定できない。**`LOGNAME` では代替できない。**

> **見つかった経緯**: `--bare` 撤去後の実 preflight が `Not logged in` を返し続けた。
> `clean_environment` の allowlist が `PATH/HOME/LANG/LC_ALL/SSL_CERT_FILE` だけだった。
> **`ANTHROPIC_API_KEY` を渡さない**という正しい方針と、
> **`USER` は渡さないといけない**という制約は対になっている。両方をテストで固定してある
> (`test_claude_environment_does_not_forward_api_auth` /
> `test_claude_environment_forwards_user_for_keychain_auth`)。

## 3. 🔴 プラグイン同梱スキルは実行時に無効化できない

`none`(スキルなし)アームの成立に直結する。**全部試して全部だめだった:**

| 手段 | 結果 |
|---|---|
| `--settings '{"disabledSkills":["ios-skills:ios-simulator"]}'` | ❌ 修飾名でも消えない |
| `--settings '{"disabledSkills":["ios-simulator"]}'` | ❌ |
| `--settings '{"enabledSkills":["<1つだけ>"]}'` | ❌ ホワイトリストも効かない |
| `--settings '{"enabledPlugins":{}}'` / `{"gigun":[]}` | ❌ 73件のまま |
| `--settings '{"disabledPlugins":["ios-skills"]}'` | ❌ 73件のまま |
| `CLAUDE_PLUGINS_DIR=<空ディレクトリ>` | ❌ 32件のまま(**env-vars.md に載っているが効かない**) |
| `CLAUDE_SKILLS_DIR=<空ディレクトリ>` | ❌ 同上 |
| **`--settings '{"disabledSkills":["<プロジェクト/ユーザースキル名>"]}`** | ✅ **これだけ効く** |

```bash
# 効く例(プロジェクトスキルの競合排除)
claude -p "..." --settings '{"disabledSkills":["ios-e2e-verify"]}'
```

**→ サブスク枠 headless で `none` アームは run 単位では作れない。**
残る道は `/plugin disable ios-skills` によるグローバル切り替え(バッチ単位)だけで、
それは **condition 間の順序ランダム化と両立しない**(`run-agent-eval.py:342-343` の shuffle)。

**推奨**: `none` を落とし、**`ios-skills-old` vs `ios-skills-new` に絞る。**
両アームとも同じプラグイン環境を通るので比較は正当に成立する。
ランダム化も保てる。「スキルの有無」ではなく「**旧版と新版のどちらが良いか**」が
そもそも今回の意思決定に必要な問いのはず。

## 4. 🟠 `--plugin-dir` は他プラグインを全部復活させる

```bash
claude --bare -p "テスト" ...                     # slash_commands 41件 / ios系 0
claude --bare -p "テスト" --plugin-dir <ios-skills> # slash_commands 66件 / ios系 4
#   ↑ 差の25件は ios-skills ではなく cloudflare:* hono-skill:* skill-creator:*
#     deslop:* dig:* fix-ci:* decomposition:* …
```

ドキュメントには「`--plugin-dir` は明示指定なので bare でも読む」とあるが、
**他プラグインまで復活する理由の記載は無い。**
§3 の推奨(`none` を落とす)を採れば実害は消える。

## 5. 🔴 MCP を無効化しないと1本も完走しない

```bash
--strict-mcp-config --mcp-config '{"mcpServers":{}}'
```

**無効化しないと、MCP サーバー(この環境で15個)のロードだけで2分を超える。**
`--timeout` の既定600秒でも、実行時間のほとんどが起動待ちになる。

## 6. 🔴 条件が効いたかを **assert** すること

§1〜§4 は**すべて、これがあれば自動で検出できたもの**であり、
**dry-run では原理的に検出できない**(dry-run は CLI を実行しないため)。

`stream-json` の最初のイベントが `{"type":"system","subtype":"init","slash_commands":[...]}`。
これをパースし、**期待するスキル集合と一致しなければ即 fail** させる:

```python
def assert_condition_took_effect(stdout: str, expect_present: set[str], expect_absent: set[str]) -> str | None:
    """条件が本当に効いたかを init イベントで検算する。

    Why: --bare/--plugin-dir/--settings のどれが効いてどれが効かないかは
    ドキュメントから読み取れず、実測でしか分からなかった(CLAUDE-RUNTIME-CONSTRAINTS.md)。
    「無効化したつもりのスキルが載ったままの baseline」は、静かに偽の対照になる。
    """
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            commands = set(event.get("slash_commands") or [])
            missing = expect_present - commands
            leaked = expect_absent & commands
            if missing or leaked:
                return f"condition did not take effect: missing={sorted(missing)} leaked={sorted(leaked)}"
            return None
    return "no init event found; cannot verify condition"
```

**認証失敗の早期検出**も同じ場所で足せる —— `result` の本文が
`Not logged in` / `Invalid API key` で始まっていたら `provider-error` にする
(いまは `artifact-error` に化けるので原因が読み取りにくい)。

---

## 6-b. ✅ サブスク枠で成立する構成(これを採る)

§1〜§4 は「run 単位で条件を切り替えようとする」と詰む。
**バッチ単位で1回だけグローバルに切り替えれば、全部解ける。**

### 前提となる実測

- **`gigun` マーケットプレイスは directory ソースで repo を直接指している**
  (`~/.claude/plugins/known_marketplaces.json`:
  `{"source":"directory","path":".../claude-code"}`)。
  **cache(`~/.claude/plugins/cache/gigun/...`)は使われていない** ——
  cache だけを書き換えても挙動は変わらず、repo を書き換えると変わることを実測で確認済み。
  → **repo を編集すると、稼働中の全セッションのプラグインが即座に変わる。**
- `--plugin-dir <path>` は **`--bare` なしでも効く**(実測: 別名のコピーを渡して読み込まれた)。

### 手順

```bash
# 1) バッチ開始前に一度だけ。以降 run 単位のグローバル操作はしない
claude plugin disable ios-skills@gigun      # 対抗馬を比較するなら build-ios-apps も同様に

# 2) 候補を repo の外へ固定エクスポートする(repo を直接指さない)
#    Why: repo は live に読まれるうえ、他セッションが編集中でありうる。
#    測定中に候補が動くのを構造で防ぐ。
git -C <repo> archive <old-ref> plugins/ios-skills | tar -x -C /eval/candidates/old --strip-components=2
git -C <repo> archive <new-ref> plugins/ios-skills | tar -x -C /eval/candidates/new --strip-components=2

# 3) run ごとに候補を1つだけ注入(--bare は使わない = サブスク枠のまま)
claude -p "<query>" \
  --plugin-dir /eval/candidates/<condition> \
  --no-session-persistence \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --settings '{"disabledSkills":["<競合するプロジェクト/ユーザースキル>"]}' \
  --output-format stream-json --verbose

# 4) バッチ終了後に戻す
claude plugin enable ios-skills@gigun
```

### なぜこれで解けるか

| 問題 | 解消 |
|---|---|
| `--bare` が要る(§1) | **不要になる。** サブスク認証のまま |
| `none` アームが作れない(§3) | `--plugin-dir` を付けないだけ ✅ |
| `--plugin-dir` の他プラグイン復活(§4) | `--bare` を使わないので**そもそも論点が消える**(全アームに他プラグインが等しく存在 = 定数) |
| 順序ランダム化と両立しない | **両立する。** グローバル切り替えは**バッチ前の1回だけ**で、condition ごとではない |
| 測定中に候補が変わる | エクスポート済みコピーを指すので**動かない** |

**残る前提**: 他プラグイン(cloudflare / hono-skill / skill-creator 等)は全アームに存在する。
これは**定数なので比較を壊さない**が、**絶対水準は「他スキルと競合した状態での値」**である
ことを結果に明記すること。

### この構成でも §6 の assert は必須

`ios-skills@gigun` の disable を戻し忘れた状態でバッチを回すと、
**全アームに新版が混入して差が消える。** `slash_commands` の assert がそれを捕まえる。

---

## 6-c. 🔴 MCP はアームごとに変える(全アーム一律に切ってはならない)

§5 で「MCP を無効化しないと完走しない」と書いたが、**これを全アームに一律適用すると
`build-ios-apps` を無力化して、`ios-skills` が構造的に勝つ。** 測定ではなく設計の産物になる。

| | 経路 | MCP を切ると |
|---|---|---|
| `ios-skills` の `ios-simulator` | `xcrun simctl` + `idb`(CLI 専業) | **無傷** |
| `build-ios-apps` の `ios-debugger-agent` | XcodeBuildMCP(`mcp__XcodeBuildMCP__*`) | **本文1行目から実行不能** |

`ios-debugger-agent/SKILL.md` は全体が `list_sims` → `session-set-defaults` →
`build_run_sim` → `describe_ui` / `tap` / `type_text` / `gesture` の MCP 呼び出しで構成されている。

**→ 各プラグインが自分の manifest で宣言した MCP をそのアームに与える。**

| アーム | `--mcp-config` |
|---|---|
| `ios-skills-old` / `-new` / `none` | `{"mcpServers":{}}` |
| `build-ios-apps` | 当該プラグインの `.mcp.json` の中身(xcodebuildmcp) |

代償: `build-ios-apps` アームだけ起動が遅い(初回は `npx -y xcodebuildmcp@latest` の
ダウンロードも走る)。**`--timeout` はアームごとに変えること。**

## 6-d. build-ios-apps を Claude で測るときの前提(2026-08-02 実測)

`openai/plugins` の `plugins/build-ios-apps`(v0.1.2)を取得して実測した。

- **`.claude-plugin/plugin.json` が無い**(`.codex-plugin` のみ)。
  Codex 版から Claude が解釈するキー(`name`/`version`/`description`/`author`/`homepage`/
  `repository`/`license`/`keywords`/`skills`/`mcpServers`)だけを写して生成すれば、
  **`--plugin-dir` で9スキル全部ロードされる**(実測確認済み)。
  `interface` / `composerIcon` 等の Codex 固有キーは落とす。
- SKILL.md の frontmatter は `name` + `description` の標準形で**そのまま互換**。
- `agents/` は `openai.yaml` が10件、Claude 形式の `.md` は0件。
  ただし中身は表示メタデータ(`display_name` / `default_prompt`)で、
  **SKILL.md 本文が agent へ委譲している箇所は無い**(相互参照はファイルパス)。
  → **Claude で agents が欠けることによる機能欠損は無い。**

### Codex 依存の内訳(9スキル)

| スキル | Codex 固有行 | Claude での可否 |
|---|---|---|
| **`ios-debugger-agent`** | **0** | ✅ **`ios-simulator` との唯一の実質的な比較対象** |
| `ios-app-intents` / `swiftui-*` 4本 | 0 | ✅(いずれも ios-skills の守備範囲外 = 比較しない) |
| `ios-memgraph-leaks` | 1 | ✅ mktemp のディレクトリ名だけ。実害なし |
| `ios-ettrace-performance` | 2 | ⚠️ *"In Codex, run `ettrace` with a TTY and answer prompts with `write_stdin`"* —— **`write_stdin` は Codex 固有ツールで Claude に無い** |
| `ios-simulator-browser` | 3 | ❌ **description からして「Codex in-app browser にミラーする」もの。Claude には in-app browser が無く構造的に成立しない** |

**→ 比較は `ios-debugger-agent` に限る。**
`ios-simulator-browser` を Claude 側の採点に含めると、**プラグインの優劣ではなく
ホストの機能差を測ることになる**(Codex 側では正常に動く)。
`ios-ettrace-performance` も同じ理由で Claude 単独の評価には向かない。

---

## 7. 🟠 Claude と Codex の数値を直接比較しない

Codex 側は `--ephemeral --ignore-user-config` + `skills.config=[...]` で、
**Claude 側より厳密に隔離できている**(サブスク枠でも成立する)。
隔離の強さが非対称なので、
**「Codex の方が精度が高い」と「Codex の方が競合スキルが少なかった」が区別できない。**

**→ 比較して意味があるのは各ランタイム内の old vs new。**
   ランタイム間の横並びは出さないか、出すなら**非対称であることを併記する。**

## 8. routing は必ずランタイム別に測る(平均しない)

実測: skill-creator の trigger ハーネス(`scripts/run_eval.py`)は
**「最初の tool_use が Skill/Read でなければ即 False」**という判定だが、
**Opus 5 は必ず Bash/Glob の下調べから入る**ため、実際には扱えるクエリで **0/20** を出した。

Codex は下調べの型が違うので、**同じ物差しが同じ意味を持たない。**
routing だけは両ランタイムで別々に測り、**決して平均しない。**

一方 **script contract / static はランタイム非依存**(bash/python)なので **1回でいい。**
2回回すのは純粋な無駄。

---

## 9. 参考: 今日この制約下で実際に回した測定

`ios-simulator` の description A/B を **120 セッション**回した記録が
`ios-simulator/evals/iteration-5/PREREGISTRATION.md`(事前登録)にある。
結果は old 16/20 vs new 17/20(差 +1 = 事前登録した「差なし」帯の中)。

そのとき使った手法は **実 SKILL.md を書き換えて退避コピーから復元する**もので、
**同時刻に他セッションが同じファイルを編集していれば無言で上書きする。**
実際 38 分後に Codex が同じ repo の再構成を始めていた。**この手法は採らないこと。**
`--plugin-dir` に**コピーを渡す**方が安全(現 runner の設計はこの点で正しい)。
