# Claude Code の文脈機構 — 寿命の対応表

> **最終検証: 2026-08-08(Claude Code 2.1.222)。**
> **180日を超えていたら、使う前に一次情報を取り直すこと。**この分野は数ヶ月で変わる。
> 再検証の手順は末尾。

**これは Claude 専用の知識。**harness はエージェント非依存(`.codex/` アダプタを配る)なので、
配布物の中核ではなくここに隔離してある。判断規則は `docs/principles.md` が正典。

**証拠の強さ:** 🟢 公式明記 / 🟡 公式から演繹 / 🔵 実測(このリポジトリ) / 🟠 issue 報告 / ⚪ 未確認

---

## 1. 何をどこに置くか(これだけ覚えれば足りる)

**判断は「この情報はいつ死ぬべきか」。**生き残ることは目的ではない —— 寿命の短い情報を
永続機構に置くと、**毎リクエスト課金され続けるのに誰も気づかない。**

| この情報が死ぬべきタイミング | 置き場 | 上限 |
|---|---|---|
| **タスクが変わったら死ぬ** | `.claude/rules/*.md` の `paths:` 付き | — |
| **セッション中ずっと要る** | `CLAUDE.md`(project-root) | 40,000字で警告 🟠 |
| **開始時に方向づければよい** | SessionStart フックの stdout | **10,000字** 🟠 |
| **呼ばれたときだけ要る** | skill 本体 | **5,000 tok** 🟢 |
| **永久に残すがロードしない** | ディスク上のファイル + ポインタ | — |

---

## 2. compaction を生き延びるもの / 消えるもの 🟢

出典: https://code.claude.com/docs/en/context-window#what-survives-compaction

| | 挙動 |
|---|---|
| `CLAUDE.md`(project-root)/ unscoped rules | **Re-injected from disk** |
| auto memory(`MEMORY.md`) | **Re-injected from disk**(先頭200行 or 25KB) |
| **invoked** な skill 本体 | **Re-injected。ただし 5,000 tok/skill・25,000 tok 合計。古いものから落ちる** |
| **`paths:` 付き rules** | **Lost until a matching file is read again** |
| nested `CLAUDE.md` | Lost until a file in that subdirectory is read again |
| 未 invoke の skill 本体 | 落ちる |
| SessionStart フックの出力 | 🟡 hooks 自体は "not applicable"。**注入内容は通常の会話履歴なので要約される** |

**`paths:` 付き rules の "until" が要点。**離れたら死に、また触れば生き返る ——
**欠陥ではなく寿命設計。**タスクが変われば死ぬべきものが、ちゃんと死んでいる。

> ⚠️ **矛盾1(未解決)。** issue #52176(2026-04、CLOSED NOT_PLANNED)は `InstructionsLoaded`
> フックのテレメトリで「`.claude/rules/*.md` と `~/.claude/CLAUDE.md` が `load_reason: compact` で
> **3回ずつ再ロードされる**」と実測している。公式の表と正面から食い違う。
> **公式が現行・#52176 が4月時点**と読むのが自然だが断定しない。
> **測り方**: `InstructionsLoaded` フックを1つ仕掛けて `/compact` を打ち、`load_reason` を見る。

### skill 本体の切り詰めは「末尾から」🟠

> **Truncation is a byte offset, not a semantic boundary.** The cut keeps the **head**
> and discards the **tail** (the actual procedure). **That is backwards.** — issue #82144

**長い SKILL.md は compaction 後に「前置きが残って手順が消える」。**
日本語は約 1.1 tok/字なので、**5,000 tok ≒ 180行**。行数ではなくトークンで測ること。

---

## 3. SessionStart フックの出力上限は 10,000 文字 🟠(公式の 50K は誤り)

| issue | 状態 | 内容 |
|---|---|---|
| #70460 | OPEN | 10,000字超は**2KB のプレビューだけ**注入。残りは無言で消える |
| #42369 | CLOSED | **v2.1.89 の CHANGELOG は 50K と書いているが、実測は 10K** |
| #84021 | OPEN(2026-08-05) | 内部関数 `persistHookOutput` の閾値が 10,000。`additionalContext` も同じ |

**harness の頭の予算 8,000B はこれに対する余裕。**日本語は 3B/字なので 8,000B ≒ 2,700字で、
文字数上限に対しては十分に安全側。

**🔵 実測: `SessionStart:compact` は発火する。**このリポジトリで7回(中央値 37ms)。
`matcher` に `compact` を書けば compaction 後にも走る。

> ⚠️ **matcher の完全な一覧は ⚪ 未確認。** 公式ドキュメントから確認できたのは
> `startup` / `resume` / `clear`。`compact` は実測で発火するが、`fork` は未確認。

---

## 4. skill listing の予算 🟢 + 🔵

```
budget = contextWindow × 4 × skillListingBudgetFraction
```

**`contextWindow` はモデルの実際の窓。**バイナリの `mF_=200000` は**引数の既定値**であって
固定値ではない。**1M モデルなら予算 40,000字、200k モデルなら 8,000字。**

- `skillListingBudgetFraction` 既定 `0.01` 🟢
- `skillListingMaxDescChars` 既定 `1536`(description + `when_to_use` の合計)🟢
- `SLASH_COMMAND_TOOL_CHAR_BUDGET`(環境変数)があると **fraction は読まれない**(早期 return)🟠

