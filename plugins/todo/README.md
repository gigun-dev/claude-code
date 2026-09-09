# todo — リポジトリのタスクを todo.txt 形式で持つ

`harness` の後継。守るものは 3 つだけ:

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

## 行の形

```
(A) 2026-09-09 iPhone 相手で送信バッファを A/B する +upload @device dep:a3f9c1 see:docs/x.md id:7b2e04
x 2026-09-09 2026-09-08 完了した本文 +upload id:a3f9c1                      ← done.txt
```

**規則の正は `skills/todo/references/format.md`(1 箇所だけ。doctor もそこを指す)。**
ここで複製すると必ずドリフトする。要点だけ:

- `(A)`〜`(Z)` は**重要度**。進行中は表さない —— それは `@wip`。
- `@` は**そのタスクが要る状況**(`@device` `@user` `@unattended`)。
- `id:` は 6 桁の小文字 16 進。**エージェントがタスクを指す唯一の手段。**
- `dep:` の指す先が `done.txt` に入るまで、その行は `ready` に出ない。
- `see:` は**リポジトリ相対パス** —— URL は `key:value` の規則に反する。
- **作成日は仕様上「任意」**。`add` は必ず付けるが、無い行を `check` は咎めない
  —— 手で書いた行を追い返す理由が仕様に無い。`id:` が無いのは咎める(CLI が
  触れなくなるため)が、**`todo id` で配れる**ので直し方は 1 コマンド。

完了行でも `id:` は残す —— 後続の `dep:` が「その id は done にあるか」で解決するため。
`done.txt` の行を消してよいのは、**その id を指す `dep:` がどこにも無いとき**だけ
(残っていれば `check` が宙吊りとして名指しする)。

### なぜ id は乱数で、連番ではないか

並行 worktree・別ブランチで足したタスクが同じ番号を取り、マージで衝突するから。
乱数なら採番に状態ファイルもカウンタも要らない。`add` は引いた id が
`todo.txt`/`done.txt` のどちらかに既にあれば引き直す。

## コマンド

```sh
todo add "text"          # 作成日と id: を付けて追記(+proj @ctx key:value は text にそのまま書く)
todo ready [TERM...]     # dep: が解けている open 行 = いま着手できる / 並列に投げられる
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

- **ID は一意なら前方一致でよい**(`todo do a3f`)。曖昧なら黙って選ばず落ちる。
- 対象は `$TODO_DIR/todo.txt` と `$TODO_DIR/done.txt`(既定は `.`)。
  環境変数名は todo.txt-cli と同じ `TODO_DIR`。
- 対話しない。データは stdout、診断は stderr。色は付けない(エージェントが読む前提)。
- 終了コード: **0** 成功 / **1** 引数・状態の誤り / **2** 形式違反(`check`、
  または書けば増やすので書かなかった)/ **3** ID が見つからない・曖昧。
- `do` / `start` / `stop` は冪等 —— 既に done、既に `@wip`、`@wip` が無い、は
  エラーではなく「何もしない」。**再実行を怖がらせない**(怖いと、状態が
  変わった瞬間に走らせる規律が最初に折れる)。

`bin/todo` は単一の POSIX sh + awk。bash 固有機能・python・jq に依存しない
—— Nix 環境の外や sandbox でも動く必要があるため。

置き場が `bin/` なのは、Claude Code がプラグインの `bin/` を Bash の PATH に
足すから —— skill から `todo ready` とだけ書ける。

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

## skills

| skill | いつ | 何を |
|---|---|---|
| `todo:todo` | セッション開始時と、タスクの状態が変わった**瞬間** | `ready` で「いま何が着手できるか」を見る。`start` / `stop` / `do` / `add` / `replace` をその場で走らせる。model-invocable |
| `todo:doctor` | 導入時と、`check` が何か言っているとき | 診断のみが既定。ファイル作成と `CLAUDE.md`/`AGENTS.md` への 1 行追記は**承認後** |

skill の `!` ブロックは `${CLAUDE_SKILL_DIR}/../../bin/todo` を直に呼ぶ。
PATH に `todo` があるならそれでよい(本文のコマンド表はそう書いてある)が、
**PATH 注入は未確認なので、必ず走る場所は確実な方に寄せている。**

形式の詳細は `skills/todo/references/format.md` の 1 箇所だけ(doctor もそこを指す)。
行が曖昧なとき・`check` の指摘が分からないときに読む。

## テスト

```sh
sh plugins/todo/tests/run.sh          # 単体
bash scripts/verify.sh                # pre-push と CI。[8/8] がこれを走らせる
```

`add` の採番・`do` の移動・`ready` の依存解決・`replace` の保持・`check` の各検出に加え、
**生成した `todo.txt` を todo.txt-cli の `todo.sh` に読ませる互換テスト**を含む
(自分の検査だけでは自作自演になる)。`todo.sh` が無い環境ではそのテストだけ skip する。
`TODO_SH` で場所を指定できる。日付は `TODO_TODAY`、採番は `TODO_FAKE_IDS` で固定する。
