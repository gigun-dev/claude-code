#!/usr/bin/env bash
# harness-template v0.15.0 (配布元: gigun-dev/claude-code plugins/harness)
#   — next-directions.md の「着手順」節を読んで一覧化し(読み取り専用)、
#     ID 指定で「着手順」節と「完了記録」節**だけ**を書き換える(--add / --done / --note / --archive)。
#
# 書き込み側の設計意図(2026-08-07 追加):
#   **スクリプトを唯一の書き手にする。** それまで着手順の項目はエージェントが手で書いており、
#   そのために SKILL.md に「ID はバッククォート囲み」「`→ 完了条件:` の位置」「証拠行は項目の
#   最後」といった**手で書くときに間違えないための説明**が約20行あった。書式を機械が書けば
#   ドリフトは構造的に起きなくなり、散文の側は消せる(公式 agentskills.io のスクリプト化基準:
#   「一発で正しく書けないほど複雑」「毎回同じロジックを再発明している」に合致する)。
#
#   **不変条件は4つ。実装として守れなければ失敗とみなす:**
#     1. **ID は再利用しない。** 採番は「着手順」だけでなく**ファイル全体**(完了記録・カタログ部
#        を含む)を走査した最大値+1。着手順だけを見ると、アーカイブ済みの ID を再利用して
#        log.md からの参照(`H-1` は何だったか)が別物を指すようになる。
#     2. **`--done` は `--evidence` 必須。** 証拠なしで `[x]` にする経路を持たせない。
#        従来は --lint が事後に叱る形だったが、**そもそも作れなくする**方が強い。
#     3. **`--archive` は既定 dry-run。** 破壊的操作は plan → validate → execute。
#        `--apply` を付けたときだけ書き換える。
#     4. **触るのは「着手順」節と「完了記録」節だけ。** 現在地・カタログ部・マーカー行には
#        1バイトも触らない(log-index.sh が「マーカー間だけ」を守っているのと同じ規律)。
#
#   **fail-closed は読み側と同じ。** パースできない / 未知の ID / 節が無い —— いずれも
#   **何も書かずに**非0で落ちる。「たぶんこうだろう」で書いた1行が正典に混ざる方が、
#   落ちるより高くつく(書式ドリフトの発生源になる)。
#
#   **書き込みは一時ファイル + mv。** 同一ファイルシステム内の mv は atomic なので、
#   途中で落ちても正典が半分だけ書き潰された状態にはならない(log-index.sh と同じ流儀)。
#
# 読み取り側の設計意図(2026-08-06):
#   **正典は next-directions.md のまま。** tasks.yaml のような構造化ファイルは作らない —
#   本文と別に真実の置き場を作ると、片方だけ更新されて必ず乖離する(memory bank 系が
#   「significant manual maintenance が要る」と言って上流ごと死んだのと同型の失敗)。
#   代わりに「着手順」節**だけ**を最小限の書式で縛り、そこをパースする。現在地とカタログ部は
#   散文のまま = 人が書きやすい形を壊さない。**機械可読にする範囲を最小にするのが要点。**
#
#   **fail-closed。** 項目0件は「タスクが無い」ではなく「書式かパーサが壊れた」として非0で落とす。
#   この repo では実際に、鮮度検査の正規表現が実物にマッチせず2リポジトリで黙って死んでいた
#   (docs/harness/next-directions.md の既知の不具合1・全角括弧の件と同型の再発)。
#   0件を正常扱いすると同じ死に方をする。「計測は寛容に、教える書式は厳密に」の原則どおり、
#   書式のドリフトは --lint で先に鳴らす(項目行に見えるのに ID が取れない行を違反にする)。
#
#   **出力は3区分。** 未完/完了の2区分ではなく「次にやること / 完了(証拠あり) / 整理対象」。
#   一覧を作る時点でどうせ完了項目も読むので、そこで「もう頭に置く理由が消えた項目」を
#   出さないのは情報の捨て損。出典: sceneview/sceneview の handoff コマンドは完了項目を
#   STATE.md から handoff.md へ "it MOVES, not copies" と明示して 400 行でローテートしている。
#   積層方式の弱点(単調増加が人間の規律に依存する)を、毎回件数を出すことで潰す。
#   ただし**このスクリプトは読んで出すだけで、移動はしない**(移動は /harness:tidy の仕事)。
#
#   読み取り専用。**何も書き換えない。** ただし survey.sh / check.sh と違い exit 0 は保証しない —
#   異常を終了コードで表に出すのが仕事なので。したがって SKILL.md の `!` 記法
#   (スキルを読んだだけで無条件に走る)には**置かない**。`!` は「必ず成功する読み取り専用」だけ。
set -euo pipefail

# --- 閾値(頭の文字数とトークン数) --------------------------------------------
# **2026-08-08 に単位を「バイト/行」から「文字/トークン」へ変えた。**経緯:
#
#   旧: HEAD_WARN_BYTES=8000 / HEAD_WARN_LINES=80。どちらも**どの機構も使っていない単位**。
#   - バイト: #70460 の "10KB" をバイトと読んだが、原文と #84021(内部の persistHookOutput)は
#     **10,000 *文字***。日本語 3B/字なので 8,000B ≒ 2,700字 —— 実際の上限の 27% で
#     鳴らしていた。**単位の読み違いで 3.7 倍きつく縛っていた。**
#   - 行: 実測すると行は言語構成に完全に依存する。notchbar/CLAUDE.md(87行・日本語率1%)は
#     1,202 tok、swift-mcp-app(109行・36%)は 2,788 tok —— 行数が同程度でトークンは 2.3 倍。
#     **複数リポジトリへ配る harness にとって行は最悪の単位。**
#
#   そもそも**代理指標は人が目視で数えるときに要るもの**で、スクリプトが測るなら
#   文字もトークンも正確に出せる。「ロジックをスクリプトへ寄せる」と決めた以上、
#   代理を残す理由は消えている(旧実装は消すどころか行の予算を doctor 側へ増やしていた)。
#
# **予算は2本立てにする。単位が違うのではなく、制約している機構が違うから。**
#
#   (1) 文字数 —— **切り詰め**への備え。#70460 / #84021。10,000字を超えると 2KB の
#       プレビューだけが注入され、残りは無言で消える。これは機械的な壁。
#   (2) トークン数 —— **毎セッションの実費**。頭は SessionStart で毎回注入されるので、
#       ここが太ると全セッションのコストになる。切り詰められなくても払い続ける。
#       3,000 tok ≒ 200k 窓の 1.5%。**これは資源配分であって検知器の閾値ではない**
#       (docs/principles.md 規則8)—— 上げるなら「毎セッションいくら払うか」を意識的に決める。
#
# ⚠️ 閾値を上げて警告を消すのは禁止(棚卸しが正)。棚卸し後に現況へ「下げ直す」方向のみ
#    調整してよい(上げ方向を許すと検知がラチェット式に静かに死ぬ)。
#    **単位を直したこの変更は「上げ」ではなく「間違った物差しの交換」**だが、実効は緩和側
#    (実測 4,065字 = 新予算の 51%、旧バイト予算では 97% だった)。緩和だという事実は隠さない。
#
# 予算は配布元の正典 `plugins/harness/budgets.sh` から読む。**ここには数値を書かない。**
# 2026-08-08 まで同じ値がここと assets/session-start.sh の2箇所にあり、隣には
# 「⚠️ この4つの値は … と一致していなければならない」という**散文の規律**が置かれていた。
# 決定論的に検査できることを人間の注意力に委ねていた形で、実際 #70460 の "10K" を
# バイトと読み違えた誤りが**5箇所へ伝播した**のはこれが原因。
# 配布物は install 時に展開されて値を受け取るので、実行時依存は生まれない(原則7)。
BUDGETS="$(cd "$(dirname "$0")/../../.." && pwd)/budgets.sh"
# shellcheck source=/dev/null
[ -r "$BUDGETS" ] || { echo "✗ 予算の正典が読めない: $BUDGETS" >&2; exit 2; }
. "$BUDGETS"

