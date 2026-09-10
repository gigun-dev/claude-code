---
name: todo
description: >-
  Manage repository tasks in todo.txt: read ready work at the start of work in a
  repository, and update tasks whenever one starts, finishes, splits, or changes —
  including when the user never says "todo". Tasks live in this repository's todo.txt
  and done.txt, driven by the `todo` CLI. Also on '/todo:todo'.
metadata:
  version: "0.1.5"
---

このスキルのディレクトリから `../../bin/todo` を絶対パスに解決し、対象リポジトリのルートで `ready` を実行する。以下の `todo` は、その同梱 CLI を引用符で囲んだ絶対パスで呼ぶことを指す。作業ディレクトリは対象リポジトリに保つ。

`ready` に並ぶのが、依存の解けた open な行、つまりいま着手できるものだ。並列に投げられるのもこの中から選ぶ。行の手前に決定の索引（`docs/adr/` にある題の一覧）が出ることがある。触れる領域がそこに当たるなら、従うか、新しい ADR で覆すことを提案する。題だけなので、当たるものがあれば本体を読む。`✗` が出ていればファイルが壊れているので、一覧を読む前にそれを直す。

行の読み方は todo.txt の仕様のとおりで、`(A)` から `(Z)` が重要度（行頭のみ。進行中の意味は持たない）、その次が作成日、`+project` が束ね、`@context` がその作業に要る状況（`@device` `@user` `@unattended`）。このプラグインはそこに四つを足している。

| 記法 | 意味 |
|---|---|
| `@wip` | 進行中。`start` が付け、`stop` と `do` が外す。見るのは `ls @wip` |
| `@dropped` | 前提が崩れて閉じた印。`drop` が理由とともに付ける。`do`（やった）と読み分けるためのもので、後ろに理由がそのまま続く |
| `dep:0001` | 依存。カンマ区切りで複数可。指す先が done.txt に入るまでその行は `ready` に出ない。存在しない id を指すと永久に出ないので、`check` がその行を名指しする |
| `see:docs/x.md` | 根拠の置き場。リポジトリ相対パスに限る。URL は value にコロンが二つ目に入るので形式違反になる。語の末尾のコロン（「原因ではない:」）は値が空で key:value ではないため、散文として通る |
| `id:0001` | `add` が付ける連番。4 桁ゼロ詰め、done.txt も数えた最大値に 1 を足す。タスクを指す唯一の手段で、行番号は編集とマージでずれるので使わない。指すときのゼロ詰めは省略できる（`todo do 12`）。手で足した行には `todo id` が配る |

タスクに言及するときは id だけで済ませず、「main.c の送信経路の切り出し（`id:0007`）」のように中身を先に置く。読む側が todo.txt を開いているとは限らず、`id:0007` とだけ言われるとそのたびに引きに行くことになる。一覧をそのまま貼るときは別で、そこは id が並んでいてよい。

`ls` と `ready` は重要度の順に並び、同じ重要度の中はファイルに書かれた順になる。行が仕様上どう読まれるか分からないときだけ `references/todo-txt-format.md`（上流の仕様そのまま）を読む。

```sh
todo ready              # 着手できるもの        todo ls @wip     # 手を付けているもの
todo ls +project        # その塊の残り          todo show <id>   # done も含めて 1 行
todo start <id>         # 着手した              todo stop <id>   # 未完のまま置いた
todo do <id>            # 検証まで終わった      todo add "<次の一手>"
todo drop <id> "<理由>" # 前提が崩れて問いが消えた（比較する対象が無い、原因が再現しない、その経路が無い）
todo replace <id> "…"   # 言い方・粒度を直す    todo pri <id> A / todo depri <id>
todo projects           # 束ごとの件数（断片化）
```

`todo --help` が正で、終了コードは 0 成功、1 引数や状態の誤り、2 形式違反、3 ID 不明。

todo.txt を更新するのは本線で、worktree で実装する側は結果を報告するだけにする。`do` は完了条件を検証した時点で打つ。やっていないものに `do` を打たない —— 前提が崩れて問いごと消えたなら `drop` で、理由は自分の言葉で書く。`replace` は前の言い方を消すので、消す前の行が stderr に出る。残す値打ちがあればそこからコミットメッセージか docs へ写す。タスクの更新だけを理由にコミット・push しない。それ以外のコマンドは、状態が変わったその瞬間に走らせる。コミットの区切りまで溜めない。

一行に書くのは、終わったと言える具体的な次の一手だけにする。終わりを言えないなら割る。学んだことや経緯は書かず、docs とコミットメッセージに回す（`drop` の理由は例外で、閉じた行にだけ残る）。todo.txt が持つのはこれからやることだけで、行を直接編集してもよく、壊れていれば次の `ls` か `ready` が教える。

`todo.txt` が無ければ未導入と伝える。空の一覧を「仕事が無い」と解釈せず、導入を求められた場合は隣の `../doctor/SKILL.md` を読む。
