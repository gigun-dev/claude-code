# Claude Code の文脈機構 — 寿命の対応表

> **最終検証: 2026-08-08(Claude Code 2.1.222)。同日の敵対的検証で事実誤り7件を訂正済み。**
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
| **呼ばれたときだけ要る** | skill 本体 | **compaction 後の再注入時に 5,000 tok** 🟢(初回ロードの上限ではない) |
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

⚠️ **5,000 tok は「compaction 後の再注入時のキャップ」であって、初回 invoke 時のロード上限ではない。**
2026-08-08 まで無条件の上限として書いていた。公式:
> Skill bodies are **re-injected after compaction**, but large skills are truncated to fit the
> per-skill cap. — context-window docs
agentskills.io 側も上限ではなく推奨(`Instructions (< 5000 tokens recommended)`)。

**長い SKILL.md は compaction 後に「前置きが残って手順が消える」。**
日本語は約 1.4 tok/字(4.7 以降)なので **5,000 tok ≒ 3,500 字**。行ではなく文字/トークンで測ること。

---

## 3. フックの出力上限は 10,000 文字 🟢(公式明記)

> Hook output strings, including `additionalContext`, `systemMessage`, and plain stdout,
> are capped at **10,000 characters**. Output that exceeds this limit is **saved to a file and
> replaced with a preview and file path**. — https://code.claude.com/docs/en/hooks

