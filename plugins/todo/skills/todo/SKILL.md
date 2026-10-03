---
name: todo
description: >-
  Track repository work in todo.txt and done.txt. Use when starting or updating
  work, or answering progress, remaining-task, and who-is-waiting questions —
  even without "todo". Also on '/todo:todo'.
metadata:
  version: "0.3.0"
---

このスキルのディレクトリから `../../bin/todo` の絶対パスを求め、対象リポジトリのルートで `ready` を実行する。以下の `todo` は、その同梱 CLI を引用符で囲んだ絶対パスで呼ぶことを指す。作業ディレクトリは対象リポジトリに保つ。

`ready` は依存の解けた未完一覧。進捗確認では `todo.txt` と `done.txt` も読み、依存待ちを落とさない。先頭の決定索引に該当する領域を変更するときは ADR 本文を読む。`✗` は形式違反。

行の読み方は todo.txt の仕様どおりで、`(A)` から `(Z)` が重要度（行頭のみ。進行中の意味は持たない）、その次が作成日、`+project` が束ね、`@context` がその作業に要る状況（`@device` `@user` `@unattended`）。このプラグインはそこに四つを足している。

| 記法 | 意味 |
|---|---|
| `@wip` | 進行中。`start` が付け、`stop` と `do` が外す。見るのは `ls @wip` |
| `@dropped` | 前提が崩れて閉じた印。`drop` が理由とともに付ける。`do`（完了）と読み分けるためのもので、後ろに理由がそのまま続く |
| `dep:0001` | 依存。カンマ区切りで複数可。依存先が done.txt に入るまでその行は `ready` に出ない。存在しない id を指すと永久に出ないので、`check` がその行を名指しする。足し外しは `dep` / `undep` で、外す先は必ず名指しする |
| `see:docs/x.md` | 根拠の置き場。リポジトリ相対パスに限る。URL は value に二つ目のコロンが入るため形式違反になる。語の末尾のコロン（「原因ではない:」）は値が空で key:value ではないため、散文として通る |
| `id:0001` | `add` が付ける連番。4 桁ゼロ詰め、done.txt も含めた最大値に 1 を足す。タスクを指す唯一の手段で、行番号は編集とマージでずれるので使わない。指すときのゼロ詰めは省略できる（`todo do 12`）。手で足した行には `todo id` が配る。本文に書けるのは散文としての `id:` までで、`id:0001` の形は `add` が拒む |

`key:value` の形をしたトークンが**タグ**で、`replace` はタグをまとめて引き継ぐ（本文とみなすのは `+project` と `@context` まで）。外すのは、新しい本文に同じ key を書いて上書きするか、`--drop <key>` で名指しするかのどちらか。書かずに外れることはなく、外れた key は stderr に出る。

報告はユーザーが困っていることを先に置き、対応・検証済みの範囲・残りを伝える。本人の判断待ちとエージェントが進められる作業を区別し、タスクは id だけでなく内容で示す。

`ls` と `ready` は重要度の順に並び、同じ重要度の中はファイルに書かれた順になる。行が仕様上どう読まれるか分からないときだけ `references/todo-txt-format.md`（上流の仕様そのまま）を読む。

```sh
todo ready              # 着手できるもの        todo ls @wip     # 手を付けているもの
todo ls +project        # その塊の残り          todo show <id>   # done も含めて 1 行
todo start <id>         # 着手した              todo stop <id>   # 未完のまま置いた
todo do <id>            # 検証まで終わった      todo add "<次の一手>"
todo drop <id> "<理由>" # 前提が崩れて問いが消えた（比較する対象が無い、原因が再現しない、その経路が無い）
todo replace <id> "…"   # 言い方・粒度を直す    todo pri <id> A / todo depri <id>
todo dep <id> <dep-id>  # 依存を足す            todo undep <id> <dep-id>
todo projects           # 束ごとの件数（断片化）
```

`todo --help` が正で、終了コードは 0 成功、1 引数や状態の誤り、2 形式違反、3 ID 不明。

todo.txt / done.txt は本線で更新し、worktree 側は変更内容を親へ伝える。`start` / `stop` / `do` / `replace` は状態が変わったときに実行する。`do` は完了条件を検証したもの、`drop` は前提が崩れたもの。変更前の記述は `replace` の stderr と Git 履歴で辿れる。

一行は終わりを確認できる次の一手にする。大きすぎれば分割する。知識は専門 docs、経緯はコミットメッセージへ残す。

`todo.txt` が無ければ未導入と伝える。空の一覧を「仕事が無い」と解釈せず、導入を求められた場合は隣の `../doctor/SKILL.md` を読む。
