# Hallmark

新規画面の設計、既存画面の監査・再設計、参考デザインの分析を行うスキル。Claude Code と Codex は同じ `skills/hallmark/SKILL.md` と参照資料を使用する。

## 導入

既存の gigun marketplace を登録した環境で、使用するホストに追加する。

```sh
claude plugin install hallmark@gigun
codex plugin add hallmark@gigun
```

利用例は `hallmark audit <対象>`、`hallmark redesign <対象>`、`hallmark study <URLまたは画像>`。スキルの本文は [SKILL.md](skills/hallmark/SKILL.md)。監査は変更を行わず、再設計は明示された実装範囲を維持する。

## 配布と更新

[Nutlope/hallmark](https://github.com/Nutlope/hallmark) v1.1.0 の本文・全参照資料・site・docs を同梱する。固定commitとローカルの相対リンク調整は [UPSTREAM.md](UPSTREAM.md)、利用条件は [LICENSE](LICENSE) を参照。本文をホストごとに複製しない。hooks、MCPサーバー、導入時の外部通信を追加しない。

更新時は固定した上流の配布物を入れ替え、UPSTREAMを更新する。Claude manifestを変更したらrepoルートから `python3 scripts/generate_manifests.py --write` でCodexの共通metadataとmarketplaceを生成する。Codexのskills登録とinterfaceは手で保持する。

```sh
python3 -m unittest discover -s plugins/hallmark/tests -v
python3 scripts/generate_manifests.py --check
claude plugin validate plugins/hallmark
bash scripts/verify.sh
```

これらは配布形・同梱参照・登録の検証。実ホストへのインストール、有効化、デザイン品質の評価は別の受入である。
