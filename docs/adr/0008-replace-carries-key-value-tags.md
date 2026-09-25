# `replace` は key:value タグを持ち越す

Date: 2026-09-10
Implementation: done

`replace` は本文だけ書き換えてタグを捨てており、言い直すたびに `dep:` が誰にも告げられず消えていた。todo.txt の仕様上 `key:value` は本文と別物なので、`replace` はタグをすべて持ち越し、外すのは操作者が key を書いたとき(上書きか `--drop KEY`)だけにする。この規則は各リポジトリの行の形を決めるので、後から戻すと前提が壊れる。

Rejected: `dep:` があるのに新しい本文に無ければ拒む — `see:` など他のタグに一般化できず、同じ根から次の症状が出る
Rejected: タグを行の元の位置に保つ — 本文を置き換える以上、位置は復元できない
Rejected: `+project` と `@context` も持ち越す — 仕様がこの 2 つを本文の一部と定めている
