# todo.txt の id は連番にする

Date: 2026-09-10
Implementation: done

並行 worktree での採番衝突を避けるため乱数 id(6 桁 16 進)を一度実装した。

todo.txt を書くのは本線だけで、worktree の implementer は報告するだけと運用を決めたので、書き手は一つになり連番で足りる。人が読めて短く指せ、`0012` のような 4 桁ゼロ詰めで ADR の番号と揃う。

Accepting: 書き手が本線 1 つであることに依存する(worktree の implementer が直接書くようになれば連番は衝突する)
