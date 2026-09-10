# 2026-09-11 subagent の時間の内訳 —— esp32-airdrop-poc のセッションログ実測

対象は `~/.claude/projects/-Users-gigun-ghq-github-com-gigun-dev-esp32-airdrop-poc/` の
transcript。集計は `plugins/telemetry/bin/session-breakdown --since 1d`(窓は 2026-09-10
05:10 → 2026-09-11 05:10 JST)。窓に入った体は subagent 32 体と本線 1 セッション。

数え方は道具の出力の先頭に印字される。要点だけ再掲する。

- 実時間 = その体の transcript の最初と最後の message 行の timestamp の差。投げてから戻る
  までではない。subagent は background で起動するので、本線側の `Agent` の tool_result は
  起動の受領(2〜3 秒)であって完了ではない。
- Bash 所要 = tool_use 行と tool_result 行の timestamp の差。ツール結果に実行時間の
  フィールドは無いので、差以外に出せる値がない。権限待ちも同じ差に入る。
- ツール所要 = 全ツールの区間の和集合。1 応答が複数ツールを並列に呼ぶので単純合計は使えない。
- モデル応答ほか = 実時間 − ツール所要。生成時間と、ログから分離できない待ちが混ざる。

## 律速はモデルの応答で、検証ではない

| | 合計 | 実時間比 |
|---|---|---|
| 実時間(32 体) | 552.4 分 | 100% |
| ツール所要(和集合) | 172.2 分 | 31% |
| モデル応答ほか | 380.3 分 | 69% |
| うち Bash | 164.2 分 | 30% |
| うち検証(test+build) | 96.0 分 | 17% |
| 検証+背景待ちのポーリング | 119.3 分 | 22% |

本線の見立ては「ツール数が 3 倍違うのに実時間が揃うので、律速は検証」だった。実時間と
ツール数は本線の手勘定と一致する(29.9 / 11.1 / 9.6 / 10.9 分、125 / 89 / 39 / 61 回)が、
内訳は違う。検証は 4 体で 38% / 31% / 43% / 33%、32 体の中央値では 9% にとどまる。残りの
2/3 はモデルの応答である。

体ごとのばらつきも大きい。Bash が実時間に占める割合は最小 0%・中央 23%・最大 77%。検証を
1 秒も走らせない体が 32 体中 6 体ある(`Explore` ×2 / `architect` ×2 / `codex-rescue` /
`general-purpose`)。

分布の両端:

- 外れ値。`Extend the observer to record a real Upload` は 60.4 分で Bash 46.8 分(77%)。
  `sh tools/test.sh` を 13 回走らせ、うち 764 秒・520 秒・309 秒・201 秒。ここだけは検証が
  律速だった。
- 定常。`Remove the send loop's fixed sleep ceiling` は 30.0 分で Bash 3.6 分(12%)、
  Bash 77 回の大半が 1 秒未満。この形が中央値に近い。
- 「普通に見える 10 分」。`Make the DVZIP block size selectable` は 9.6 分・ツール 39 回で、
  内訳は検証 4.2 分(43%)+ モデル 5.3 分。ツール数が少ないのは無駄が無いからではなく、
  1 回の検証が重いからである。

## test.sh は 100 秒ではないし、build は 3〜5 分ではない

`sh tools/test.sh` は窓内で 63 回。単独で走ったとき中央値 50 秒、他の `test.sh` と時間が
重なったとき中央値 94 秒、最大 764 秒。長い側の 3 件はいずれも `exit=1` で、失敗した回が
長い。並列に投げた subagent が同じホストテストを取り合っている。

前景の `bash tools/idf-board.sh <board> build` は 65 回で中央値 16 秒、最大 105 秒。3 分を
超えた回は 0。CLAUDE.md と本線の見立てにある「3〜5 分」は、この窓の実測には無い(おそらく
クリーンビルドの値だが、ログからは確かめられない)。

同一コマンドの再実行は 31 回。`sh tools/test.sh` を 1 体で 3 回走らせた例が 2 体ある。

背景実行のポーリング(`until grep -q ... done`)が 48 回・23.4 分。中身はすべて背景に投げた
test / build のログ待ちなので、検証の実体は 22% と読むのが正しい。ポーリング自体は最長
180.8 秒の 1 回を含む。

## 目的を達したあとの尾

最後の `Edit`/`Write` から終了までの時間は、書いた体 24 体で最小 1%・中央 20%・最大 62%。
上位は `Derive verify.sh numbering`(2.6 分 / 4.2 分 = 62%)、`Make the DVZIP block size
selectable`(5.0 分 / 9.6 分 = 52%)、`Add a source line command`(4.6 分 / 10.9 分 = 42%)。

**この尾が無駄かどうかはログからは決まらない。** 最終確認・コミット・報告の作成が入る区間
でもある。言えるのは「編集は前半で終わっており、後半は検証と報告に使われている」ところまで。

## worktree —— 隔離されていない書き込みが 8 件

窓内で worktree を割り当てられて起動した体は 24/32。cwd はいずれも 100% worktree の中に
とどまっていた(例: 254/254 行)。壊れているのは cwd ではなく書き込み先である。

worktree を持つ体が worktree の外へ書いた `Edit`/`Write`:

