# 外部プラグインは上流の公開配布元を参照して配布する

Date: 2026-11-12
Implementation: done

上流リポジトリが管理する外部プラグインを自リポジトリへ複製すると、上流の更新追従や差分管理の負担が常時発生する。Claude Code と Codex のマーケットプレイスは、いずれも外部 Git URL と npm パッケージを source として参照でき、各ホストの更新機能で追従できる。

独自実装のプラグインや単体スニペットを除き、上流がプラグイン定義を持つサードパーティ製プラグインは plugins ディレクトリへ実体を置かず、上流が配布に使っている形のまま marketplace.json の source として登録する。Git で配布するものは url か git-subdir、ビルド済み runtime を npm パッケージで配布するものは npm を使う。npm source にはバージョンを書かず、Git source が ref に main を指すのと同じく、更新は各ホストのプラグイン更新機能に委ねる。

Accepting: オフライン時に初回のプラグイン取得ができず、上流の可用性と公開物の中身に依存する
Accepting: npm source はバージョンを固定しないため、上流の新しいリリースが検証なしで入る
Rejected: 上流コードを plugins に vendor 複製する — 追従の手間と自リポジトリの肥大化を避けるため
Rejected: npm 配布のプラグインを Git source で参照する — ビルド成果物が Git に無く、clean checkout では起動できないため
Rejected: npm source のバージョンを固定する — 上流リリースのたびに手で更新する作業が生じ、Git source の扱いとも揃わないため

Replaces: 0002
