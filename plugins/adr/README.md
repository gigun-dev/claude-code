# adr — 決めたことを 1 決定 1 ファイルで持つ

Architecture Decision Record を、エージェントが書く前提で運ぶプラグイン。守るのは 2 つ:

- **書式も採否の基準も自作しない。** [mattpocock/skills](https://github.com/mattpocock/skills)
  の `ADR-FORMAT.md` を**逐語で** vendor してある(MIT。同じディレクトリの
  `LICENSE-mattpocock-skills` がそのライセンス)。置き場は
  `skills/adr/references/ADR-FORMAT.md`。**編集しない** —— 更新は上流から取り直す。
- **書く前に読む。** ADR の一番の値打ちは「もう決まっている」を先に知ること。
  skill は起動時に `adr ls` を走らせ、既存の決定を目の前に置く。

書くのはエージェントで、CLI は一覧と検査だけを持つ。雛形を吐くコマンドは置かない
—— 埋める欄があると、埋めるために創作が始まる。

## ファイルの形

```
docs/adr/0003-use-manual-sql-instead-of-an-orm.md

  # Use manual SQL instead of an ORM

  2026-09-10 に決めた。<何が文脈で、何を決めて、なぜか。1〜3 文>
```

- ファイル名は `NNNN-<小文字ケバブの slug>.md`。番号は 4 桁で、既存の最大値 + 1
  (`adr ls` の一番下が最大値)。**採番後に改名しない。**
- 日付は `YYYY-MM-DD`。書き出しの文の中か、`Date:` の 1 行。
- `Status:` / Considered Options / Consequences は**値打ちがあるときだけ**。
  ほとんどの ADR は題 + 1 段落で終わる。
- **受理済みの ADR は編集しない。**差し替えは新しいファイルに書き、その中で古い方を
  名指しする。古い方に許される編集は先頭行 `Superseded by <slug>` だけ。

三重関門(覆すのが高い / 文脈が無いと驚く / 本物の取引の結果)と「何が該当するか」は
上流の `ADR-FORMAT.md` が正。**ここには複製しない**(複製すると必ずドリフトする)。

## コマンド

```sh
adr ls        # <date> <slug> <status> <title> を番号順に 1 行 1 件
adr check     # 書式検査。指摘があれば stdout に出して 2 で終わる
```

**インターフェイスの正は `adr --help`。**ここは索引で、食い違ったら `--help` が正しい。

- 対象は `$ADR_DIR`。未指定なら `docs/adr` → `docs/decisions` → `adr` →
  `decisions` の順に最初に見つかったもの。どれも無ければ何もせず 0 で終わる。
- `check` が見るのは、ファイル名 / 番号の重複 / 題 / 日付 / `Superseded by` の
  指す先の実在 / `Status:` の語彙。**改名も書き換えもしない** —— 番号が重複していても
  指摘だけを出す(上流が「改名しない」と言う以上、直すのは人の判断)。
- `Superseded by` があり `Status:` が無ければ、`ls` の status は `superseded`。
- 対話しない。データは stdout、診断は stderr。終了コード: **0** 成功 /
  **1** 引数・状態の誤り / **2** `check` が指摘を出した。

`bin/adr` は単一の POSIX sh + awk。bash 固有機能・python・jq に依存しない
—— Nix 環境の外や sandbox でも動く必要があるため。置き場が `bin/` なのは、
Claude Code がプラグインの `bin/` を Bash の PATH に足すから。

フックは置かない —— 呼ばれる保証の無い場所へ検査を置くと、検査が黙って死ぬ。

## skills

| skill | いつ | 何を |
|---|---|---|
| `adr:adr` | 覆しにくい決定が下りた**瞬間**、利用者が裁定したとき、測定が案を否定したとき、「なぜこうなっている」と訊かれたとき、既に決まっていそうな領域へ変更を提案する前 | `ls` で既存の決定を見て、三重関門にかけ、通れば節ごとに合意しながら書く。落ちれば勧退してコミットメッセージを勧める。model-invocable |

決定が仕事を生んだら、その仕事は ADR ではなく `todo` の 1 行にする
(`see:docs/adr/<slug>.md` で根拠を指す)。

## テスト

```sh
sh plugins/adr/tests/run.sh          # 単体
bash scripts/verify.sh               # pre-push と CI。[9/9] がこれを走らせる
```

`ls` の並び(番号順であって日付順でも文字列順でもない)・status の 4 つの出どころ・
`check` の各指摘・ディレクトリの探索順・`ADR_DIR` の上書きを見る。
