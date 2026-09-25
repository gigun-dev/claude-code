# todo と adr のプラグインは hook を持たない

Date: 2026-09-10
Implementation: done

hook は常時のコストと harness 依存を増やし、呼ばれない場所では黙って死ぬ(利用者の裁定)。代わりに CLI が書く前に検査し、`ls` と `ready` が読むたびに結果を出す。高くつく検査が出てきたときだけ hook を検討する。
