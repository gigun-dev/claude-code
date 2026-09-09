# todo — リポジトリの持続的な文脈をタスクと決定で持つ

エージェントが読む文脈を、リポジトリのファイルに置く 1 つの配布単位。
**これからやることは `todo.txt`、覆しにくい決まりごとは `docs/adr/`。**
CLI は `bin/todo` と `bin/adr` の 2 本、skill は `todo` / `adr` / `doctor` の 3 つ。
(`adr` は 2026-09-10 まで別プラグインだった。統合の理由は
`docs/adr/0005-merge-adr-into-the-todo-plugin.md`。)

タスク側は `harness` の後継。守るものは 3 つだけ:

- **枯れた慣行に乗る。** 形式は [todo.txt](https://github.com/todotxt/todo.txt) そのもの。
  語彙は [todo.txt-cli](https://github.com/todotxt/todo.txt-cli) から借りる。
  独自形式なら、それを読める道具はこのプラグインだけになる。
- **独自の記録ファイルを持たない。** リポジトリ直下の `todo.txt`(open)と
  `done.txt`(完了)の 2 つだけ。現在地も log も作らない ——
  **経緯は git のコミットメッセージ、知識は docs、これからやることが todo.txt。**
- **腐る散文を持たない。** todo.txt に書けるのは「終わったと言える次の一手」だけ。
  学んだことや撤回を書き足せる場所を作らない。作れば必ず腐る。

`id:` と `dep:` は、エージェントがタスクを指し・順序を判断するための最小の拡張。
仕様の `key:value` の範囲内で、todo.sh から見ればただの語として素通りする。

## todo.txt の行の形

```
(A) 2026-09-10 iPhone 相手で送信バッファを A/B する +upload @device dep:0001 see:docs/x.md id:0002
x 2026-09-10 2026-09-08 完了した本文 +upload id:0001                        ← done.txt
```

正の置き場は 2 つに分かれる。**ここで複製すると必ずドリフトするので、要点だけ:**

- **上流の仕様**は `skills/todo/references/todo-txt-format.md` に**そのまま**入れてある
  (上流 README の逐語コピー。GPL-3.0 で、同じディレクトリの `LICENSE-todo-txt` が
  そのライセンス)。**編集しない** —— 更新は上流から取り直す。
- **このプラグインの拡張**(`id:` `dep:` `see:` `@wip`・並び順)は
  `skills/todo/SKILL.md` の「語彙」が正。**毎回の起動で要る情報なので reference に
  置かない**(reference は必要になったときだけ読まれる)。

- `(A)`〜`(Z)` は**重要度**。進行中は表さない —— それは `@wip`。
- `@` は**そのタスクが要る状況**(`@device` `@user` `@unattended`)。
- **作成日は仕様上「任意」**。`add` は必ず付けるが、無い行を `check` は咎めない
  —— 手で書いた行を追い返す理由が仕様に無い。`id:` が無いのは咎める(CLI が
  触れなくなるため)が、**`todo id` で配れる**ので直し方は 1 コマンド。

完了行でも `id:` は残す —— 後続の `dep:` が「その id は done にあるか」で解決するため。
`done.txt` の行を消してよいのは、**その id を指す `dep:` がどこにも無いとき**だけ
(残っていれば `check` が宙吊りとして名指しする)。

### 採番

`add` と `todo id` は **`todo.txt` と `done.txt` の両方**の max+1 を、
4 桁ゼロ詰め(`id:0001`)で書く。桁は ADR の `NNNN-slug.md` と揃えてある
—— 同じリポジトリに 2 種類の採番が並ぶので、見た目が同じ方が読み違えない。
9999 を超えたら 5 桁になるだけで、特別扱いはしない。

**連番が安全なのは、書き手が 1 人だから** —— todo.txt を更新するのは本線だけで、
worktree の implementer は報告するに留める(`skills/todo/SKILL.md` の規律)。
並行して 2 箇所が `add` すれば同じ番号を取り、マージで衝突する。

指すときのゼロ詰めは任意で、**数値として完全一致**したものだけを引く
(`todo do 12` は `id:0012` に当たるが、`todo do 3` は `id:0030` に当たらない)。
`id:0012` と `id:12` が両方あるのは同じ番号の重複なので、`check` が名指しし、
どちらを指すか決められないコマンドは落ちる。

## todo のコマンド

```sh
todo add "text"          # 作成日と id: を付けて追記(+proj @ctx key:value は text にそのまま書く)
todo ready [TERM...]     # dep: が解けている open 行 = いま着手できる / 並列に投げられる
                         #   ADR があれば先頭に決定の索引(題だけ)を出す
todo ls [TERM...]        # open を優先度順に。TERM は AND、-TERM で除外
todo start ID            # @wip を付ける / todo stop ID で外す
todo do ID...            # @wip を外して done.txt へ移す
todo pri ID A            # 優先度を付ける / todo depri ID で外す
todo replace ID "text"   # 本文を置き換える(id: と作成日と優先度は保持)
todo append ID "text"    # 行末に足す / todo prepend ID "text" は本文の先頭へ
todo listproj / listcon  # +project / @context の一覧
todo show ID...          # 1 行を出す(done.txt も見る)
todo check               # 形式検査。違反があれば stdout に出して 2 で終わる
todo id                  # id: の無い open 行すべてに id: を配る(冪等)
```

**インターフェイスの正は `todo --help`。**ここは索引で、食い違ったら `--help` が正しい。

- **`ready` の先頭には決定の索引が出る**(ADR が 1 件以上あるときだけ。0 件なら無音)。
  出るのは `adr ls` と同じ題の索引で、**本文は出さないし truncate もしない** ——
  新しい順に切ると、忘れやすい古い決定から先に隠れる。代わりに、行数が閾値
  (`bin/todo` の `ADR_INDEX_WARN_AT`、既定 30)を超えたら索引自身がそう報せる。
  `ls` には出さない —— 読む口は一つに保つ。
- **ID は数値としての完全一致のみ。** ゼロ詰めは付けても付けなくてよい。
- 対象は `$TODO_DIR/todo.txt` と `$TODO_DIR/done.txt`(既定は `.`)。
  環境変数名は todo.txt-cli と同じ `TODO_DIR`。
- 対話しない。データは stdout、診断は stderr。色は付けない(エージェントが読む前提)。
- 終了コード: **0** 成功 / **1** 引数・状態の誤り / **2** 形式違反(`check`、
  または書けば増やすので書かなかった)/ **3** ID が見つからない。
- `do` / `start` / `stop` は冪等 —— 既に done、既に `@wip`、`@wip` が無い、は
  エラーではなく「何もしない」。**再実行を怖がらせない**(怖いと、状態が
  変わった瞬間に走らせる規律が最初に折れる)。

`bin/todo` は単一の POSIX sh + awk。bash 固有機能・python・jq に依存しない
—— Nix 環境の外や sandbox でも動く必要があるため。

CLI はプラグイン内の `bin/` に同梱する。Claude / Codex とも、skill の実パスから
同梱 CLI の絶対パスを解決して実行する。PATH の自動追加には依存しない。
対象データは作業中のリポジトリにあるため、CLI を呼ぶときにプラグイン側へ移動しない。

### 手で編集してよい

todo.txt の第一目標は「テキストエディタで編集できること」。CLI は楽なだけで、
行を直接足しても書き換えてもよい。**次の `ls` / `ready` が壊れていれば教える**
(一覧の前に `✗` を出す。一覧自体は成功で返る)。リポジトリの検証コマンドに
`todo check` を足しておくとさらに早く気づける。

書き込むコマンドは、書く前に結果を検査して**違反を増やすなら書かない**
(宙吊り `dep:` を作る `add`、URL を入れる `append` などはその場で落ちる)。
既に違反があるファイルからでも CLI で直せるよう、「0 件でなければ拒む」ではなく
「増えるなら拒む」にしてある。フックは置かない —— 呼ばれる保証の無い場所へ検査を
置くと、検査が黙って死ぬ。

## ADR のファイルの形

決定の側で守るのは 2 つ:

- **書式も採否の基準も自作しない。** [mattpocock/skills](https://github.com/mattpocock/skills)
  の `ADR-FORMAT.md` を**逐語で** vendor してある(MIT。同じディレクトリの
  `LICENSE-mattpocock-skills` がそのライセンス)。置き場は
  `skills/adr/references/ADR-FORMAT.md`。**編集しない** —— 更新は上流から取り直す。
- **書く前に読む。** ADR の一番の値打ちは「もう決まっている」を先に知ること。
  `todo ready` は出力の先頭に決定の索引を出し、`adr` skill は最初に `adr ls` を指示する。

書くのはエージェントで、CLI は一覧と検査だけを持つ。雛形を吐くコマンドは置かない
—— 埋める欄があると、埋めるために創作が始まる。

```
docs/adr/0003-use-manual-sql-instead-of-an-orm.md

  # Use manual SQL instead of an ORM

  2026-09-10 に決めた。<何が文脈で、何を決めて、なぜか。1〜3 文>
```

- ファイル名は `NNNN-<小文字ケバブの slug>.md`。番号は 4 桁で、既存の最大値 + 1
  (`adr ls` の一番下が最大値)。**採番後に改名しない。**
- 日付は `YYYY-MM-DD`。書き出しの文の中か、`Date:` の 1 行。
- `Status:` / Considered Options / Consequences は**値打ちがあるときだけ**。
  ほとんどの ADR は題 + 1 段落で終わる。
- **受理済みの ADR は編集しない。**差し替えは新しいファイルに書き、その中で古い方を
  名指しする。古い方に許される編集は先頭行 `Superseded by <slug>` だけ。

三重関門(覆すのが高い / 文脈が無いと驚く / 本物の取引の結果)と「何が該当するか」は
上流の `ADR-FORMAT.md` が正。**ここには複製しない**(複製すると必ずドリフトする)。

## adr のコマンド

```sh
adr ls        # <date> <slug> <status> <title> を番号順に 1 行 1 件
adr check     # 書式検査。指摘があれば stdout に出して 2 で終わる
```

**インターフェイスの正は `adr --help`。**ここは索引で、食い違ったら `--help` が正しい。

- 対象は `$ADR_DIR`。未指定なら `docs/adr` → `docs/decisions` → `adr` →
  `decisions` の順に最初に見つかったもの。どれも無ければ何もせず 0 で終わる。
  **この解決は `lib/adr-dir.sh` の 1 箇所**で、`bin/adr` と `bin/todo` の両方が
  読み込む —— 2 つ持つと片方だけ直されてずれる。
- `check` が見るのは、ファイル名 / 番号の重複 / 題 / 日付 / `Superseded by` の
  指す先の実在 / `Status:` の語彙。**改名も書き換えもしない** —— 番号が重複していても
  指摘だけを出す(上流が「改名しない」と言う以上、直すのは人の判断)。
- `Superseded by` があり `Status:` が無ければ、`ls` の status は `superseded`。
- 対話しない。データは stdout、診断は stderr。終了コード: **0** 成功 /
  **1** 引数・状態の誤り / **2** `check` が指摘を出した。

`bin/adr` も単一の POSIX sh + awk。フックは置かない —— 呼ばれる保証の無い場所へ
検査を置くと、検査が黙って死ぬ。

決定が仕事を生んだら、その仕事は ADR ではなく `todo` の 1 行にする
(`see:docs/adr/<slug>.md` で根拠を指す)。

## skills

| skill | いつ | 何を |
|---|---|---|
| `todo:todo` | セッション開始時と、タスクの状態が変わった**瞬間** | `ready` で「いま何が着手できるか」を見る。`start` / `stop` / `do` / `add` / `replace` をその場で走らせる。model-invocable |
| `todo:adr` | 覆しにくい決定が下りた**瞬間**、利用者が裁定したとき、測定が案を否定したとき、「なぜこうなっている」と訊かれたとき、既に決まっていそうな領域へ変更を提案する前 | `ls` で既存の決定を見て、三重関門にかけ、通れば確定した内容を書く。落ちれば勧退してコミットメッセージを勧める。model-invocable |
| `todo:doctor` | 導入時と、`check` が何か言っているとき | 診断のみが既定。導入・移行を依頼されたらファイルと指示の入口を用意する |

skill は最初のコマンドを本文で明示する。Claude 専用の自動実行記法や
`CLAUDE_SKILL_DIR` を必要とせず、Codex でも同じ本文を使う。

拡張の定義は `skills/todo/SKILL.md` の「語彙」1 箇所(doctor もそこを指す)。
上流の仕様は `skills/todo/references/todo-txt-format.md` に逐語で入れてあり、
**行が仕様上どう読まれるか分からないときだけ**読む。

## テスト

```sh
sh plugins/todo/tests/run.sh          # 単体
bash scripts/verify.sh                # pre-push と CI。この中からも走る
```

実行口は `tests/run.sh` の 1 つ。todo の分をそこで走らせ、続けて `tests/adr.sh` を
呼んで件数を合算する。ファイルが 2 つなのは作業場の作り方が違うから ——
todo は `TODO_DIR` を渡し、adr は**カレントディレクトリからの探索**で置き場を
決めるので `cd` したサブシェルから呼ぶ。

todo 側は `add` の採番・`do` の移動・`ready` の依存解決と決定の索引・`replace` の保持・
`check` の各検出・`projects` の集計に加え、**生成した `todo.txt` を todo.txt-cli の
`todo.sh` に読ませる互換テスト**を含む(自分の検査だけでは自作自演になる)。
`todo.sh` が無い環境ではそのテストだけ skip する。`TODO_SH` で場所を指定できる。
日付だけ `TODO_TODAY` で固定する —— 採番は連番なので、空のディレクトリから
始めれば `id:0001` から決まり、注入点が要らない。

adr 側は `ls` の並び(番号順であって日付順でも文字列順でもない)・status の 4 つの
出どころ・`check` の各指摘・ディレクトリの探索順・`ADR_DIR` の上書きを見る。

テストは `sh "$ADRBIN"` ではなく**実行ファイルとして直に呼ぶ**。前者だと PATH 上の
新しい shell で走り、shebang が指す `/bin/sh` —— macOS では **bash 3.2** ——
で一度も走らない。2026-09-10 に実際そうなった: `$( … )` の中の `case` を
bash 3.2 が解析できず `adr` は起動すらできないのに、テストは 39 件すべて緑だった。
**`$( … )` の中に `case` を書かないこと**(括弧付きパターンで逃げると、次に触る人が
普通の書き方へ戻した瞬間に再発する)。`/bin/sh` で `--help` / `ls` / `check` を
叩くテストが番人。

## 導入

Codex: `codex plugin add todo@gigun`。Claude Code: `claude plugin install todo@gigun`。
タスクと決定は同じ 1 つの配布単位なので、`adr@gigun` は無い(2026-09-10 に統合した)。
導入後、doctor スキルに対象リポジトリへの導入を依頼する。
プラグインのインストールと、各リポジトリのデータ・フックの移行は別の作業。
`docs/adr/` は最初の決定を記録するときに作り、空のテンプレートを先に増やさない。
