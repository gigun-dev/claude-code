# 外部プラグインは上流を参照し、版は marketplace に固定する

Date: 2026-11-13
Implementation: done

上流リポジトリが管理する外部プラグインを自リポジトリへ複製すると、上流の更新追従や差分管理の負担が常時発生する。Claude Code と Codex のマーケットプレイスは、いずれも外部 Git URL と npm パッケージを source として参照できる。ただし版を書かずに参照すると、入る版が導入した時刻と host の環境で決まる。npm は実行中の Node が満たす最新版を選ぶため、Node が古い host には plugin 定義を持たない旧版が黙って入った。

独自実装のプラグインや単体スニペットを除き、上流がプラグイン定義を持つサードパーティ製プラグインは plugins ディレクトリへ実体を置かず、上流が配布に使っている形のまま marketplace.json の source として登録する。Git で配布するものは url か git-subdir、ビルド済み runtime を npm パッケージで配布するものは npm を使う。どの source にも版を固定して書く。npm は正確な version、Git は ref に加えて commit の sha である。

固定した版は週次の workflow が動かし、その PR は自動で merge する。差分を人が読まない代わりに、公開から一定の日数を経た版だけを採り、npm は両 host の plugin 定義を同じ版で含むものだけを採る。

Accepting: オフライン時に初回のプラグイン取得ができず、上流の可用性と公開物の中身に依存する
Accepting: 上流の新しい版は、最小経過日数と週次の実行を待ってから届く
Accepting: 自動 merge のため、経過日数のうちに上流で発覚しなかった不具合や改ざんはそのまま入る
Rejected: 上流コードを plugins に vendor 複製する — 追従の手間と自リポジトリの肥大化を避けるため
Rejected: npm 配布のプラグインを Git source で参照する — ビルド成果物が Git に無く、clean checkout では起動できないため
Rejected: 版を書かず更新を各 host の更新機能に委ねる — 入る版が host の Node と導入時刻で変わり、同じ marketplace から違う中身が入るため
Rejected: 版を動かす PR を人が merge する — merge の手間が毎週増えるため

Replaces: 0003