# 文字数とトークン数の計測。**ロケールに依存させない**のが要点 ——
# `wc -m` はロケール次第でバイト数を返す(LANG 未設定の macOS が実際にそう)ので使えない。
# 代わりに UTF-8 の構造を直接使う:
#   - 文字数 = 継続バイト(0x80-0xBF)を全部落とした残りのバイト数(1文字1バイトに潰れる)
#   - ASCII 文字数 = 0x00-0x7F だけ残したバイト数
# トークンは概算。**英語 ≒ 0.33 tok/字、日本語 ≒ 1.4 tok/字** を混合率で加重する。
#
# **なぜ概算しかないのか(2026-08-08、バイナリ 2.1.222 で確認した事実):**
#   Claude Code は**ローカルにトークナイザを持っていない** —— 271MB のバンドルに
#   cl100k / o200k / merges.txt / vocab.json / bpe_ranks はいずれも 0 件。正確な数が要るときは
#   `POST /v1/messages/count_tokens` を叩き、届かないときは `count_tokens_unreachable` を
#   記録して**文字数だけの概算に落ち**、"Token counts are estimates and may differ from
#   actual usage." と明示する。**この式はその フォールバックと同じ位置**であって、劣った
#   代用品ではない(むしろ言語で重み付けする分、日本語混在では実態に近い)。
#   ⚠️ フックや検査から API は叩けない —— 毎セッションのネットワーク往復・認証情報・
#      オフラインでの沈黙。原則4 に正面から反する。詳細は
#      plugins/harness/skills/doctor/references/context-mechanics.md §4.5。
#
# ⚠️ **係数は 2026-08-08 に 0.25 / 1.1 から引き上げた。最初に置いた方向が誤っていた。**
#    公式(platform.claude.com/docs/en/build-with-claude/token-counting):
#      "Claude 4.7 and later models use a newer tokenizer. The same input text produces
#       **approximately 30 percent more tokens** than on earlier models."
#    0.25 / 1.1 は**旧トークナイザの文献値**で、Opus 5 を含む 4.7 以降では約 30% 過小。
#    「日本語 1.1 は過大だから過小評価には倒れない」と書いていたのは**逆で、実際は
#    危険側**(予算内に見えて実は超過 = 沈黙する失敗)に倒れていた。× 1.3 して 0.33 / 1.4。
#
# ⚠️ **トークナイザはモデルの属性であって、テキストの属性ではない。**同じ文字列でも
#    4.7 未満と 4.7 以降で 30% 違う。スクリプトはセッションのモデルを知れないので
#    **新しい(=多い)側に固定する** —— 旧モデルでは過大評価になるが、過大は安全側。
#    これは `mF_=200000` を固定値と読み違えたのと**同じ種類の誤り**
#    (環境に依存する値を定数として扱う)。予算まわりで2回目なので、規則化した:
#    docs/principles.md 規則8「測れないものを予算にするとき」。
# ⚠️ まだ実測で較正していない。較正の口は `/context`、または count_tokens API
#    (**無料**。RPM 制限のみ。ただし API キーが要る)。突き合わせるまで「正しい」と書かない。
# ⚠️ **概算であることを出力に明示すること**(`≒`)—— 精密な数字に見えると、
#    予算の議論が「あと何トークン入るか」の帳尻合わせに化ける。
# Why not python3/tiktoken: (1) tiktoken は **OpenAI の語彙**で Claude とは別物。日本語で
#   大きくズレるので使ってはいけない。(2) 配布先に python3 がある保証が無く、無いと
#   **黙って計測が消える**(原則4)。tr は POSIX で必ずある。
# 検算: 2026-08-08 に python3 の文字数計算と突き合わせて一致(chars 4065 / tok≒2577)。
#   ⚠️ これは**式の実装が正しいことの検算であって、係数の較正ではない**。混同しないこと。
#
# 呼び方: `measure "$text"` → `MEAS_CHARS` / `MEAS_TOKENS` に入る。
# Why not 標準入力から読む2関数にしないのか: 同じ入力を2回読む必要があり、
# パイプは1回しか読めない。呼び側が毎回一時ファイルを作る羽目になるので、
# **文字列を引数で受けて2つまとめて返す1関数**にした(呼び出し箇所は常に頭だけ = 数KB)。
TOK_ASCII_PCT=${HARNESS_TOK_ASCII_PCT:-33}
TOK_WIDE_PCT=${HARNESS_TOK_WIDE_PCT:-140}
TOKENIZER_LABEL=${HARNESS_TOKENIZER_LABEL:-Claude 4.7+}
measure() {
  local s=$1 ascii
  MEAS_CHARS=$(printf '%s' "$s" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
  ascii=$(printf '%s' "$s" | LC_ALL=C tr -cd '\000-\177' | wc -c | tr -d ' ')
  MEAS_TOKENS=$(( (ascii * TOK_ASCII_PCT + (MEAS_CHARS - ascii) * TOK_WIDE_PCT) / 100 ))
}

# 中間レコードのフィールド区切り。US(0x1f)は markdown 本文に出てこない制御文字なので
# 安全に使える(タブや `|` は本文に普通に出るので区切りには使えない)。
# 継続行を1レコードへ畳むための VT(0x0b)/ FF(0x0c)は awk 側だけで完結するので
# bash には持たない(詳細はパーサのコメント)。
US=$(printf '\037')

usage() {
  cat <<'EOF'
使い方: nd-tasks.sh [options] [<next-directions.md> ...]

next-directions.md の「## 着手順」節を読んで一覧化する(既定・読み取り専用)。
ID を指定して同じ節を書き換える操作もここに集約してある(下の「書き込み操作」)。
正典は next-directions.md のまま — tasks.yaml のような別ファイルは作らない。

走査対象:
  既定            ${CLAUDE_PROJECT_DIR:-.} 配下の docs/next-directions.md と
                  docs/*/next-directions.md の両方(単一プロダクト型 / 複数コンポーネント型)。
  --all           ${HARNESS_ROOTS:-$HOME/ghq/github.com/*/*} を展開して横断走査し、
                  リポジトリごとに見出しを出す。ND を持つリポジトリだけが出る。
  <path> ...      明示したファイルだけを走査する(自動探索を上書き。書式検証用)。

オプション(読み取り):
  --format text   既定。3区分(次にやること / 完了(証拠あり) / 整理対象)の表で出す。
  --format json   {"items":[...],"files":[...],"errors":[...]} を出す(エージェント用)。
                  items[] = id, status(open|done), summary, detail, done_criteria,
                  evidence[], file, component, repo。
                  files[] = file, repo, component, head_chars, head_tokens_est,
                  has_marker, head_injection。
  --lint          検査のみ。違反があれば非0で終了する。
  -h, --help      これ。

書き込み操作(**書式は手で書かずここに書かせる。** 対象ファイルは1本に定まる必要がある):
  --add "<概要>" --criteria "<完了条件>"
                  「着手順」節の末尾に未完了項目を1件足す。**ID は自動採番** ——
                  接頭辞はそのファイルで既に使われているもの(`H-` / `IOS-` など)を継承し、
                  番号は**ファイル全体**(着手順 + 完了記録 + カタログ部)の最大値 + 1。
                  着手順だけを見て採番すると**アーカイブ済みの ID を再利用**してしまい、
                  log.md からの参照が別物を指すようになるため、走査範囲は必ず全体。
  --done <ID> --evidence "<何を確認したか>"
                  `[ ]` を `[x]` にし、証拠行 `→ <evidence>` を項目の最後に足す。
                  **--evidence は必須**(証拠なしで [x] にする経路は用意しない)。
                  書けない移行時のみ `--evidence "(移行: 証拠なし)"` を許す。
                  既に `[x]` + 証拠行あり → 何もせず正常終了(冪等)。
                  既に `[x]` だが証拠行なし → 証拠行だけを足す(no-evidence 違反の解消)。
  --note <ID> "<本文>"
                  その項目の末尾に `> **YYYY-MM-DD 更新:** <本文>` を積層する。
                  完全に同一の行が既にあれば積まない(二重実行での重複を防ぐ)。
  --archive [--apply]
                  **証拠行を持つ `[x]` 項目**を「着手順」から `## 完了記録` へ移す。
                  **既定は dry-run**(何がどこへ移るかを出すだけ)。実際に書き換えるのは
                  --apply を付けたときだけ。証拠行を持たない `[x]` は移さない
                  (移すと証拠のないまま記録に残る。先に --done で証拠を足すこと)。
                  対象0件なら何もせず正常終了。

書き込み操作の使用例:
  nd-tasks.sh --add "doctor の pre-push 検査を hooksPath 起点に直す" \
              --criteria "dotfiles で誤検知が消え、claude-code では「無い」が残ること"
  nd-tasks.sh --done H-1 --evidence "2026-08-07 / 00b8686 / 使い捨て repo 3件で hooksPath が保たれることを実測"
  nd-tasks.sh --note H-5 "80行予算は後から足したので H-8 の棚卸し結果は未達のまま"
  nd-tasks.sh --archive                 # 何が移るかを見る
  nd-tasks.sh --archive --apply         # 実際に移す
  nd-tasks.sh --done H-1 --evidence "…" docs/harness/next-directions.md   # 対象を明示

書き込み操作の不変条件:
  - 触るのは「## 着手順」節と「## 完了記録」節だけ。現在地・カタログ部・
    `<!-- session-head-end` マーカー行には1バイトも触らない。
  - `## 完了記録` が無ければ session-head-end マーカーの直後に作る。
  - 一時ファイル + mv(atomic)。途中で落ちても正典が半分だけ書き潰されることはない。
  - fail-closed。未知の ID / 「着手順」節が無い / 接頭辞が決められない —— **何も書かずに落ちる。**
  - 書き込み後に「頭」の文字数と概算トークン数を出す(予算 8,000字 / 3,000 tok)。超えたら警告する。
  - --all / --lint / --format json とは併用できない(読み取りと書き込みを混ぜない)。

読み取る書式(この形だけを正とする):
  ## 着手順(以降の文字は任意)
  - [ ] `H-4` 概要(ID はバッククォート囲み・`[A-Za-z]+-[0-9]+`)
        補足の散文は字下げして続ける(複数行可)
        → 完了条件: 何をすれば閉じられるか
  - [x] `H-1` 概要
        → 2026-08-05 / bc3350f / 何を確認したか(**証拠行**。[x] には必須)
  節の終わりは次の `## ` か行頭 `<!-- session-head-end` か EOF。
  証拠を書けない移行時のみ `(移行: 証拠なし)` を項目か継続行に含めて免除する。

出力の3区分:
  1. 次にやること      [ ] の項目。完了条件つき
  2. 完了(証拠あり)  [x] かつ証拠行を持つもの
  3. 整理対象          [x] すべて。閉じた時点で「頭」に置く理由が消えるので、
                       カタログ部か log.md へ移す候補(移すのは /harness:tidy の仕事)

頭のサイズ(2つの機構を、それぞれの単位で見る):
  文字数 —— 切り詰め。SessionStart の stdout は **10,000 文字**超で無言に切り詰められ、
    2KB のプレビューだけが注入される(claude-code#70460 / #84021)。
    8,000字超で警告 / 10,000字超で強い警告。
  概算トークン —— 毎セッションの実費。切り詰めに余裕があっても払い続ける分。
    3,000 tok 超で警告(≒ 200k 窓の 1.5%)。
  行数は**参考値としてしか出さない**。行はどの機構も使っておらず、日本語率で 2 倍以上ブレる。
  ⚠️ 閾値を上げて警告を消すのは禁止。

検査項目(--lint はこれだけを出す。他モードでも stderr に出る):
  1. [x] なのに証拠行(→ で始まる継続行)が無い(移行免除マーカーも無い)     no-evidence
  2. 同一ファイル内での ID 重複                                              dup-id
  3. 項目行に見える(`- [`)のに書式に合わず ID が取れない  ←ドリフト検知器  malformed
  4. `<!-- session-head-end` マーカーが無い                                   no-marker
     頭注入型のフックを持つリポジトリでのみ違反。pointer 型 / ハーネス未導入では
     注入自体が無いので警告どまり(一律に鳴らすと検知器が信用されなくなる)。
  5. `## 着手順` 節が無い                                                    no-section
  6. 節はあるが `- [` 行が1本も無い(旧書式のまま未移行)                    not-migrated
  7. `- [` 行はあるのに1件も読めない(**ドリフト**。fail-closed)            empty-section

  ⚠️ 5・6(未移行)は **--all のときだけ警告へ落とす**。横断 board は毎日叩くもので、
     未移行が1つでもあると常に赤になり、**赤の意味が消えて本物のドリフト(3・7)が
     埋もれる**ため。単一リポジトリ(既定 / --lint)では従来どおり違反。

終了コード:
  0  違反なし(読み取り)/ 書き込んだ・何もしなかった・dry-run を出した(書き込み)
  1  違反あり(fail-closed の検知を含む)。頭のサイズ超過・--all の未移行は
     警告であって違反ではない
  2  使い方の誤り / 走査対象が1件も無い / 書き込み対象のファイルが1本に定まらない /
     --done に --evidence が無い
  3  書き込み操作の対象の状態が合わない —— **何も書いていない**。
     未知の ID / 「## 着手順」節が無い / 採番の接頭辞が決められない /
     「## 完了記録」を作る位置(session-head-end マーカー)が無い
EOF
}

# --- 引数 ---------------------------------------------------------------------
FORMAT="text"
MODE="list"       # list | lint
ALL=0
EXPLICIT=()       # 明示指定されたファイル(自動探索を上書きする)

# 書き込み操作。**対話プロンプトは一切出さない**(公式 agentskills.io の「スクリプトは
# 入力を全部フラグで受ける」に従う。プロンプトを出すとエージェントからは無反応に見えて固まる)。
OP=""             # "" | add | done | note | archive。同時に2つ指定したらエラー
OP_ID=""          # --done / --note の対象 ID
OP_SUMMARY=""     # --add の概要
OP_CRITERIA=""    # --add の完了条件
OP_EVIDENCE=""    # --done の証拠(何を確認したか)
OP_NOTE=""        # --note の本文
APPLY=0           # --archive を実際に適用するか(既定 dry-run)

# 操作フラグが2つ来たら落とす。--add と --done を同時に受けると「どちらが効いたのか」が
# 出力から読めなくなり、正典に対して意図しない書き込みが混ざる余地ができる。
set_op() {
  if [ -n "$OP" ] && [ "$OP" != "$1" ]; then
    echo "✗ 書き込み操作は一度に1つだけ(--$OP と --$1 が同時に指定された)。" >&2
    echo "  分けて2回実行すること。どちらが効いたのか分からない書き込みは作らない。" >&2
    exit 2
  fi
  OP="$1"
}
# フラグの値が欠けているケース(`--done` で終わっている / 次が別のフラグ)を先に潰す。
# 欠けたまま空文字で進むと「ID が空の項目を探して未知の ID で落ちる」という**分かりにくい
# 失敗**になる。次の一手が分かる形で落とすのが規約。
need_val() {
  case "${2-__MISSING__}" in
    __MISSING__) echo "✗ $1 には値が要る(例: $3)。" >&2; exit 2 ;;
    -*)          echo "✗ $1 の値がフラグに見える: $2(例: $3)。値は引用符で囲むこと。" >&2; exit 2 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-}"; shift 2 ;;
    --lint) MODE="lint"; shift ;;
    --all) ALL=1; shift ;;
    --add)
      need_val --add "${2-__MISSING__}" '--add "doctor の pre-push 検査を直す"'
      set_op add; OP_SUMMARY="$2"; shift 2 ;;
    --criteria)
      need_val --criteria "${2-__MISSING__}" '--criteria "dotfiles で誤検知が消えること"'
      OP_CRITERIA="$2"; shift 2 ;;
    --done)
      need_val --done "${2-__MISSING__}" '--done H-1'
      set_op done; OP_ID="$2"; shift 2 ;;
    --evidence)
      need_val --evidence "${2-__MISSING__}" '--evidence "使い捨て repo 3件で実測した"'
      OP_EVIDENCE="$2"; shift 2 ;;
    --note)
      # **値を2つ取る唯一のフラグ**(ID と本文)。仕様どおり `--note <ID> "<本文>"`。
      need_val --note "${2-__MISSING__}" '--note H-5 "80行予算は未達のまま"'
      need_val "--note の本文" "${3-__MISSING__}" '--note H-5 "80行予算は未達のまま"'
      set_op note; OP_ID="$2"; OP_NOTE="$3"; shift 3 ;;
    --archive) set_op archive; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
    *) EXPLICIT+=("$1"); shift ;;
  esac