⚠️ **2026-08-08 まで、ここを「🟠 issue 報告(#70460 / #42369 / #84021)。公式の 50K は誤り」と
書いていた。**数字も挙動も合っていたが、**位置づけが古かった** —— いま公式が明記している。
issue が指していた 50K は docs ではなく v2.1.89 の CHANGELOG。
**「賞味期限が短い」と書いた当のファイルが、再検証の手順を持ちながら実行されずに腐っていた。**

⚠️ 超過時の挙動は「2KB のプレビュー」ではなく「**ファイルへ退避 + プレビューとパス**」。
   harness の警告文言はプレビューが出る前提で書いてあり、そこは変わらない
   (**頭の後半が読まれない**のは同じ)。


**harness の頭の予算 8,000 *文字* はこれに対する余裕**(2,000字ぶん)。
⚠️ 2026-08-07 まで 8,000 *バイト* で運用していたが、これは #70460 の "10K" を
バイトと読み違えたもの。日本語 3B/字なので実効 2,700字 —— **実際の上限の 27% で
鳴らしていた。**単位はここでは文字。

**🔵 実測: `SessionStart:compact` は発火する。**このリポジトリで7回(中央値 37ms)。
`matcher` に `compact` を書けば compaction 後にも走る。

**matcher の完全な一覧 🟢**(https://code.claude.com/docs/en/hooks のマッチャ表):
`startup` / `resume` / `clear` / `compact` / `fork` の5つ。
⚠️ 2026-08-08 まで「⚪ 未確認、`fork` は不明」と書いていた。**公式に一覧がある。**

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
> **設定を読む前に無条件で `"on"` を返す。**効くのは `~/.claude/skills/` 配下と bundled skill だけ。
> ⚠️ **2026-08-08 まで「公式ドキュメントにこの但し書きは無い」と書いていたが、誤り。**
> 公式に明記されている: `Plugin skills are not affected by skillOverrides.
> Manage those through /plugin instead.` — https://code.claude.com/docs/en/skills
> **「公式に書かれていない挙動が実在する」の実例としてここを使っていたが、その用途では成立しない**
> (挙動そのものはバイナリで再現できるので、事実としては残る)。

**🔵 `disable-model-invocation: true` はプラグイン skill でも効く**(`/context` の一覧に
`harness:status` が出てこない)。description ごと listing から外れるので予算も食わない。

---

## 4.5 トークン数の数え方 —— ローカルトークナイザは存在しない 🔵

**2026-08-08、バイナリ(2.1.222・271MB)で確認。**予算をトークンで持つなら、まずこれを知ること。

| 探したもの | ヒット |
|---|---|
| `cl100k` / `o200k` / `merges.txt` / `vocab.json` / `bpe_ranks` / `special_tokens` | **すべて 0 件** |
| `/v1/messages/count_tokens`(POST) | あり |
| `count_tokens_unreachable`(テレメトリのイベント名) | あり |

**Claude Code は BPE テーブルを持っていない。**正確なトークン数が要るときは
**API を叩いている**(`POST /v1/messages/count_tokens`)。

そして API が届かないときの挙動が、そのまま我々の設計の答えになっている:

```js
// /plugin の詳細表示(バイナリから復元)
w = { always_on: S.reduce((k,O) => k + O.chars.always_on, 0), ... }  // ← 文字数を集計
A = m[p[0]]                                                          // ← API 由来のアンカー
R = A?.always_on ?? i(w.always_on, w.always_on, void 0)              // ← 無ければ文字数だけで概算
...
if (A) Se("cli_plugin_details")
else   Oe("cli_plugin_details", "count_tokens_unreachable")
g.push("  Token counts are estimates and may differ from actual usage.")
```

**つまり Claude Code 自身が「コンポーネントごとの文字数 + API で測った1点のアンカー」で
トークンを按分しており、アンカーが取れなければ文字数だけの概算に落ちて、
"Token counts are estimates and may differ from actual usage." と明示する。**

**帰結(harness の予算設計に直結):**

1. **ローカルで正確に数える方法は無い。** tiktoken は OpenAI の語彙で、Claude とは別物
   (特に日本語で大きくズレる)。使ってはいけない。
2. **フックから API は叩けない。** 毎セッション開始時のネットワーク往復・認証情報・
   オフラインでの沈黙 —— 原則4(検知器は黙って死ぬ前提)に正面から反する。
3. **だから概算しかない。**位置づけは Claude Code の**フォールバック側と同じ**であって、
   劣った代用品ではない。`≒` の表示は Claude Code の
   "estimates and may differ" と同じ開示。
4. **ただし harness の概算は言語で重み付けする**(英語 ≒ 0.33 tok/字・日本語 ≒ 1.4 tok/字)。
   Claude Code のフォールバックは文字数のみで言語を区別しないので、日本語混在の
   リポジトリではこちらのほうが実態に近い。
5. ⚠️ **トークナイザはモデルの属性。4.7 で切り替わっており、同じ文字列で約 30% 増える** 🟢
   > "Claude 4.7 and later models use a newer tokenizer. The same input text produces
   >  **approximately 30 percent more tokens** than on earlier models."
   > — platform.claude.com/docs/en/build-with-claude/token-counting

   | モデル | トークナイザ |
   |---|---|
   | Opus 5 / Sonnet 5 / Fable 5 / Mythos 5 | **新**(4.7 系) |
   | Haiku 4.5 およびそれ以前 | 旧 |

   **当初 0.25 / 1.1(旧トークナイザの文献値)を置き、「日本語 1.1 は過大だから安全側」と
   書いたが、方向が逆だった** —— 現行モデルでは約 30% **過小**、つまり
   「予算内に見えて実は超過」= 沈黙する失敗の側に倒れていた。× 1.3 して 0.33 / 1.4。
   スクリプトはセッションのモデルを知れないので**多い側に固定する**(旧モデルでは過大 = 安全側)。
6. ⚠️ **係数は定数ではなく、上書き可能な既定値として実装すること。**
   **harness はエージェント非依存**(Codex アダプタを配る)なのに、**トークナイザは
   ベンダー固有** —— Claude と GPT では語彙が違う。文字はテキストそのものの属性だが、
   トークンは「テキスト × トークナイザ」の属性なので、配布物に定数として埋めると
   他クライアントで黙って嘘をつく。実装は env で差し替え可能にし、出力にラベルを出す:
   `HARNESS_TOK_ASCII_PCT` / `HARNESS_TOK_WIDE_PCT` / `HARNESS_TOKENIZER_LABEL`。
   **文字数の予算だけはベンダー非依存なので、ゲートは常に文字側が主。**
   (言語で加重する構造自体はベンダー非依存 —— 英語中心の BPE なら日本語が高いのは共通で、
    変わるのは倍率だけ。だから構造は残して係数だけ外に出す。)
7. **較正は `scripts/calibrate.sh` で実際のトークナイザに当てられる** 🔵
   (`--claude` = count_tokens API・**無料**、`--gpt` = ローカルの tiktoken)。
   **`!` 記法には絶対に置かない** —— 外向きの通信を行いうるため、必ず明示起動。

   **⚠️ ファイルは2本以上渡す。**未知数が2つ(ASCII 係数・非ASCII 係数)あるので
   1本では原理的に解けない。初版は ASCII 側を固定して1本で解いており、日本語率 1% の
   ファイルで **`WIDE_PCT = -679`(負)** を出した。いまは切片なしの最小二乗で両方を解く。

   **🔵 実測(2026-08-08、日本語率 1% / 25% / 44% の3本、o200k_base):**

   | トークナイザ | ASCII | 非ASCII | 最大残差 |
   |---|---|---|---|
   | `o200k_base`(GPT / Codex) | **25** | **102** | **0.8%** |
   | Claude 4.7+ | **35** 🔵 | 140 ⚠️ | 9.5% |

   **線形モデル(tok = a·ASCII数 + w·非ASCII数、切片なし)は残差 1% 未満で成立する。**
   非ASCII を1種類に丸めている(かな・漢字・記号でトークン単価は違うはず)にもかかわらず
   この精度なので、**予算の用途にはこのモデルで足りる。**

   **同じ文書が Claude 換算と GPT 換算で 35% 違う** —— 係数を配布物の定数にしなかった
   判断は、この数字で裏付けられている。

   **🔵 Claude 側の実測(2026-08-08。API キー不要・ネットワーク不要)**

   **セッションの transcript(`~/.claude/projects/<repo>/<session>.jsonl`)には、毎リクエストの
   `usage` が入っている。これは Anthropic 側で実際にトークナイズされた結果。**
   `/context` を人が読む必要すら無い —— **「もう払った計算」はここにも落ちている。**
   連続するリクエストの `input + cache_creation + cache_read` の差分と、その間に足された
   本文の文字構成を突き合わせれば、係数が解ける(669観測)。

   結果: **ASCII 0.345(全標本)/ 0.37(大きい観測6本を `calibrate.sh --manual` へ通した値)。
   どちらも既定の 0.33 より大きい = 既定は過小評価していた**(沈黙する失敗の側)。
   → **0.35 へ上げた。**保守的に2つの推定値の下側を採っている。

   ⚠️ **非ASCII は 140 のまま据え置いた。同じ較正が 125 を出したにもかかわらず。** 理由:

   1. **分解できていない。**日本語率 40〜47% の観測に絞っても係数は **1.18〜1.60 に散らばり、
      1.40 を跨ぐ。**最大残差 9.5% は o200k の 0.8% と比べて桁違いに粗い。
   2. **測定に上向きのバイアスがある。**1ターンの差分には system-reminder・タスク一覧など
      **私が数えられない挿入が ≒1,300 tok** 含まれる。切片で吸収しきれない分が係数に乗る。
   3. ⚠️ **125 を採ると、ios-skills の頭が 3,014 → 2,857 tok になり予算超過の警告が消える。**
      文書は1文字も変わっていないのに。これは「閾値を上げて警告を消す」と**効果が同じ**。
      **ノイズに埋もれた推定で警告を消してはいけない。**

   **だから片側だけ採った** —— 安全側(過小評価の是正)は採り、警告を消す側は採らない。
   非ASCII を確定させるには、この経路より分解能の高い測定が要る
   (`--claude` = count_tokens API、または日本語のみの大きなファイル1本を単独ターンで読む)。

---

## 5. サブエージェントに届かないもの

| | 状況 |
|---|---|
| 親の会話履歴 | 🟢 継承しない(`context: fork` のみ例外) |
| `CLAUDE.md` | 🟢 継承する。**ただし Explore と Plan だけは省く** |
| **`.claude/rules/`** | 🟢 **継承する。**公式が `project rules` を名指しで列挙(下の引用) |
| **SessionStart フック** | 🟢 **subagent では発火しない。**ただし **`SubagentStart` が存在する**(下記) |
| skills | 🟢 継承しない。`skills:` に明示列挙が要る |
| auto memory | 🟢 継承しない ⚠️ ただし「実際には入っていた」という反証報告あり(#77261) |

> A non-fork subagent's initial context contains: … **CLAUDE.md files**: every level of the
> CLAUDE.md hierarchy the main conversation loads, including `~/.claude/CLAUDE.md`,
> **project rules**, `CLAUDE.local.md`, and managed policy files.
> **The built-in Explore and Plan agents skip this.**
> — https://code.claude.com/docs/en/sub-agents

⚠️ **2026-08-08 まで逆を書いていた**(「rules は継承しないと複数人が報告。公式は CLAUDE.md
しか名指ししていない」)。**公式は project rules を名指ししている。**
🟠 の第三者報告を、公式を取り直さずに採用していたのが原因 —— このファイルの再検証手順は
「公式を取り直す(要約や記憶で判定しない)」と書いてあり、**それを実行していなかった。**

**帰結(訂正後):** `paths:` 付き rules は**サブエージェントにも届く**(Explore / Plan を除く)。
ただし `paths:` のスコープが効くので、**そのサブエージェントが該当ファイルを触るまでは載らない**。
確実に届けたいものは、いまも**プロンプト本文に明示的に載せるのが最短**。

### `SubagentStart` フックがある 🟢

| Event | When it fires | 注入 |
|---|---|---|
| `SubagentStart` | When a subagent is spawned | `hookSpecificOutput.additionalContext`(decision control 無し) |

入力に `agent_id` / `agent_type` が入る。**「SessionStart が発火しないから本文へ載せるしかない」は
誤り** —— サブエージェント向けの注入経路は存在する(2026-08-08 に公式で確認)。

### ⚠️ subagent の返り値はセッションを殺せる 🟠

> compaction only runs **between turns**, not during a turn. — #68584

大きな返り値はターンの途中で一括注入され、**compaction を飛び越える**。
#82402 では 1MB の JSONL エントリでセッションが回復不能になっている
(**compaction 自体が肥大した文脈をロードする必要があるため**)。
**subagent の出力サイズは自分で縛ること。**

---

## 6. その他の実測値

- **CLAUDE.md**: ⚠️ **「40,000字で警告」の出典は確認できなかった** ⚪(2026-08-08 に再検証)。
  公式 memory docs にあるのは行数の目安だけ:
  > **Size**: target under 200 lines per CLAUDE.md file. Longer files consume more context and
  > reduce adherence. … **CLAUDE.md files are loaded in full regardless of length.**

  バイナリ 2.1.222 を `40,000` / `40000` / `4e4` で走査しても CLAUDE.md 関連の文字列は出ない
  (同じ手法で `skillListingBudgetFraction` 等は取れるので、探索が効かなかったわけではない)。
  **harness は `CLAUDE_MD_HARD_CHARS` を撤去した** —— 機構の裏付けが無い閾値は持たない。
  残るのはトークン予算(毎セッションの実費 + サブエージェントぶんの乗算)で、こちらは
  自前の根拠で立つ。
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

1. **compaction 後に `paths:` 付き rules は本当に消えるか**(§2 の矛盾1)
3. **`name-only` に落とした skill が自動発火するか** —— on-the-wire でバイト数は実測されているが、
   **発火するかの前後比較は世界中どこにも無い**
4. **description を磨くと発火率が上がるか** —— 測定を試みた3件は lift ゼロ / 0/40(原因は
   隣接 skill による捕捉)/ 代理指標のみ。**成功報告は見つかっていない**
4. **CLAUDE.md にサイズ由来の警告・切り詰めが本当に無いか**(公式は「長さに関わらず全文ロード」)
5. **`SubagentStart` に harness の頭を載せるべきか**(載せると乗算コストになる。未裁定)

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