**超過時は使用頻度の低い順に description が落ち、名前だけになる** 🟢。**警告は出るが、
出ないケースの報告も複数ある** 🟠。

**実測の口は `/context` の Skills 行**(予算適用後の実サイズ。v2.1.196 以前は表示バグあり 🟢)。
**ディスク上のファイルを足し合わせた推計は分母を間違えうる** —— 2026-08-08 に実際にやった。

> ⚠️ **矛盾2(決着済み)。** 公式は超過対策に `skillOverrides: "name-only"` を勧めるが、
> **プラグイン由来の skill には効かない。🔵 このマシンのバイナリで確認:**
> ```
> $ grep -ao 'e.source==="plugin")return"on"' .claude-wrapped
> e.source==="plugin")return"on"
> ```
> **設定を読む前に無条件で `"on"` を返す。**公式ドキュメントにこの但し書きは無い。
> 効くのは `~/.claude/skills/` 配下と bundled skill だけ。

**🔵 `disable-model-invocation: true` はプラグイン skill でも効く**(`/context` の一覧に
`harness:next` が出てこない)。description ごと listing から外れるので予算も食わない。

---

## 5. サブエージェントに届かないもの

| | 状況 |
|---|---|
| 親の会話履歴 | 🟢 継承しない(`context: fork` のみ例外) |
| `CLAUDE.md` | 🟢 継承する。**ただし Explore と Plan だけは省く** |
| **`.claude/rules/`** | 🟠 **継承しないと複数人が報告。**公式は CLAUDE.md しか名指ししていない |
| **SessionStart フック** | 🟠 **subagent では発火しない**(#46696) |
| skills | 🟢 継承しない。`skills:` に明示列挙が要る |
| auto memory | 🟢 継承しない ⚠️ ただし「実際には入っていた」という反証報告あり(#77261) |

**帰結: 引き継ぎ情報は subagent のプロンプト本文に明示的に載せる。**
「rules に置けば届く」は main セッション限定の話。

### ⚠️ subagent の返り値はセッションを殺せる 🟠

> compaction only runs **between turns**, not during a turn. — #68584

大きな返り値はターンの途中で一括注入され、**compaction を飛び越える**。
#82402 では 1MB の JSONL エントリでセッションが回復不能になっている
(**compaction 自体が肥大した文脈をロードする必要があるため**)。
**subagent の出力サイズは自分で縛ること。**

---

## 6. その他の実測値

- **CLAUDE.md**: 40,000字で警告が出る 🟠。**ハード上限の証拠は無い** ⚪。
  mid-session の編集は現セッションに反映されない(次の `/clear` `/compact` 再起動から)🟢
- **auto memory**: 先頭200行 or 25KB、**先に来た方**。ハードコード 🟢
- **`@import`**: CLAUDE.md 内では session start に無条件展開 🟢。
  **rules 内では `paths:` を無視して全展開される** 🟠(#66027、第三者再現あり)。
  さらに「import した内容が context に一度も届かなかった」という対照実験もある 🟠(#77963)
- **symlink**: **CLAUDE.md が symlink 側のとき書き込みが拒否される** 🟠(#66559)。
  `ln -s CLAUDE.md AGENTS.md`(実体が CLAUDE.md)は安全。逆向きは壊れる。
  **`.claude/` ディレクトリ自体を symlink にすると settings / plugin / `mcp add` が全滅する**
- **context overflow**: 古い tool 出力から消され、次に会話が要約される 🟢。
  同じ文脈が即座に埋まる場合は数回で諦めてエラーになる(無限ループ防止)🟢

---

## 分かっていないこと(⚪ 未確認。埋まったらここから消す)

1. **SessionStart matcher の完全な一覧**(`fork` は有効か)
2. **compaction 後に `paths:` 付き rules は本当に消えるか**(§2 の矛盾1)
3. **`name-only` に落とした skill が自動発火するか** —— on-the-wire でバイト数は実測されているが、
   **発火するかの前後比較は世界中どこにも無い**
4. **description を磨くと発火率が上がるか** —— 測定を試みた3件は lift ゼロ / 0/40(原因は
   隣接 skill による捕捉)/ 代理指標のみ。**成功報告は見つかっていない**
5. CLAUDE.md がサイズを理由に無視される証拠

---

## 再検証の手順

1. **公式を取り直す**(要約や記憶で判定しない):
   - https://code.claude.com/docs/en/context-window — compaction の表
   - https://code.claude.com/docs/en/memory / settings / skills
2. **自分の環境で測る** —— `/context`(実サイズ)、`/doctor`(listing の最大消費者)、
   `--debug`(超過時の警告)。**推計より実測を優先する。**
3. **バイナリで確かめる** —— 設定が効かない疑いがあるときは
   `grep -ao '<パターン>' "$(readlink -f "$(command -v claude)")"`。
   公式ドキュメントに但し書きが無い挙動が実在する(§4 の矛盾2がその実例)。
4. **変わっていたらこのファイルの日付と該当行を更新する。**
   ⚪ が埋まったら「分かっていないこと」から消す。