done
case "$FORMAT" in
  text|json) ;;
  *) echo "✗ --format は text か json(指定: $FORMAT)" >&2; exit 2 ;;
esac

# --- 書き込み値の正規化(**構造注入の防止**) ---------------------------------
#
# ⚠️ **2026-08-08 の敵対的検証で発覚した実害。**--summary / --criteria / --evidence /
#    --note の値は awk の print へそのまま渡っており、**改行が素通し**だった。結果:
#
#    (1) エージェントが自然に渡す複数行の evidence が、字下げなしで着手順節へ書かれ、
#        **自分で書いた正典を自分の --lint が malformed と判定する**(実測)
#    (2) 値に `<!-- session-head-end -->` を混ぜると**マーカーが着手順の途中に増え、
#        以降の頭が黙って消えるのに --lint は「違反なし」を返す**(実測)。
#        検知器が完全に沈黙する —— このリポジトリが最も嫌う壊れ方。
#
#    宣言していた2つの不変条件を**改行1個で両方破れていた**:
#    「マーカー行には1バイトも触らない」「fail-closed。パースできないなら何も書かずに落ちる」。
#
# **拒否ではなく正規化を選んだ理由:** 複数行の証拠は**エージェントが自然に書きたくなる形**で、
# 拒否すると「証拠を短く削る」方向に圧力がかかる —— 証拠ゲートの目的に反する。
# 継続行の書式(6スペース字下げ)へ畳めば、意図を保ったまま構造注入が消える。
#
# **なぜ字下げで安全になるか:** パーサも session-start.sh も**行頭アンカー**で構造を見る
# (`/^- \[[ x]\] /` `/^## 着手順/` `^<!-- session-head-end`)。字下げされた行はどれにも
# マッチしないので、構造として解釈されない。**アンカーが防御になっている。**
# ⚠️ したがって**行頭アンカーを緩めると、この防御も同時に消える。**パーサを触るときは
#    ここを思い出すこと(原則7 と同じ「離れた場所の暗黙の依存」)。
sanitize_value() {
  # CR を落とし(CRLF 混入対策)、改行を「改行 + 6スペース」へ畳む。
  # 末尾の空白行は落とす —— 空の継続行は項目の切れ目に見えてパーサを惑わせる。
  printf '%s' "$1" | tr -d '\r' | awk '
    NR == 1 { out = $0; next }
    { sub(/^[[:space:]]+/, ""); if ($0 != "") out = out "\n      " $0 }
    END { print out }
  '
}
if [ -n "${OP:-}" ]; then
  OP_SUMMARY=$(sanitize_value "$OP_SUMMARY")
  OP_CRITERIA=$(sanitize_value "$OP_CRITERIA")
  OP_EVIDENCE=$(sanitize_value "$OP_EVIDENCE")
  OP_NOTE=$(sanitize_value "$OP_NOTE")
fi

# --- 書き込み操作の引数検証(実行は後段。ここでは何も読まない) -----------------
# **副作用の前に落とす。** 使い方の誤りはファイルを1バイトも読まないうちに分かるので、
# ここで exit 2 まで済ませておく(実行部は「引数は正しい」を前提に書ける)。
# 実行本体は下の「書き込み操作の実行」節 —— nds_of_repo() を使い回すために、
# その定義より後ろに置いてある。
if [ -n "$OP" ]; then
  # 読み取り系との併用は禁止。混ぜると「一覧を出すつもりが書き換わっていた」が起きうるし、
  # --all(横断)と書き込みの組は**複数リポジトリを一度に書き換える**という最も危険な形になる。
  [ "$ALL" -eq 0 ] || { echo "✗ --all は書き込み操作(--$OP)と併用できない。横断走査は読み取り専用。" >&2; exit 2; }
  [ "$MODE" != "lint" ] || { echo "✗ --lint は書き込み操作(--$OP)と併用できない。検査してから別途書くこと。" >&2; exit 2; }
  [ "$FORMAT" = "text" ] || { echo "✗ --format は書き込み操作(--$OP)と併用できない。" >&2; exit 2; }
fi

case "$OP" in
  add)
    # 完了条件の無い項目は**閉じ方が決まらない** = 永久に着手順に残る。読み側が
    # 「→ 完了条件: **(未記載)**」を出すのは既存項目の救済であって、新規に作る言い訳ではない。
    [ -n "$OP_CRITERIA" ] || {
      echo "✗ --add には --criteria が要る。" >&2
      echo "  完了条件の無い項目は「何をすれば閉じられるか」が決まらず、着手順に残り続ける。" >&2
      echo "  例: --add \"doctor の pre-push 検査を直す\" --criteria \"dotfiles で誤検知が消えること\"" >&2
      exit 2
    } ;;
  done)
    # **ここが証拠必須の入口。** --lint は事後に叱るだけだが、こちらは「証拠なしで [x] に
    # する経路をそもそも作らない」。Anthropic の long-running harness 記事にある
    # 「後続のエージェントが進捗を見て勝手に完了宣言する」罠は、✅ が証拠なしで積み上がるほど強く出る。
    [ -n "$OP_EVIDENCE" ] || {
      echo "✗ --done には --evidence が必要です。" >&2
      echo "  書くのは「何をしたか」ではなく **何を確認したか**(検証コマンドとその結果)。" >&2
      echo "  例: --done $OP_ID --evidence \"2026-08-07 / 00b8686 / 使い捨て repo 3件で hooksPath が保たれることを実測\"" >&2
      echo "  証拠を書けない移行時のみ --evidence \"(移行: 証拠なし)\" を許す。" >&2
      exit 2
    } ;;
esac

# 操作に属さないフラグが単独で来たら落とす。黙って無視すると「--evidence を付けたのに
# 証拠が入らなかった」に気づけない(サイレントな取りこぼしはこの repo が最も嫌う壊れ方)。
[ -z "$OP_CRITERIA" ] || [ "$OP" = "add" ] || { echo "✗ --criteria は --add と一緒に使う(指定: --${OP:-なし})。" >&2; exit 2; }
[ -z "$OP_EVIDENCE" ] || [ "$OP" = "done" ] || { echo "✗ --evidence は --done と一緒に使う(指定: --${OP:-なし})。" >&2; exit 2; }
[ "$APPLY" -eq 0 ] || [ "$OP" = "archive" ] || { echo "✗ --apply は --archive と一緒に使う(dry-run を実行に変えるフラグ)。" >&2; exit 2; }

# ID の形は読み側のパーサと**同じ正規表現**で縛る。ここを緩めると、書けるのに読めない
# ID(例: 全角ハイフン)を正典へ入れてしまい、一覧から静かに消える。
# ボツ案: `case` のパターンだけで見る。「英字+ハイフン+数字」の順序制約が表現できず、
# `H-1-2` のような形を通してしまう。expr もボツ —— 値が `-` で始まると expr のオプションと
# 解釈されて誤動作する(`--` が使えない実装がある)。grep -E が一番素直で、依存も既にある。
if [ -n "$OP_ID" ] && ! printf '%s' "$OP_ID" | grep -qE '^[A-Za-z]+-[0-9]+$'; then
  echo "✗ ID の形が不正: $OP_ID" >&2
  echo "  ID は「英字 + ハイフン + 数字」(例: H-1 / IOS-10)。バッククォートは付けずに渡すこと。" >&2
  exit 2
fi

# --- パーサ(awk) -------------------------------------------------------------
# 1ファイルにつき1回呼ぶ。repo / comp / file はここでは判らないので bash から渡す
# (awk 側で解決すると --all のときにパスの切り出しロジックが二重になる)。
#
# レコード形式(US 区切り):
#   I <repo> <comp> <file> <id> <status> <summary> <detail> <done> <evidence>
#   E <repo> <comp> <file> <code> <line> <sev> <message>       sev: V=違反 / W=警告
#
# detail / done / evidence の中は2段の区切りを持つ:
#   VT(0x0b) = ブロックの区切り(別の「→」行 / 別の段落)
#   FF(0x0c) = 同じブロックの折り返し(1行に収まらなかった続き)
# 折り返しを別ブロックにすると「完了条件が2件ある」「証拠が2本ある」と誤って数えてしまう。
# 実物の正典は 90 桁前後で折り返して書かれているので、この区別は必須。
#
# ⚠️ プログラムは一時ファイルへ書いて `awk -f` で渡す。`PARSER=$(cat <<'AWK' ...)` の形に
#    してはいけない —— **bash 3.2(macOS 標準の /bin/bash)は `$( )` の中では引用符付き
#    ヒアドキュメントの中身まで走査し、本文中のバッククォートをコマンド置換の開始と
#    誤認して構文エラーになる**(実際に踏んだ。bash 5 では通るので気づきにくい)。
#    このパーサは ID をバッククォート囲みで扱う都合上、本文にバッククォートが必ず出る。
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nd-tasks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PARSER="$tmp/parser.awk"
cat > "$PARSER" <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# 行頭の空白を落とす。全角スペースは日本語の字下げで実際に混ざるので一緒に落とす。
# ⚠️ 多バイト文字を [ ] の中に書かないこと — このリポジトリの awk はバイト単位で
#    ブラケットを解釈するので、全角スペースが「3バイトの選択肢」に分解されて誤爆する。
#    量化子も (　)+ のようにグループへ掛ける(　+ だと最終バイトにだけ掛かる)。
function ltrim(s) { sub(/^[ \t]+/, "", s); sub(/^(　)+/, "", s); sub(/^[ \t]+/, "", s); return s }

function emit_err(code, ln, sev, msg) {
  print "E" US repo US comp US file US code US ln US sev US msg
}

function reset() { c_id=""; c_st=""; c_sum=""; c_det=""; c_done=""; c_evi=""; c_ex=0; c_ln=0
                   c_last=""; c_aind=0 }

function flush() {
  if (c_id == "") { reset(); return }
  # [x] の証拠行は harness の中心的な運用契約 —— 「何をしたか」ではなく「何を確認したか」を
  # 残させるためのもの。Anthropic の long-running harness 記事にある「後続のエージェントが
  # 進捗を見て勝手に完了宣言する」罠は、✅ が証拠なしで積み上がるほど強く出る。
  if (c_st == "x" && c_evi == "" && c_ex == 0)
    emit_err("no-evidence", c_ln, "V", "完了 [x] の `" c_id "` に証拠行が無い(→ で始まる継続行に「何を確認したか」を書く。移行時のみ (移行: 証拠なし) で免除)")
  print "I" US repo US comp US file US c_id US c_st US c_sum US c_det US c_done US c_evi
  nitem++
  reset()
}

BEGIN {
  US = sprintf("%c", 31); VT = sprintf("%c", 11); FF = sprintf("%c", 12)
  insec = 0; nsec = 0; nitem = 0
  reset()
}

# --- 節の境界 ---------------------------------------------------------------
# 見出しの残りは任意。「## 着手順(次にやること)」のような表記揺れを許す
# (教える書式は厳密に、計測は寛容に)。
/^## 着手順/                     { flush(); insec = 1; nsec++; next }
insec && /^## /                  { flush(); insec = 0; next }
insec && /^<!-- session-head-end/ { flush(); insec = 0; next }
!insec                           { next }

# --- ここから下は「着手順」節の中 -------------------------------------------
# 空行は継続を切らない(補足が段落に分かれて書かれることがある)。
/^[ \t]*$/ { next }