| 時刻(JST) | 体 | 書いた先 |
|---|---|---|
| 09-10 04:14:49 | Harden benchmark wrappers | `tools/lib/preflight.sh` |
| 09-10 21:57:59 | Add heap instrument and bound check | `main/tls_heap_trace.h` |
| 09-11 01:38:51 | Extend the observer to record a real Upload | `tools/observe-airdrop-receiver.py` |
| 09-11 01:47:05 | Make the fixed TX rate default | `sdkconfig.defaults` |
| 09-11 02:17:30 | Cut the serial log volume | `main/seen_sample.h` |
| 09-11 03:42:41 | Fix benchmark guard and boot config line | `tools/lib/gitignore_guard.py` |
| 09-11 04:10:35 | Make the DVZIP block size selectable | `main/Kconfig.projbuild` |
| 09-11 04:53:50 | Remove the send loop's fixed sleep ceiling | `main/send_spin.h` |

いずれも `/Users/gigun/ghq/github.com/gigun-dev/esp32-airdrop-poc/` の本体チェックアウト、
つまり本線がファームウェアをビルドして実機に焼くツリーである。ファームウェアのヘッダと
`sdkconfig.defaults` が含まれる。1 体あたり 1 件で、絶対パスを組み立てるときに worktree の
接頭辞が落ちている形。

もう 1 つの形は repo をまたぐ場合である。esp32 のセッションから起動した体が
`plugins/todo/bin/todo` や `scripts/verify.sh` を編集しており、窓内で 13 ファイル・71 回。worktree は
セッションの repo(esp32)の下に作られるのに、仕事の対象は claude-code だった。この場合
worktree は 1 度も使われず、編集はすべて claude-code の本体チェックアウトに直接入る。

同じツリーを時間的に重ねて触った組は 8 組。すべて本線 × worktree 無しの subagent で、重なり
最大 29.5 分。worktree を持たない体(調査系)は本体チェックアウトで走るので、本線と同時に
同じツリーを触る。今日は本線がこのツリーの変更を見て「別のエージェントが触っている」と
判断できず、無関係の subagent に問い合わせている。

**後片付けはログの範囲外。** 実測すると `.claude/worktrees/` は 44 個・20 GB、日付は
09-08 が 11 個、09-09 が 8 個、09-10 が 16 個、09-11 が 9 個。4 日分が 1 つも消えていない。
`cleanupPeriodDays` は local のセッションログを残すため 9999 固定という確約があるので、
自動掃除は原理的に発火しない。掃除の口は dotfiles の `claude/commands/worktree-sweep.md`
にあるが、手で叩くコマンドである。

## ハーネスは効いているか

このセッションの subagent 41 体(窓より広い、セッションの全期間)での発火:

| | 体数 |
|---|---|
| `git commit` した | 30/41 |
| リポジトリの `CLAUDE.md` を読んだ | 20/41 |
| `.claude/rules/comments.md` を読んだ | 9/41 |
| todo CLI を叩いた | 7/41 |
| adr CLI を叩いた | 6/41 |
| `git push` した | 3/41 |

指示ファイルは半分の体にしか読まれていない。todo は 7 体。本線が今日起票した
`id:0028`(投げる前に本線が start を打つ)と `id:0030`(worktree の subagent の todo 更新が
マージまで届かない)は、この数字と整合する。

起動時の文脈量(最初のリクエストの input+cache)は中央値 11,391 トークン、最大 34,792。
常時コストとしては小さく、ここは問題ではない。

## 本線の手勘定との食い違い

| | 本線 | 実測 |
|---|---|---|
| 実時間 4 体 | 29.9 / 11.1 / 9.6 / 10.9 分 | 一致 |
| ツール呼び出し | 125 / 89 / 39 / 61 | 一致 |
| トークン | 219,685 / 143,204 / 170,498 / 127,905 | 216,284 / 143,463 / 169,378 / 125,359 |
| 律速 | 検証 | 検証は 31〜43%、32 体の中央値は 9%。残り 2/3 はモデルの応答 |
| test.sh | 約 100 秒 | 単独 中央 50 秒 / 重なり時 中央 94 秒 / 最大 764 秒 |
| build | 3〜5 分 | 中央 16 秒 / 最大 105 秒、3 分超は 0 回 |
| worktree | 43 個・19 GB | 44 個・20 GB(セッション中に 1 個増えた) |

トークンの数字は 1〜2% 差で、実測の **peak(1 リクエストの文脈最大長)** と一致する。本線が
数えていたのは文脈の大きさであって、消費したトークンではない。累積は 1 桁違う。同じ 4 体の
cache read は 23,502,933 / 10,096,287 / 7,495,084 / 9,415,043 で、cum output は
38,850 / 22,381 / 24,540 / 23,913。

## ログから答えられなかったこと

- モデルの生成時間と、その裏で起きた待ちの切り分け。行が立つのは応答の完了時だけなので、
  「モデル応答ほか」380.3 分の中身は分けられない。
- 「文脈がうまく伝わっていなくて何かに引っかかった」かどうか。retry も stall もログに印が
  無い。手掛かりになるのは同一コマンドの再実行(31 回)と失敗した test.sh の所要だけで、
  引っかかりの証拠としては弱い。
- 「既に目的が達成されているのに続けていた」かどうか。最後の編集からの尾(中央 20%)は
  代理指標であって、達成の判定ではない。
- subagent を投げてから起動するまでの遅延。background 起動なので測る 2 点が無い。
- worktree が後片付けされたかどうか。ログは実行時の姿しか持たない。実測は上に書いた。
- 今日 esp32 の本体ツリーを 05:04 に触っていた別セッションの正体。`ListAgents` は一覧が
  切れており、この projects ディレクトリの transcript にも該当する体はいない。
