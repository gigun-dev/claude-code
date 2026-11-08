# Emil Skills

Emil Kowalski の UI デザイン、アニメーション、プロトタイピング、UI の検証に関するスキルをまとめたプラグイン。Claude Code と Codex で同じスキル本文を使う。

## 導入

この marketplace を登録済みの環境で、使用するホストにインストールする。

```sh
claude plugin install emil@gigun
codex plugin add emil@gigun
```

例えば `emil-design-eng` は UI の仕上げ、`break-ui` は長い文字列などの境界条件の検証に使える。他のスキルは [skills/](skills/) を参照。

## 配布と更新

上流の skills ディレクトリと MIT ライセンスを同梱する。固定コミットは [UPSTREAM.md](UPSTREAM.md) を参照。プラグインのバージョンは、このリポジトリでの配布版を表す。更新時は上流との差分を確認して同梱物と固定コミットを更新する。

マニフェストを変更したら、リポジトリのルートで `python3 scripts/generate_manifests.py --write` を実行する。生成物の整合性、ホストでの読み込み、スキル本文の参照先を確認する。