# 項目行。`- [` で始まるのに書式に合わない行は**違反**にする —— これが書式ドリフトの
# 検知器。ここを黙って読み飛ばすと、書式が変わった日に一覧が静かに空になる。
# 副作用として markdown リンク始まりの `- [text](url)` も違反になるが、着手順節に
# それを書く用途は無いので許容する(厳密側に倒す)。
/^- \[/ {
  flush()
  # 節の中に「項目行のつもりの行」が1本でもあったか。0件だったときの原因が
  # 「まだ移行していない(散文のまま)」なのか「読めなくなった(ドリフト)」なのかは、
  # これが在るか無いかで機械的に分かれる。END で使う。
  nbracket++
  if ($0 !~ /^- \[[ x]\] `[A-Za-z]+-[0-9]+` /) {
    emit_err("malformed", NR, "V", "項目行の書式に合わない: " substr($0, 1, 80))
    next
  }
  c_st = substr($0, 4, 1)          # "- [x] " の 4 文字目が状態
  r = substr($0, 7)                # 開きバッククォートから後ろ
  p = index(substr(r, 2), "`")     # 閉じバッククォートの位置(r の 2 文字目から数えて)
  c_id = substr(r, 2, p - 1)
  c_sum = trim(substr(r, p + 2))
  c_ln = NR
  if (c_id in seen)
    emit_err("dup-id", NR, "V", "ID が重複: `" c_id "`(" seen[c_id] " 行目にもある)")
  else
    seen[c_id] = NR
  if (c_sum ~ /移行(:|：)( |　)*証拠なし/) c_ex = 1
  next
}

# 継続行。行頭が空白の行は、直前の項目に属する。
/^[ \t]/ {
  if (c_id == "") next            # 項目に属さない字下げ行(節の導入文など)は無視
  match($0, /^[ \t]*/); ind = RLENGTH
  t = ltrim($0)
  if (t ~ /移行(:|：)( |　)*証拠なし/) c_ex = 1
  if (t ~ /^→/) {
    sub(/^→/, "", t); t = ltrim(t)
    c_aind = ind                  # 折り返し判定の基準になる字下げ幅
    # 「→ 完了条件:」は**これから何をすれば閉じられるか**、それ以外の「→」は
    # **何を確認したか(証拠)**。完了項目が着手時の完了条件行を残していても、
    # それを証拠として数えてはいけないので、ここで明確に分ける。
    if (t ~ /^完了条件(:|：)/) {
      sub(/^完了条件(:|：)/, "", t); t = trim(t)
      c_done = (c_done == "" ? t : c_done VT t); c_last = "d"
    } else {
      c_evi = (c_evi == "" ? t : c_evi VT t); c_last = "e"
    }
  } else if (c_last != "" && ind > c_aind) {
    # 直前の「→」行より深く字下げされた行は、その行の**折り返し**とみなす。
    # 別ブロック(VT)ではなく FF で繋ぐ —— ここを間違えると証拠が2本あることになる。
    if (c_last == "d") c_done = c_done FF t; else c_evi = c_evi FF t
  } else {
    c_det = (c_det == "" ? t : c_det VT t); c_last = ""
  }
  next
}

# 上のどれにも当たらない行(節内の字下げなし散文・### 小見出しなど)は
# 項目の継続を打ち切るだけで、内容は無視する。
{ flush() }

END {
  flush()
  # 0件の理由を2つに割る。**この区別が検知の要**:
  #   未移行(no-section / not-migrated)= まだチェックリストにしていない。既知の状態で異常ではない
  #   ドリフト(empty-section)          = 項目行のつもりの行は在るのに1件も読めない。
  #                                        **前は読めていたものが読めなくなった**side なので必ず赤にする
  # 同じ赤にすると、未移行リポジトリの数に本物のドリフトが埋もれる(--all で顕著)。
  if (nsec == 0)
    emit_err("no-section", 0, "V", "`## 着手順` 節が無い(旧書式のまま — チェックリスト形式への移行が要る)")
  else if (nitem == 0 && nbracket == 0)
    emit_err("not-migrated", 0, "V", "`## 着手順` 節はあるが、チェックリストの項目行(`- [ ]`)が1本も無い —— 旧書式(番号付き散文)のまま未移行。**タスクが無いという意味ではない**。移行すると `/harness:status` で読めるようになる")
  else if (nitem == 0)
    emit_err("empty-section", 0, "V", "`## 着手順` 節に項目行らしき行(`- [`)は " nbracket " 本あるのに1件も読めない —— **書式が変わったかパーサの正規表現が腐った可能性**。「- [ ] `ID-1` 概要」の形(ID はバッククォート囲み)になっているか確認すること。**タスクが無いと解釈してはいけない**")
}
AWK

# --- 収集 ---------------------------------------------------------------------
RECS="$tmp/records"
: > "$RECS"

# US 区切りの1レコードを書く。IFS の先頭文字で "$*" が連結される性質を使う。
emit_rec() { local IFS="$US"; printf '%s\n' "$*" >> "$RECS"; }

# そのリポジトリのフックが「頭注入型」か(= session-head-end を読むか)。
#
# マーカー欠落の意味は、フックの配線で3通りに分かれる:
#   (a) 頭注入型のフックがある + マーカー無し → **注入が fail-closed で停止している**(違反)
#   (b) pointer 型フック(この repo)         → そもそも頭を注入しないので停止ではない(警告)
#   (c) フックが無い(ハーネス未導入)         → 同上(警告。直すのは /harness:doctor)
# 一律に違反にすると (b)(c) で毎回鳴り、検知器が信用されなくなる —— このリポジトリは
# 「検知器が黙って死ぬ」と同じくらい「鳴りすぎて無視される」を嫌う。実測では
# tdr-concierge は (c) だった(フック自体が無い。「停止中」ではなく未導入)。
head_injection_mode() {
  local root=$1
  grep -rqs 'session-head-end' "$root/.claude/hooks" 2>/dev/null && echo 1 || echo 0
}

# ファイルパスから (リポジトリルート, コンポーネント名) を決める。
#   <root>/docs/next-directions.md        → comp="" (単一プロダクト型)
#   <root>/docs/<comp>/next-directions.md → comp=<comp>
root_of() {
  local d; d=$(cd "$(dirname "$1")" && pwd)
  case "$d" in
    */docs)   printf '%s\n' "${d%/docs}" ;;
    */docs/*) printf '%s\n' "${d%/docs/*}" ;;
    *)        printf '%s\n' "$d" ;;   # docs 配下でない明示指定(書式検証用の一時ファイルなど)
  esac
}
comp_of() {
  local d; d=$(cd "$(dirname "$1")" && pwd)
  case "$d" in
    */docs) printf '%s\n' "" ;;
    *)      basename "$d" ;;
  esac
}

# 1ファイルを走査して F/I/E レコードを積む。
scan_file() {
  local f=$1 root comp repo marker head_chars head_tokens has_marker inject
  root=$(root_of "$f"); comp=$(comp_of "$f"); repo=$(basename "$root")
  inject=$(head_injection_mode "$root")

  # 頭(SessionStart が注入する範囲)の文字数とトークン数。フックは marker 行の**手前まで**を
  # 出すので、計測もそこに揃える(marker 行自身と、フックが足す見出し行は含めない)。
  # 行頭アンカーで探すのはフックと同じ理由 —— 散文中で session-head-end に言及しただけで
  # 頭が切れる誤爆を防ぐ。
  marker=$(grep -n -m1 '^<!-- session-head-end' "$f" | cut -d: -f1 || true)
  if [ -n "$marker" ]; then
    has_marker=1
    measure "$(sed -n "1,$((marker - 1))p" "$f")"
  else
    has_marker=0
    measure "$(cat "$f")"   # 頭が定義できない。参考値として全文サイズを出す
  fi
  head_chars=$MEAS_CHARS; head_tokens=$MEAS_TOKENS
  emit_rec F "$repo" "$comp" "$f" "$head_chars" "$has_marker" "$inject" "$root" "$head_tokens"

  if [ "$has_marker" -eq 0 ]; then
    if [ "$inject" -eq 1 ]; then
      emit_rec E "$repo" "$comp" "$f" no-marker 0 V \
        "session-head-end マーカーが無い —— このリポジトリのフックは頭注入型なので、**注入が fail-closed で停止している**(誰も気づかないまま止まる)。現在地・着手順の直後に行頭から <!-- session-head-end --> を復元すること"
    else
      emit_rec E "$repo" "$comp" "$f" no-marker 0 W \
        "session-head-end マーカーが無い(このリポジトリに頭注入型のフックが無い = pointer 型かハーネス未導入。注入が止まっているわけではないが、頭/カタログの境界が無いので読み手は全文を読むことになる。導入は /harness:doctor)"
    fi
  else
    # #70460 / #84021: SessionStart の stdout は **10,000 文字**超で無言に切り詰められ、
    # 2KB のプレビューだけが注入される。バイトでも行でもなく**文字**で効く制限。
    if [ "$head_chars" -gt "$HEAD_HARD_CHARS" ]; then
      emit_rec E "$repo" "$comp" "$f" head-truncated 0 W \
        "頭が ${head_chars}字(> ${HEAD_HARD_CHARS}字)—— SessionStart の stdout は 10,000字超で**無言に切り詰められ 2KB のプレビューだけが注入される**(anthropics/claude-code#70460・#84021)。いま実際に切れている。棚卸しして頭を縮めること"
    elif [ "$head_chars" -gt "$HEAD_WARN_CHARS" ]; then
      emit_rec E "$repo" "$comp" "$f" head-large 0 W \
        "頭が ${head_chars}字(目安 ${HEAD_WARN_CHARS}字)—— 10,000字を超えると SessionStart の stdout が無言に切り詰められる(#70460)。余裕が ${HEAD_HARD_CHARS}字まで"
    fi
    # トークンは切り詰めとは別の機構(毎セッションの実費)。切り詰めに余裕があっても
    # ここが太れば全セッションで払い続けるので、独立した予算として別に鳴らす。
    if [ "$head_tokens" -gt "$HEAD_WARN_TOKENS" ]; then
      emit_rec E "$repo" "$comp" "$f" head-costly 0 W \
        "頭が ≒${head_tokens} tok(予算 ${HEAD_WARN_TOKENS} tok)—— 切り詰めには余裕があるが、**毎セッション注入されるので全セッションのコストになる**。棚卸しか --archive で降ろすこと"
    fi
  fi

  awk -v repo="$repo" -v comp="$comp" -v file="$f" -f "$PARSER" "$f" >> "$RECS"
}

