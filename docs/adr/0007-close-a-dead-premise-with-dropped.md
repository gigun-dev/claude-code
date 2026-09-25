# 前提が崩れた行は `do` ではなく `@dropped` で閉じる

Date: 2026-09-10
Implementation: done

「前提が間違っていた」が最も多い結末の一つなのに、出口は `do` しか無く、やっていない仕事が `done.txt` に完了として並んでいた。`drop ID "理由"` を足し、完了行に `@dropped <理由>` を付けて閉じる(理由は必須。書式は増やさない)。drop は `dep:` も解く —— 前提が死んだ依存先を人の前に戻すため。

Rejected: 理由を任意にする — `do` と区別が付かない
Rejected: `done.txt` とは別のファイルに落とす — 保管場所は todo.txt と done.txt の 2 つだけ、という約束を崩す
Rejected: 行に過去の文面を溜める — todo.txt に腐る散文を持たない、に反する。`replace` は消す前の行を stderr に出すだけにして、残したい経緯はコミットメッセージへ移す