# 1リポジトリ配下の正典を列挙する。単一プロダクト型と複数コンポーネント型の両対応
# (tidy.sh の探索と同じ形。片方だけ見ると、この repo のような marketplace 型を取りこぼす)。
nds_of_repo() {
  local root=$1 f
  [ -f "$root/docs/next-directions.md" ] && printf '%s\n' "$root/docs/next-directions.md"
  for f in "$root"/docs/*/next-directions.md; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# =============================================================================
# 書き込み操作の実行(--add / --done / --note / --archive)
# =============================================================================
# 引数の検証は上の「書き込み操作の引数検証」で済ませてある。ここは「引数は正しい」前提で、
# 対象ファイルを1本に決め、エディタ(awk)に新しい全文を作らせ、atomic に置き換えるだけ。
#
# **読み取り経路には一切入らない。** 下の収集ループ(scan_file / RECS)まで落ちてこない
# ように、この if の中で必ず exit する —— 書き込みの後に一覧を出すと、出力が
# 「何をしたか」と「いま何があるか」で混ざって、どちらの話か読めなくなる。
if [ -n "$OP" ]; then
  # --- 対象ファイルを1本に決める(fail-closed) -------------------------------
  # **複数候補があるときは推測しない。** この repo のように docs/harness/ と docs/ios-skills/
  # の2本を持つ構成で「たぶん harness の方だろう」と決め打つと、**別のコンポーネントの正典を
  # 書き換える**という取り返しのつかない事故になる。読み取り(--all)と違い、書き込みでは
  # 曖昧さを許さない。
  TARGET=""
  if [ ${#EXPLICIT[@]} -gt 1 ]; then
    echo "✗ 書き込み操作の対象は1ファイルだけ(${#EXPLICIT[@]} 件が指定された)。" >&2
    echo "  1本ずつ実行すること。" >&2
    exit 2
  elif [ ${#EXPLICIT[@]} -eq 1 ]; then
    TARGET="${EXPLICIT[0]}"
    [ -f "$TARGET" ] || { echo "✗ ファイルが無い: $TARGET" >&2; exit 2; }
  else
    wbase=$(cd "${CLAUDE_PROJECT_DIR:-.}" && pwd)
    ncand=0
    # 1行1ファイルで受ける($(...) を直接 for に食わせると空白入りパスが割れる。
    # 割れたときの症状が「静かに1件も見つからない」なので、読み取り側と同じ形にする)。
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      ncand=$((ncand + 1)); TARGET="$f"; cand_list="${cand_list:-}  $f"$'\n'
    done <<EOF
$(nds_of_repo "$wbase")
EOF
    if [ "$ncand" -eq 0 ]; then
      echo "✗ $wbase に docs/next-directions.md も docs/*/next-directions.md も無い。" >&2
      echo "  ハーネス未導入なら /harness:doctor で導入できる。" >&2
      exit 2
    elif [ "$ncand" -gt 1 ]; then
      echo "✗ next-directions.md が $ncand 本ある —— どれに書くかを推測しない(別コンポーネントの" >&2
      echo "  正典を書き換える事故を防ぐため)。パスを引数で明示すること:" >&2
      printf '%s' "$cand_list" >&2
      exit 2
    fi
  fi
  TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

  # --- エディタ(awk) ---------------------------------------------------------
  # ⚠️ 読み取り側のパーサと同じ理由で、プログラムは一時ファイルへ書いて `awk -f` で渡す。
  #    `PROG=$(cat <<'AWK' …)` の形にすると、**bash 3.2(macOS 標準)が $( ) の中で
  #    引用符付きヒアドキュメントの中身まで走査し、本文のバッククォートをコマンド置換の
  #    開始と誤認して構文エラーになる**。ID をバッククォート囲みで扱う以上、必ず踏む。
  #
  # 入出力の契約:
  #   stdout            書き換えた後の**全文**(呼び出し側が atomic に置き換える)
  #   report ファイル   "<SEV>\t<メッセージ>" の行。SEV は E=違反 / W=警告 / I=情報 /
  #                     M=移動の内訳 / N=採番した ID / C=件数
  #   終了コード        0=変更あり(stdout が有効) / 10=変更不要(冪等) / 3=状態エラー
  #
  # **利用者が渡す文字列は -v ではなく環境変数(ENVIRON)で受ける。** awk の -v は値の中の
  # バックスラッシュをエスケープシーケンスとして解釈するので、`C:\path` や `\n` を含む
  # 概要・証拠が**静かに壊れる**。ENVIRON にはその変換が無い。
  EDITOR="$tmp/edit.awk"
  cat > "$EDITOR" <<'AWK'
# --- 小道具 -----------------------------------------------------------------
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# 行頭の空白を落とす。全角スペースは日本語の字下げで実際に混ざるので一緒に落とす。
# ⚠️ 多バイト文字を [ ] の中に書かないこと — この awk はブラケット式をバイト単位で
#    解釈するので、全角スペースが「3バイトの選択肢」に分解されて誤爆する(読み側と同じ注意)。
function ltrim(s) { sub(/^[ \t]+/, "", s); sub(/^(　)+/, "", s); sub(/^[ \t]+/, "", s); return s }
function ind_of(s) { match(s, /^[ \t]*/); return RLENGTH }
function blank(s) { return (s ~ /^[ \t]*$/) }
function sp(k,   s) { s = ""; while (length(s) < k) s = s " "; return s }
function say(sev, msg) { print sev "\t" msg >> report }
# **何も書かずに落ちる**のがこの関数の全て。呼び出し側は exit 3 を見て stdout を捨てる。
function die(msg) { say("E", msg); exit 3 }
# 「i 行目の直後に足す行」を積む。削除(del)と併せて、出力は emit() が1回で組み立てる ——
# 行番号を動かしながら書き換えると、後続の位置がずれて**別の項目を壊す**。
function add_ins(at, text) { insn[at]++; ins[at, insn[at]] = text }

# --- 節の特定 ---------------------------------------------------------------
# 書き換えてよいのは「着手順」と「完了記録」だけ。現在地・カタログ部・マーカー行の
# 位置はここで確定させ、以降その外側の行番号には触れない。
function locate_sections(   i) {
  ss = 0
  for (i = 1; i <= n; i++) if (L[i] ~ /^## 着手順/) { ss = i; break }
  if (ss == 0)
    die("`## 着手順` 節が無い —— 書き込む場所が決められないので**何も書いていない**。旧書式のままなら `## 着手順(次にやること)` 見出しを作り、`- [ ] `ID-1` 概要` 形式へ移行すること(/harness:doctor が配る雛形が正)。")
  # 節の終わりは読み側のパーサと同じ規則(次の `## ` か行頭 `<!-- session-head-end` か EOF)。
  # ここが読み書きでずれると、書いた行が一覧に出ない/出ない行を書き換える、が起きる。
  se = n + 1
  for (i = ss + 1; i <= n; i++)
    if (L[i] ~ /^## / || L[i] ~ /^<!-- session-head-end/) { se = i; break }
  ds = 0
  for (i = 1; i <= n; i++) if (L[i] ~ /^## 完了記録/) { ds = i; break }
  if (ds > 0) {
    de = n + 1
    for (i = ds + 1; i <= n; i++) if (L[i] ~ /^## /) { de = i; break }
  }
  mk = 0
  for (i = 1; i <= n; i++) if (L[i] ~ /^<!-- session-head-end/) { mk = i; break }
}

# --- 項目の切り出し ---------------------------------------------------------
# 項目行の正規表現は**読み側のパーサと1文字も違えない**。ここが緩いと「書けるのに読めない」
# 項目を正典へ入れてしまい、一覧から静かに消える(この repo が最も嫌う壊れ方)。
function collect_items(   i, j, k, r, p, t, last, mind, aind, nstart) {
  ni = 0
  for (i = ss + 1; i < se; i++) {
    if (L[i] !~ /^- \[[ x]\] `[A-Za-z]+-[0-9]+` /) continue
    ni++
    istart[ni] = i
    istat[ni] = substr(L[i], 4, 1)      # "- [x] " の 4 文字目が状態
    r = substr(L[i], 7)
    p = index(substr(r, 2), "`")
    iid[ni] = substr(r, 2, p - 1)
    isum[ni] = trim(substr(r, p + 2))
  }
  for (k = 1; k <= ni; k++) {
    # 項目の範囲 = 次の「字下げ無しの非空行」の手前まで。空行は継続を切らない
    # (補足が段落に分かれて書かれることがある。読み側のパーサと同じ規則)。
    last = istart[k]
    for (j = istart[k] + 1; j < se; j++) {
      if (blank(L[j])) continue
      if (L[j] !~ /^[ \t]/) break
      last = j
    }
    iend[k] = last

    mind = 999; aind = 999; ihas_evi[k] = 0; ifirst_evi[k] = 0
    for (j = istart[k] + 1; j <= iend[k]; j++) {
      if (blank(L[j])) continue
      if (ind_of(L[j]) < mind) mind = ind_of(L[j])
      t = ltrim(L[j])
      if (t !~ /^→/) continue
      if (ind_of(L[j]) < aind) aind = ind_of(L[j])
      # 「→ 完了条件:」は**これから何をすれば閉じられるか**、それ以外の「→」は
      # **何を確認したか(証拠)**。--archive の可否はこの区別だけで決まるので、
      # 読み側と同じ判定を使う(完了条件行を証拠として数えたら不変条件が崩れる)。
      sub(/^→/, "", t); t = ltrim(t)
      if (t ~ /^完了条件(:|：)/) continue
      ihas_evi[k] = 1
      if (ifirst_evi[k] == 0) ifirst_evi[k] = j
    }
    imind[k] = (mind == 999 ? 0 : mind)
    iaind[k] = (aind == 999 ? 0 : aind)

    # 末尾に積まれた「> …」引用ブロック(= --note が書いた更新行)の開始位置。
    # **証拠行はその手前に入れる。** 引用ブロックは段落を切るので、その後ろに
    # 6 桁字下げの「→」行を置くと markdown 側でインデントコードブロックとして描画される
    # (list item の内容カラムが 2 桁なので、6 桁は相対 4 桁 = コードブロック)。
    nstart = 0
    for (j = iend[k]; j > istart[k]; j--) {
      if (blank(L[j])) continue
      if (ltrim(L[j]) ~ /^>/) nstart = j; else break
    }
    if (nstart == 0) ipara[k] = iend[k]
    else {
      p = istart[k]
      for (j = istart[k] + 1; j < nstart; j++) if (!blank(L[j])) p = j
      ipara[k] = p
    }
  }
}

function find_item(qid,   k) {
  for (k = 1; k <= ni; k++) if (iid[k] == qid) return k
  return 0
}

# 未知の ID。「そんな ID は無い」で終わらせず、**次の一手**を出す ——
# 完了記録に在るなら打ち間違いではないし、在る ID を並べれば探す手間が消える。
function unknown_id(   i, k, list) {
  for (i = 1; i <= n; i++)
    if (substr(L[i], 1, 4) == "- ~~" && index(L[i], "`" id "`") == 5)
      die("`" id "` は「着手順」に無い —— 「完了記録」に在る(既に --archive 済み)。**何も書いていない。** 閉じ直す必要は無い。")
  list = ""
  for (k = 1; k <= ni; k++) list = list (list == "" ? "" : ", ") "`" iid[k] "`"
  die("`" id "` という ID の項目が「着手順」に無い。**何も書いていない。** いま在るのは: " (list == "" ? "(0件)" : list))
}

# --- 採番 -------------------------------------------------------------------
# **ファイル全体**(着手順 + 完了記録 + カタログ部 + 散文中の参照)を走査して最大値を採る。
# 着手順だけを見ると、--archive で完了記録へ降ろした ID を再利用してしまい、
# log.md やコミットメッセージからの参照(「`H-1` の件」)が**別物を指す**ようになる。
# 削除された ID を埋め直す「詰め直し」もしない —— 欠番は安全だが再利用は嘘を作る。
function scan_all_ids(   i, t, tok, q, pfx, num) {
  for (i = 1; i <= n; i++) {
    t = L[i]
    while (match(t, /`[A-Za-z]+-[0-9]+`/)) {
      tok = substr(t, RSTART + 1, RLENGTH - 2)
      q = length(tok); while (substr(tok, q, 1) != "-") q--
      pfx = substr(tok, 1, q - 1); num = substr(tok, q + 1) + 0
      if (num > maxnum[pfx]) maxnum[pfx] = num
      t = substr(t, RSTART + RLENGTH)
    }
  }
}

# 接頭辞は**項目位置に現れたもの**からしか採らない(着手順の `- [ ] `X-1`` と
# 完了記録の `- ~~`X-1``)。散文やコードブロックには `iteration-4` のような
# 「ID に見えるだけの文字列」が実在するので、そこから接頭辞を拾うと別系列を作ってしまう。
# 複数あれば**最も多く使われているもの**を採る(タイは先に出た方)。
function dominant_prefix(   i, s, tok, q, p, pn, best, bestc) {
  pn = 0; best = ""; bestc = 0
  for (i = 1; i <= n; i++) {
    s = L[i]
    if (s !~ /^- \[[ x]\] `[A-Za-z]+-[0-9]+`/ && s !~ /^- ~~`[A-Za-z]+-[0-9]+`/) continue
    match(s, /`[A-Za-z]+-[0-9]+`/)
    tok = substr(s, RSTART + 1, RLENGTH - 2)
    q = length(tok); while (substr(tok, q, 1) != "-") q--
    p = substr(tok, 1, q - 1)
    if (!(p in pcount)) porder[++pn] = p
    pcount[p]++
  }
  for (i = 1; i <= pn; i++) if (pcount[porder[i]] > bestc) { bestc = pcount[porder[i]]; best = porder[i] }
  return best
}

# --- 操作: --add ------------------------------------------------------------
function do_add(   pfx, nid, at, i) {
  pfx = dominant_prefix()
  if (pfx == "")
    die("採番の接頭辞が決められない —— 「着手順」にも「完了記録」にも `H-1` 形式の項目が1本も無い。**何も書いていない。** 最初の1件だけは手で書いて接頭辞を決めること(プロジェクトの略号にする。例: caldav なら `CD-1`)。")
  nid = pfx "-" (maxnum[pfx] + 1)
  # 挿入位置 = 節の中の最後の非空行の直後。項目があればその末尾、無ければ導入散文の直後。
  # 「末尾へ足す」のは着手順が**優先順ではなく追加順**だから(順序を変えたいときは人が動かす)。
  at = 0
  for (i = ss + 1; i < se; i++) if (!blank(L[i])) at = i
  if (at == 0) { at = ss; add_ins(at, "") }
  else if (L[at] !~ /^- / && L[at] !~ /^[ \t]/) add_ins(at, "")   # 直上が散文なら空行を1本
  add_ins(at, "- [ ] `" nid "` " ENVIRON["ND_SUMMARY"])
  add_ins(at, sp(6) "→ 完了条件: " ENVIRON["ND_CRITERIA"])
  say("N", nid)
  say("I", "採番 `" nid "` = 接頭辞 " pfx " の最大値 " maxnum[pfx] " + 1(**ファイル全体**を走査した。着手順だけを見るとアーカイブ済み ID を再利用する)")
  changed = 1
}

# --- 操作: --done -----------------------------------------------------------
function do_done(   k, ind) {
  k = find_item(id)
  if (k == 0) unknown_id()
  # 冪等。2回目は**エラーにしない** —— 再実行が安全でないスクリプトは、失敗したときに
  # 「もう一度叩いてよいか」を人が判断しなければならず、そこで手作業に戻る。
  if (istat[k] == "x" && ihas_evi[k]) {
    say("I", "`" id "` は既に完了(`[x]` + 証拠行あり)。何もしていない。")
    changed = 0
    return
  }
  # 証拠行の字下げは既存の「→」行に揃える。無ければ継続行の最小字下げ、それも無ければ 6
  # (`- [x] ` の幅。読み側は字下げ幅を問わないが、揃っていないと人が読めない)。
  ind = (iaind[k] > 0 ? iaind[k] : (imind[k] > 0 ? imind[k] : 6))
  add_ins(ipara[k], sp(ind) "→ " ENVIRON["ND_EVIDENCE"])
  if (istat[k] == "x")
    say("W", "`" id "` は既に `[x]` だったが証拠行が無かった —— 証拠行だけを足した(--lint の no-evidence 違反はこれで解消する)。")
  else {
    L[istart[k]] = substr(L[istart[k]], 1, 3) "x" substr(L[istart[k]], 5)
    say("I", "`" id "` を `[x]` にし、証拠行を項目の最後に足した。")
  }
  changed = 1
}

# --- 操作: --note -----------------------------------------------------------
function do_note(   k, ln, j, nind) {
  k = find_item(id)
  if (k == 0) unknown_id()
  # 字下げは 2 桁。list item の内容カラムが 2 桁なので、そこに `>` を置くと
  # **項目の中の引用ブロック**として描画される。6 桁にすると相対 4 桁 =
  # インデントコードブロック扱いになり、`> **… 更新:**` がそのまま等幅で出てしまう。
  # かつ 2 桁は直前の「→」行の字下げ(通常 6)以下なので、読み側のパーサに
  # **証拠行の折り返し**と誤読されない(折り返し判定は「直前の → 行より深い」)。
  # 「→」行が 1 桁という異常な字下げのときだけ、それに合わせて更に浅くする。
  nind = 2
  if (iaind[k] > 0 && iaind[k] < 2) nind = iaind[k]
  ln = sp(nind) "> **" today " 更新:** " ENVIRON["ND_NOTE"]
  # 二重実行での重複を防ぐ。積層(append)が本来の意味なので**内容が違えば何本でも積む**が、
  # 完全一致は「同じコマンドをもう一度叩いた」以外にありえないので黙って落とす。
  for (j = istart[k]; j <= iend[k]; j++) if (L[j] == ln) {
    say("I", "同じ内容の更新行が既にある(" j " 行目)。積まなかった。")
    changed = 0
    return
  }
  add_ins(iend[k], ln)
  say("I", "`" id "` の末尾に `> **" today " 更新:**` を積んだ。")
  changed = 1
}

# --- 操作: --archive --------------------------------------------------------
# ✅ の日付は証拠行の先頭にある YYYY-MM-DD を使う。無ければ今日。
# 「今日」を無条件に使うと、3日前に閉じた項目が今日閉じたことになって記録が嘘になる。
function evi_date(k,   t) {
  if (ifirst_evi[k] == 0) return today
  t = ltrim(L[ifirst_evi[k]])
  sub(/^→/, "", t); t = ltrim(t)
  if (match(t, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) return substr(t, 1, 10)
  return today
}

function move_item(k, dst,   i, mind, sh, ln, dt, s) {
  dt = evi_date(k)
  # 完了記録の書式は既存の実物に合わせる: `- ~~`ID` 概要~~ ✅ YYYY-MM-DD`。
  # チェックボックス形式のまま降ろすのはボツ —— 完了記録は「## 着手順」の外なので
  # 読み側のパーサが見ない。`[x]` のまま置くと、書式だけ機械可読で誰も読まない行になる。
  s = "`" iid[k] "` " isum[k]
  # ⚠️ **手書き様式との衝突を避ける。** 移行前の実物には
  # `- [x] `IOS-3` ~~概要~~ ✅(2026-08-04)` のように、打ち消し線と ✅ を**項目行の中に
  # 手で書いた**ものが在る(docs/ios-skills/next-directions.md で実際に踏んだ)。
  # そこへ機械的に `~~ … ~~` を被せると打ち消し線が入れ子になって markdown が壊れ、
  # ✅ も2つ並ぶ。既にあるなら足さない —— 人が書いた形の方を正とする。
  # ボツ案: 既存の `~~` と `✅…` を剥がして正規化する。項目の文言そのものを削ることになり、
  # 「移すだけ」という約束を超える(どこまでが装飾でどこからが本文かは機械には判らない)。
  if (index(s, "~~") == 0) s = "~~" s "~~"
  if (index(s, "✅") == 0) s = s " ✅ " dt
  add_ins(dst, "- " s)
  # 継続行は**相対構造を保ったまま**平行移動する(最小字下げが 2 になるように)。
  # 一律に 2 桁へ潰すのはボツ: 「→」行とその折り返しの深さの差が消え、
  # 読み側の折り返し判定と食い違う形になる(完了記録は読まれないが、
  # 人が着手順へ戻したくなったときに壊れた形が残るのは避ける)。
  mind = 999
  for (i = istart[k] + 1; i <= iend[k]; i++)
    if (!blank(L[i]) && ind_of(L[i]) < mind) mind = ind_of(L[i])
  sh = (mind == 999 ? 0 : mind - 2)
  for (i = istart[k] + 1; i <= iend[k]; i++) {
    if (blank(L[i])) { add_ins(dst, ""); continue }
    ln = L[i]
    # mind は最小字下げなので、どの行も先頭 sh 文字は必ず空白。安全に落とせる。
    if (sh > 0) ln = substr(ln, sh + 1)
    else if (sh < 0) ln = sp(-sh) ln
    add_ins(dst, ln)
  }
  for (i = istart[k]; i <= iend[k]; i++) del[i] = 1
  # 直後の空行は、直上も空行のときだけ一緒に落とす(空行が2本続くのを作らない)。
  if (iend[k] + 1 < se && blank(L[iend[k] + 1]) && istart[k] > 1 && blank(L[istart[k] - 1]))
    del[iend[k] + 1] = 1
  say("M", "`" iid[k] "` " isum[k] " → `## 完了記録`(✅ " dt ")")
}

function do_archive(   k, i, nm, dst, has_entry) {
  nm = 0
  for (k = 1; k <= ni; k++) {
    if (istat[k] != "x") continue
    # **証拠行を持たない `[x]` は移さない。** 移すと「検証されていない完了」が
    # 恒久記録に残り、後から見分けられなくなる(--lint の no-evidence も、
    # 着手順から出た瞬間に検査対象外になって黙る)。
    if (!ihas_evi[k]) {
      say("W", "`" iid[k] "` は `[x]` だが証拠行が無い —— **移さない**。先に `--done " iid[k] " --evidence \"何を確認したか\"` で証拠を足すこと(移行免除の `(移行: 証拠なし)` も証拠ではないので同じ扱い)。")
      continue
    }
    nm++; mv[nm] = k
  }
  say("C", nm)
  if (nm == 0) {
    say("I", "移す対象は0件(証拠行を持つ `[x]` 項目が無い)。何もしていない。")
    changed = 0
    return
  }
  if (ds == 0) {
    # 置き場が無ければ作る。位置は session-head-end マーカーの直後 ——
    # 完了記録は「頭」ではなくカタログ側に属する(閉じた項目を毎セッション注入する理由は無い)。
    if (mk == 0)
      die("`## 完了記録` 節が無く、作る位置(`<!-- session-head-end` マーカー)も無い —— **何も書いていない。** 先に `## 完了記録` 節を作るか、マーカーを入れること(/harness:doctor が配る雛形が正)。")
    dst = mk
    add_ins(dst, "")
    add_ins(dst, "## 完了記録(着手順から降ろしたもの)")
    add_ins(dst, "")
    add_ins(dst, "頭は予算制なので、完了した項目はここへ降ろす。**ID は再利用しない**(log.md から参照されるため)。")
    add_ins(dst, "")
    # 過去形にしない —— このメッセージは dry-run でも出る(まだ1バイトも書いていない)。
    say("I", "`## 完了記録` 節が無いので、session-head-end マーカーの直後に新設する。")
  } else {
    # 既存の節へは**末尾に追記**する。先頭へ挿すのはボツ —— 追記なら git 差分が
    # 「+N -M(着手順から消えた分)」で読め、既存行の位置が動かない(log.md の
    # append-only と同じ理屈。索引だけが新しい順で、本文は時系列)。
    has_entry = 0; dst = ds
    for (i = ds + 1; i < de; i++) {
      if (blank(L[i])) continue
      dst = i
      if (L[i] ~ /^- /) has_entry = 1
    }
    # 既存エントリがあれば詰めて並べる(実物の完了記録は項目間に空行が無い)。
    # 導入散文しか無い節にいきなりぶら下げると段落と箇条書きが繋がるので、そのときだけ空行。
    if (!has_entry) add_ins(dst, "")
  }
  for (i = 1; i <= nm; i++) move_item(mv[i], dst)
  # 全部降ろすと「着手順」節が空になる。**それ自体は正しい状態**(やることが無い)だが、
  # 読み側の --lint は項目0件を `not-migrated`(旧書式のまま未移行)と診断して落ちる ——
  # 空にした本人には的外れな診断で、原因を探して時間を溶かす。
  # ここで先に言っておく。**止めはしない**(強制は最小・検知は最大。空にする自由は残す)。
  # ボツ案: 最後の1件は移さない。「やることが無い」を表現できなくなるうえ、
  # なぜ1件だけ残るのかが利用者から見て説明できない。
  if (ni - nm == 0)
    say("W", "これで「## 着手順」の項目が0件になる —— **--lint は0件を `not-migrated`(未移行)と診断して非0で落ちる**(空にしたこと自体は異常ではないが、検査器から見ると書式ドリフトと区別が付かない)。次の項目を `--add` で足すこと。")
  changed = 1
}

# --- 出力 -------------------------------------------------------------------
# 削除と挿入を1回のループで反映する。**元の行はそのまま印字する**(整形し直さない)——
# 節の外はもちろん、節の中でも触っていない行が1バイトでも変わると、
# 「着手順だけを書き換えた」という約束が検証できなくなる(git diff で見えなくなる)。
function emit(   i, j) {
  for (i = 1; i <= n; i++) {
    if (!del[i]) print L[i]
    for (j = 1; j <= insn[i]; j++) print ins[i, j]
  }
}

{ L[NR] = $0; n = NR }

END {
  if (n == 0) die("ファイルが空 —— 書き込み対象として不正。**何も書いていない。**")
  scan_all_ids()
  locate_sections()
  collect_items()
  if      (op == "add")     do_add()
  else if (op == "done")    do_done()
  else if (op == "note")    do_note()
  else if (op == "archive") do_archive()
  else die("内部エラー: 未知の操作 " op)
  if (!changed) exit 10
  emit()
  exit 0
}
AWK

  REPORT="$tmp/report"; : > "$REPORT"
  NEW="$tmp/new"
  TODAY=$(date +%Y-%m-%d)

  # report を人向けに流す。**stdout = データ / stderr = 診断**を守る:
  #   I(何をしたか)と M(移動の内訳)は操作の結果 = データなので stdout。
  #   E / W は診断なので stderr。N / C は機械用の値なので、ここでは出さない。
  emit_report() {
    local TAB sev msg
    TAB=$(printf '\t')
    while IFS="$TAB" read -r sev msg; do
      case "$sev" in
        E) printf '✗ %s\n' "$msg" >&2 ;;
        W) printf '⚠️ %s\n' "$msg" >&2 ;;
        I) printf '%s\n' "$msg" ;;
        M) printf '  %s\n' "$msg" ;;
      esac
    done < "$REPORT"
  }
  report_value() { awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$REPORT"; }

  # 書き込み後の「頭」のサイズ。**その場で出す**のが要点 —— 書いた本人が予算超過に
  # 気づかないと、次のセッションで SessionStart が無言に切り詰められるまで誰も気づかない。
  print_head_size() {
    local f=$1 marker lines
    marker=$(grep -n -m1 '^<!-- session-head-end' "$f" | cut -d: -f1 || true)
    if [ -z "$marker" ]; then
      echo "⚠️ session-head-end マーカーが無いので「頭」のサイズを測れない(境界が定義できない)。" >&2
      return 0
    fi
    lines=$((marker - 1))
    if [ "$lines" -ge 1 ]; then measure "$(sed -n "1,${lines}p" "$f")"; else MEAS_CHARS=0; MEAS_TOKENS=0; fi
    # 行数も出すが**予算としては出さない**(参考値)。行はどの機構も使っておらず、
    # 言語構成で 2 倍以上ブレる —— 予算に使うと日本語の正典だけ不当にきつくなる。
    # それでも表示は残す: 人が「どこを削るか」を探すときの手掛かりは結局行だから。
    printf '頭: %s字 / ≒%s tok(予算 %s字 / %s tok)・%s 行(参考)\n' \
      "$MEAS_CHARS" "$MEAS_TOKENS" "$HEAD_WARN_CHARS" "$HEAD_WARN_TOKENS" "$lines"
    # ⚠️ 閾値を上げて警告を消すのは禁止。減らす手段(--archive / 棚卸し)を必ず添える。
    if [ "$MEAS_CHARS" -gt "$HEAD_HARD_CHARS" ]; then
      echo "✗ 頭が ${MEAS_CHARS}字(> ${HEAD_HARD_CHARS}字)—— SessionStart の stdout は**無言に切り詰められ 2KB のプレビューだけが注入される**(anthropics/claude-code#70460・#84021)。いま実際に切れている。--archive で降ろすか棚卸しすること。" >&2
    elif [ "$MEAS_CHARS" -gt "$HEAD_WARN_CHARS" ]; then
      echo "⚠️ 頭が ${MEAS_CHARS}字(予算 ${HEAD_WARN_CHARS}字)。余裕は ${HEAD_HARD_CHARS}字まで。**閾値は上げない** —— --archive で降ろすか棚卸しすること。" >&2
    fi
    if [ "$MEAS_TOKENS" -gt "$HEAD_WARN_TOKENS" ]; then
      echo "⚠️ 頭が ≒${MEAS_TOKENS} tok(予算 ${HEAD_WARN_TOKENS} tok)。切り詰めには余裕があるが**毎セッション払う**。**閾値は上げない** —— --archive で降ろすか棚卸しすること。" >&2
    fi
  }

  rc=0
  ND_SUMMARY="$OP_SUMMARY" ND_CRITERIA="$OP_CRITERIA" ND_EVIDENCE="$OP_EVIDENCE" ND_NOTE="$OP_NOTE" \
    awk -v op="$OP" -v id="$OP_ID" -v today="$TODAY" -v report="$REPORT" \
        -f "$EDITOR" "$TARGET" > "$NEW" || rc=$?

  case "$rc" in
    0) ;;                                  # 変更あり。$NEW が新しい全文
    10) emit_report; exit 0 ;;             # 変更不要(冪等)。**書かない**
    3) emit_report
       echo "  (対象: $TARGET)" >&2
       exit 3 ;;
    *) echo "✗ 内部エラー: エディタが終了コード $rc で落ちた。**何も書いていない。**" >&2
       exit 3 ;;
  esac

  # --- --archive は既定 dry-run(plan → validate → execute) --------------------
  # 破壊的操作を「見てから実行する」形にしておくと、**移す対象の判定を間違えていたときに
  # 気づく機会が1回増える**。証拠行の有無だけで運命が決まる操作なので、ここは必ず挟む。
  nmove=""
  if [ "$OP" = "archive" ]; then
    nmove=$(report_value C)
    if [ "$APPLY" -eq 1 ]; then
      echo "=== harness:status --archive — 完了記録へ降ろす ==="
    else
      echo "=== harness:status --archive — 完了記録へ降ろす(dry-run) ==="
    fi
    echo
    emit_report
    echo
    if [ "$APPLY" -eq 0 ]; then
      printf '%s 件が対象。**まだ1バイトも書いていない。** 実際に移すには --apply を付けること:\n' "$nmove"
      printf '    nd-tasks.sh --archive --apply %s\n' "$TARGET"
      exit 0
    fi
  fi

  # --- 書き込み(atomic) -------------------------------------------------------
  # 内容が同じなら書かない。**冪等なスクリプトは黙って何もしないのが正常系**なので、
  # 何も起きなかったこと自体を出力する(無出力だと「動いたのか?」が分からない)。
  if cmp -s "$TARGET" "$NEW"; then
    echo "変更なし(生成結果が現在の内容と一致した)。何も書いていない。"
    exit 0
  fi
  # 同じディレクトリへ書いてから mv する。**mv は同一ファイルシステム内なら atomic** なので、
  # 途中で落ちても正典が半分だけ書き潰された状態にはならない(log-index.sh と同じ流儀)。
  # 代償としてパーミッションは umask 由来に戻るが、.md なので実害なし。
  # ⚠️ $tmp(mktemp -d)ではなく**正典と同じディレクトリ**へ置くのが要点 —— TMPDIR が
  #    別ファイルシステムだと mv が「コピー + 削除」に退化して atomic でなくなる。
  wtmp="$TARGET.nd-tasks.tmp.$$"
  # cp が途中で失敗(ディスク満杯など)したときに、正典の隣に残骸を置き去りにしない。
  # docs/ 配下のゴミは次のセッションで「これは何だ」を生むし、探索グロブに引っかかりうる。
  trap 'rm -rf "$tmp"; [ -z "${wtmp:-}" ] || rm -f "$wtmp"' EXIT
  cp "$NEW" "$wtmp"
  mv "$wtmp" "$TARGET"
  wtmp=""   # mv 済み。trap が消しにいかないようにする

  [ "$OP" = "archive" ] || emit_report
  case "$OP" in
    add)     printf '✓ `%s` を追加した — %s\n' "$(report_value N)" "$TARGET" ;;
    done)    printf '✓ `%s` を完了にした — %s\n' "$OP_ID" "$TARGET" ;;
    note)    printf '✓ `%s` に更新行を積んだ — %s\n' "$OP_ID" "$TARGET" ;;
    archive) printf '✓ %s 件を `## 完了記録` へ移した — %s\n' "$nmove" "$TARGET" ;;
  esac
  print_head_size "$TARGET"
  exit 0
fi

nfiles=0
if [ ${#EXPLICIT[@]} -gt 0 ]; then
  for f in "${EXPLICIT[@]}"; do
    [ -f "$f" ] || { echo "✗ ファイルが無い: $f" >&2; exit 2; }
    scan_file "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; nfiles=$((nfiles + 1))
  done
elif [ "$ALL" -eq 1 ]; then
  # HARNESS_ROOTS は「グロブを含む文字列」。展開させるために**意図的に引用しない**
  # (引用すると 1 個のリテラルパスとして扱われ、1件も見つからなくなる)。
  roots_glob=${HARNESS_ROOTS:-${HOME:?HOME が未設定}/ghq/github.com/*/*}
  # shellcheck disable=SC2086
  for d in $roots_glob; do
    [ -d "$d" ] || continue
    # 1行1ファイルで受ける。$(...) を直接 for に食わせると空白を含むパスが割れる
    # (ghq 配下では滅多に無いが、割れたときの症状が「静かに1件も出ない」なので避ける)。
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      scan_file "$f"; nfiles=$((nfiles + 1))
    done <<EOF
$(nds_of_repo "$d")
EOF
  done
  if [ "$nfiles" -eq 0 ]; then
    echo "✗ --all: next-directions.md を持つリポジトリが1つも見つからない($roots_glob)。" >&2
    echo "  探索パターンが実態と合っていない可能性がある。HARNESS_ROOTS で上書きできる。" >&2
    exit 2
  fi
else
  base=$(cd "${CLAUDE_PROJECT_DIR:-.}" && pwd)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    scan_file "$f"; nfiles=$((nfiles + 1))
  done <<EOF
$(nds_of_repo "$base")
EOF
  if [ "$nfiles" -eq 0 ]; then
    echo "✗ $base に docs/next-directions.md も docs/*/next-directions.md も無い。" >&2
    echo "  ハーネス未導入なら /harness:doctor で導入できる。" >&2
    exit 2
  fi
fi

# --- 未移行の緩和(--all のときだけ) -----------------------------------------
# **横断 board(--all)でだけ「未移行」を警告へ落とす。**
#
# なぜ --all だけか: fail-closed が本当に効いてほしいのは「**前は読めていたものが
# 読めなくなった**」= 書式ドリフト。「まだ移行していない」は既知の状態であって異常ではない。
# 横断 board は毎日叩くもので、未移行リポジトリが1つでもある限り常に赤になると、
# **赤の意味そのものが消えて本物のドリフトが埋もれる**(閾値を上げて警告を消すのを
# 禁じているのと同じ理屈 —— 検知は「鳴りっぱなし」でも死ぬ)。
#
# 単一リポジトリを見るとき(既定 / --lint)は緩めない。そこでは未移行は
# 「今このリポジトリで直すべきこと」そのものなので、赤で正しい。
nmigrated_out=0
if [ "$ALL" -eq 1 ]; then
  awk -F "$US" -v OFS="$US" \
    '$1 == "E" && ($5 == "no-section" || $5 == "not-migrated") { $7 = "W" } 1' \
    "$RECS" > "$RECS.new" && mv "$RECS.new" "$RECS"
fi
# 未移行のファイル数(サマリに出す。件数が見えていれば「まだやっていない」は伝わる)。
nmigrated_out=$(awk -F "$US" '$1=="E" && ($5=="no-section" || $5=="not-migrated")' "$RECS" | wc -l | tr -d ' ')

# 違反(sev=V)が1件でもあれば非0。頭のバイト数超過(sev=W)は健康指標であって
# 書式違反ではないので、終了コードは動かさない(鳴らしすぎて無視されるのを避ける)。
nviolation=0
while IFS="$US" read -r t _r _c _f _code _ln sev _msg; do
  [ "$t" = "E" ] || continue
  [ "$sev" = "V" ] && nviolation=$((nviolation + 1))
done < "$RECS"

# --- 出力: --lint --------------------------------------------------------------
if [ "$MODE" = "lint" ]; then
  echo "=== harness:status --lint — 着手順の書式検査 ==="
  echo
  nwarn=0
  while IFS="$US" read -r t r c f code ln sev msg; do
    [ "$t" = "E" ] || continue
    loc="$f"; [ "$ln" != "0" ] && loc="$f:$ln"
    if [ "$sev" = "V" ]; then printf '✗ [%s] %s\n    %s\n' "$code" "$loc" "$msg"
    else printf '⚠️ [%s] %s\n    %s\n' "$code" "$loc" "$msg"; nwarn=$((nwarn + 1)); fi
  done < "$RECS"
  nitem=$(awk -v US="$US" -F "$US" '$1=="I"' "$RECS" | wc -l | tr -d ' ')
  migr=""; [ "$nmigrated_out" -gt 0 ] && migr=" / 未移行 ${nmigrated_out} ファイル"
  echo
  if [ "$nviolation" -eq 0 ]; then
    printf '✓ %s ファイル / %s 項目%s — 違反なし(警告 %s 件)\n' "$nfiles" "$nitem" "$migr" "$nwarn"
    exit 0
  fi
  printf '✗ %s ファイル / %s 項目%s — 違反 %s 件(警告 %s 件)\n' "$nfiles" "$nitem" "$migr" "$nviolation" "$nwarn"
  exit 1
fi

# --- 出力: --format json -------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  awk -v nfiles="$nfiles" '
    function jesc(s) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
      gsub(/\t/, "\\t", s); gsub(/\r/, "", s)
      gsub(VT, "\\n", s); gsub(FF, "\\n", s)   # ブロック区切りも折り返しも JSON では改行
      return s
    }
    function jstr(s) { return "\"" jesc(s) "\"" }
    # 証拠は「何を確認したか」の記録が複数並びうるので配列で出す(件数がそのまま
    # 検証の厚みになる)。detail / done_criteria は散文なので \n 入りの文字列で出す。
    function jarr(s,   n, a, i, out) {
      if (s == "") return "[]"
      n = split(s, a, VT); out = ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") jstr(a[i])
      return "[" out "]"
    }
    BEGIN { US = sprintf("%c", 31); VT = sprintf("%c", 11); FF = sprintf("%c", 12); FS = US
            ni = 0; nf = 0; ne = 0 }
    $1 == "I" { ni++; I[ni] = $0 }
    $1 == "F" { nf++; F[nf] = $0 }
    $1 == "E" { ne++; E[ne] = $0 }
    END {
      print "{"
      printf "  \"items\": ["
      for (i = 1; i <= ni; i++) {
        split(I[i], f, US)
        printf "%s\n    {", (i > 1 ? "," : "")
        printf "\"id\": %s, ", jstr(f[5])
        printf "\"status\": %s, ", (f[6] == "x" ? "\"done\"" : "\"open\"")
        printf "\"summary\": %s, ", jstr(f[7])
        printf "\"detail\": %s, ", jstr(f[8])
        printf "\"done_criteria\": %s, ", jstr(f[9])
        printf "\"evidence\": %s, ", jarr(f[10])
        printf "\"file\": %s, ", jstr(f[4])
        printf "\"component\": %s, ", jstr(f[3])
        printf "\"repo\": %s}", jstr(f[2])
      }
      print (ni ? "\n  ]," : "],")
      printf "  \"files\": ["
      for (i = 1; i <= nf; i++) {
        split(F[i], f, US)
        printf "%s\n    {", (i > 1 ? "," : "")
        printf "\"file\": %s, ", jstr(f[4])
        printf "\"repo\": %s, ", jstr(f[2])
        printf "\"component\": %s, ", jstr(f[3])
        printf "\"head_chars\": %d, ", f[5]
        printf "\"head_tokens_est\": %d, ", f[9]
        printf "\"has_marker\": %s, ", (f[6] == "1" ? "true" : "false")
        printf "\"head_injection\": %s}", (f[7] == "1" ? "true" : "false")
      }
      print (nf ? "\n  ]," : "],")
      printf "  \"errors\": ["
      for (i = 1; i <= ne; i++) {
        split(E[i], f, US)
        printf "%s\n    {", (i > 1 ? "," : "")
        printf "\"code\": %s, ", jstr(f[5])
        printf "\"severity\": %s, ", (f[7] == "V" ? "\"violation\"" : "\"warning\"")
        printf "\"file\": %s, ", jstr(f[4])
        printf "\"repo\": %s, ", jstr(f[2])
        printf "\"component\": %s, ", jstr(f[3])
        printf "\"line\": %d, ", f[6]
        printf "\"message\": %s}", jstr(f[8])
      }
      print (ne ? "\n  ]" : "]")
      print "}"
    }
  ' "$RECS"
  [ "$nviolation" -eq 0 ] || exit 1
  exit 0
fi

# --- 出力: --format text -------------------------------------------------------
awk -v grouped="$ALL" -v nfiles="$nfiles" -v nmigr="$nmigrated_out" -v nviol="$nviolation" \
    -v warn_chars="$HEAD_WARN_CHARS" -v hard_chars="$HEAD_HARD_CHARS" -v warn_tok="$HEAD_WARN_TOKENS" '
  # markdown の表を壊さないためのセル用エスケープ。桁揃えはしない ——
  # 日本語は文字幅が環境で変わるので、揃えようとすると必ずズレる。
  function cell(s) { gsub(/\|/, "\\|", s); return s }

  # 折り返し(FF)を繋ぎ直して1セルに戻す。表のセルは改行を持てないので、ここで畳む。
  # 日本語は空白なしで繋ぐのが正しいが、繋ぎ目のどちらかが英数字なら単語が結合しないよう
  # 空白を入れる(「…の」+「glob が」→「の glob が」。片側だけ見ると取りこぼす)。
  function unwrap(s,   n, a, i, out) {
    n = split(s, a, FF); out = a[1]
    for (i = 2; i <= n; i++)
      out = out ((out ~ /[A-Za-z0-9,.;:)`*]$/ || a[i] ~ /^[A-Za-z0-9(`*_[]/) ? " " : "") a[i]
    return out
  }
  # 「→」ブロック(完了条件 / 証拠)を、項目行の下にぶら下げる行として出す。
  function arrow_rows(s, prefix,   m, d, k) {
    m = split(s, d, VT)
    for (k = 1; k <= m; k++) print "|  |  | " prefix cell(unwrap(d[k])) " |  |"
  }

  # 頭(SessionStart が注入する範囲)のサイズ表。**横断 board の主要な健康指標**。
  # 2つの機構をそれぞれの単位で見る —— 切り詰めは**文字**(#70460 / #84021)、
  # 毎セッションの実費は**トークン**。行は出さない(言語構成で 2 倍以上ブレる代理指標)。
  # 項目が0件のリポジトリでもここだけは出す。
  function head_table(r,   i, f, p, verdict) {
    print ""; print "### 頭のサイズ(SessionStart が注入する範囲)"; print ""
    print "| ファイル | 文字 | 概算tok | 判定 |"
    print "|---|---|---|---|"
    for (i = 1; i <= n; i++) {
      if (typ[i] != "F" || rp[i] != r) continue
      split(rec[i], f, US)
      p = f[4]; sub("^" root[r] "/", "", p)
      # 判定は「重い順に1つだけ」。マーカー無し > 切り詰め > 文字が目安超 > トークン超。
      # 複数出すと**どれから直せばいいかが消える**(表の1セルに収める以上、順位付けが要る)。
      if (f[6] != "1") verdict = (f[7] == "1" ? "✗ マーカー無し = 注入が停止中" : "⚠️ マーカー無し(頭/カタログの境界が無い)")
      else if (f[5] + 0 > hard_chars) verdict = "✗ " comma(hard_chars) "字超 — 無言に切り詰められている(#70460)"
      else if (f[5] + 0 > warn_chars) verdict = "⚠️ 目安 " comma(warn_chars) "字 超"
      else if (f[9] + 0 > warn_tok) verdict = "⚠️ 予算 " comma(warn_tok) " tok 超(毎セッションの実費)"
      else verdict = "✓"
      print "| " cell(p) " | " (f[6] == "1" ? comma(f[5]) : "(全文 " comma(f[5]) ")") \
            " | ≒" comma(f[9]) " | " verdict " |"
    }
  }
  function comma(n,   s, out) {
    s = sprintf("%d", n); out = ""
    while (length(s) > 3) { out = "," substr(s, length(s) - 2) out; s = substr(s, 1, length(s) - 3) }
    return s out
  }
  BEGIN { US = sprintf("%c", 31); VT = sprintf("%c", 11); FF = sprintf("%c", 12)
          FS = US; n = 0; nr = 0 }
  {
    n++; rec[n] = $0; typ[n] = $1; rp[n] = $2
    if (!($2 in seen)) { seen[$2] = 1; order[++nr] = $2 }
    if ($1 == "F") root[$2] = $8
  }
  END {
    print "=== harness:status — 着手順 ==="
    total_open = 0; total_done = 0
    for (ri = 1; ri <= nr; ri++) {
      r = order[ri]
      if (grouped == 1) { print ""; print "## " r " — " root[r] }

      # 1項目も取れなかったリポジトリで「(なし)」を3区分ぶん並べても情報が無いので畳む。
      # --all では未移行リポジトリが大半を占めるため、ここを畳まないと一覧が読めなくなる
      # (**畳んでも警告は stderr に必ず出る**ので、静かに消えることはない)。
      empty = 1
      for (i = 1; i <= n; i++) if (typ[i] == "I" && rp[i] == r) { empty = 0; break }
      if (empty) {
        print ""
        print "着手順の項目が0件(未移行か書式ずれ。**タスクが無いという意味ではない** — stderr の警告を見ること)"
        head_table(r)
        continue
      }

      # --- 区分1: 次にやること -------------------------------------------------
      # 一覧の主目的は「次に何をすれば閉じられるか」なので、完了条件も一緒に出す。
      cnt = 0
      for (i = 1; i <= n; i++) if (typ[i] == "I" && rp[i] == r) { split(rec[i], f, US); if (f[6] != "x") cnt++ }
      total_open += cnt
      print ""; print "### 次にやること (" cnt ")"; print ""
      if (cnt == 0) print "(なし)"
      else {
        print "| 状態 | ID | 概要 | コンポーネント |"
        print "|---|---|---|---|"
        for (i = 1; i <= n; i++) {
          if (typ[i] != "I" || rp[i] != r) continue
          split(rec[i], f, US); if (f[6] == "x") continue
          print "| ☐ | `" f[5] "` | " cell(unwrap(f[7])) " | " (f[3] == "" ? "-" : f[3]) " |"
          if (f[9] != "") arrow_rows(f[9], "→ 完了条件: ")
          else            print "|  |  | → 完了条件: **(未記載)** |  |"
        }
      }

      # --- 区分2: 完了(証拠あり) ----------------------------------------------
      cnt2 = 0
      for (i = 1; i <= n; i++) if (typ[i] == "I" && rp[i] == r) { split(rec[i], f, US); if (f[6] == "x" && f[10] != "") cnt2++ }
      print ""; print "### 完了(証拠あり) (" cnt2 ")"; print ""
      if (cnt2 == 0) print "(なし)"
      else {
        print "| 状態 | ID | 概要 | コンポーネント |"
        print "|---|---|---|---|"
        for (i = 1; i <= n; i++) {
          if (typ[i] != "I" || rp[i] != r) continue
          split(rec[i], f, US); if (f[6] != "x" || f[10] == "") continue
          print "| ✅ | `" f[5] "` | " cell(unwrap(f[7])) " | " (f[3] == "" ? "-" : f[3]) " |"
          arrow_rows(f[10], "→ ")
        }
      }

      # --- 区分3: 整理対象 -----------------------------------------------------
      # 完了 [x] は**閉じた時点で「頭」に置く理由が消える**。一覧を作るときにどうせ
      # 全部読むので、ここで件数を出しておく = 棚卸しの起点になる唯一のタイミング。
      # 証拠の有無は問わない(証拠なしは「検証済みとして扱わない」ラベルであって、
      # 整理対象かどうかとは独立の軸)。
      cnt3 = 0; ids = ""; noevi = 0
      for (i = 1; i <= n; i++) {
        if (typ[i] != "I" || rp[i] != r) continue
        split(rec[i], f, US); if (f[6] != "x") continue
        cnt3++; ids = ids (ids == "" ? "" : ", ") "`" f[5] "`"
        if (f[10] == "") noevi++
      }
      total_done += cnt3
      print ""; print "### 整理対象 (" cnt3 ")"; print ""
      if (cnt3 == 0) print "(なし)"
      else {
        print "完了 `[x]` は閉じた時点で「頭」に置く理由が消える —— カタログ部か log.md へ移す候補。"
        print "対象: " ids (noevi > 0 ? "(うち証拠行なし " noevi " 件)" : "")
        print "**移すのは `/harness:tidy` の仕事。** next は読んで出すだけで動かさない。"
      }

      head_table(r)
    }
    # サマリ。未移行の件数を必ず出す —— --all では未移行を warning へ落として exit 0 に
    # するので、**数字が見えていないと「まだやっていない」ことが伝わらない**。
    print ""
    printf "次にやること %d / 整理対象 %d(%d ファイル / %d リポジトリ / 未移行 %d / 違反 %d)\n",
           total_open, total_done, nfiles, nr, nmigr, nviol
  }
' "$RECS"

# 警告・違反は stderr へ。一覧(stdout)を人に見せるときの本体から分離しておくと、
# パイプで加工しても検知が消えない。
while IFS="$US" read -r t r c f code ln sev msg; do
  [ "$t" = "E" ] || continue
  loc="$f"; [ "$ln" != "0" ] && loc="$f:$ln"
  if [ "$sev" = "V" ]; then printf '✗ [%s] %s\n   %s\n' "$code" "$loc" "$msg" >&2
  else printf '⚠️ [%s] %s\n   %s\n' "$code" "$loc" "$msg" >&2; fi
done < "$RECS"

if [ "$nviolation" -gt 0 ]; then
  printf '\n✗ 違反 %s 件。**0件で落ちたときは「タスクが無い」ではなく書式かパーサが壊れている**。詳細は --lint。\n' "$nviolation" >&2
  exit 1
fi
exit 0
