# ios-simulator スキルの eval

このディレクトリは `ios-simulator` スキルの評価基盤。**`skill-creator` スキルのスクリプトで回す前提**で
組んである(自前のランナーは書いていない)。

> ⚠️ **このスキルの eval は他のスキルと決定的に違う点が3つある。読まずに走らせないこと。**
> 1. **1本あたり 50〜60 分・20〜26 万トークン**(iteration-1 実測)。気軽に回せない。
> 2. **副作用がある。** Simulator 端末を作る/起動する、Keychain に CA を入れる、
>    ホストのプロキシ設定を触る、本番 CalDAV サーバーに書き込む。
> 3. **並列に回せない。** 端末を分けても、システムプロキシ・SimRenderServer・ペーストボードは
>    ホスト単位の共有資源。詳細は下の「並列実行の禁止」。

---

## 📌 最初に読むもの

**`METHODOLOGY.md`** —— スキルを測るときの作法。**ios-simulator 固有ではなく、どのスキルにも効く。**
25 run の過程で**自分の結論を15回訂正した**経験から、一般化できるものだけを抜いた
(A/B は欠陥を見つけるために取る / 事前登録の閾値は到達可能性を先に確認 / 打ち切り条件も宣言 /
ノイズと決める前に層別 / 答えではなく観点を書く / 物差しを動かさない / 自己申告は数値でも裏取り /
計測ツールの癖 / 編集の反映を先に確認 / 環境が答えを持つと知識は差を生まない)。

**`BENCHMARK.md`** —— 結果。能力の集計(全ドメイン)と A/B(スキルの寄与)を**分けて**載せている。

**`NOTES.md`** —— 時系列の作業記録。長いので、上2つで足りなければ該当節だけ読む。

## ファイルの役割

| ファイル | 何か | 誰が読むか |
|---|---|---|
| `evals.json` | 出力品質 eval のテストケース定義(6本)。**人が手で書く唯一のファイル** | 人・実行エージェント |
| `trigger_queries.json` | description のトリガー eval 用の20クエリ。**`run_loop.py --eval-set` に渡す正本** | `scripts/run_loop.py` |
| `train_queries.json` / `validation_queries.json` | 上を 60/40 に割ったもの。**`run_loop.py` は自分で分割するのでツールには渡さない**(下記) | 人(手動確認用) |
| `iteration-N/` | 実行結果のワークスペース | `aggregate_benchmark.py` / `generate_review.py` |
| `NOTES.md` | 基盤を作りながらの所見(description / SKILL.md の改善候補、運用上の障害) | 人 |

### `iteration-N/` の構造(`skill-creator` の実装が要求する形)

```
iteration-1/
├── eval-demo-video/
│   ├── eval_metadata.json              ← aggregate_benchmark.py が読む位置
│   └── with_skill/
│       └── run-1/                      ← ★ run-N/ 階層は必須
│           ├── eval_metadata.json      ← generate_review.py が読む位置(親か自分だけを見る)
│           ├── timing.json
│           ├── grading.json
│           ├── transcript.md           ← iteration-2 から必須(下記)
│           └── outputs/
├── eval-caldav-account-sync/ …
├── benchmark.json
└── benchmark.md
```

---

## ⚠️ 公式ドキュメントと `skill-creator` 実装の食い違い(実装に合わせてある)

`docs/skill-creation/evaluating-skills.mdx` の例をそのまま写すと、**スクリプトが値を読めない**。
以下は実装(`scripts/aggregate_benchmark.py` / `eval-viewer/generate_review.py` /
`references/schemas.md` / `agents/grader.md`)を読んで確認した差分。

| 項目 | 公式ドキュメント | 実装(こちらが正) |
|---|---|---|
| grading.json の配列キー | `assertion_results` | **`expectations`**(`text` / `passed` / `evidence`) |
| evals.json の項目名 | `assertions` | **`expectations`**(schemas.md)。`skill-creator/SKILL.md` 本文は `assertions` と書いており内部でも不一致 |
| eval の `id` | 数値 | 数値。ただしディレクトリ名は `eval-<説明的な名前>` にする(glob は `eval-*`) |
| run ディレクトリ | `with_skill/` 直下に成果物 | **`with_skill/run-N/` 階層が必須。** `run-*` が無い config ディレクトリは丸ごと無視される |
| timing.json | `total_tokens` / `duration_ms` | 左記 **+ `total_duration_seconds`**(aggregate はこれを読む。ミリ秒は読まない) |
| ワークスペースの位置 | `<skill>-workspace/` を skill と兄弟に置く | 引数でディレクトリを渡す実装なのでどこでもよい。**ここでは `evals/iteration-N/` に置いた**(スキルと eval を1つのディレクトリで持ち運べる方が、プラグインとして配布するときに都合がよい) |

### 罠1: `grading.json` に `timing` を書くとトークン数が 0 になる

`aggregate_benchmark.py` は「`grading.json` の `timing.total_duration_seconds` が 0 のときだけ」
`timing.json` を読みに行き、**`tokens` はその分岐でしか代入されない**。
つまり `grading.json` に `timing` を書くと `timing.json` が読まれず、トークンが 0 になる。
→ **時間もトークンも `timing.json` に一本化し、`grading.json` には `timing` を書かない。**

### 罠2: baseline が無いと `delta` が嘘になる

config が1つしか無いと baseline を空辞書として扱い、`delta = with_skill - 0` を出す。
iteration-1 の `benchmark.md` は `Config B 0% / Delta +0.32` と生成された。これは
**「スキル無しなら全部 FAIL する」という未検証の主張**なので、N/A に潰してある。
**`without_skill` が揃うまでは、`aggregate_benchmark.py` を回すたびに手で潰すこと**
(`benchmark.json` の `run_summary.delta` と `benchmark.md` の Summary 表)。

### 罠3: `eval_metadata.json` は2箇所に要る

`aggregate_benchmark.py` は `eval-X/eval_metadata.json` を、
`generate_review.py` は `run_dir` かその **親** の `eval_metadata.json` しか見ない
(`eval-X/with_skill/run-1` の親は `with_skill` なので、eval 直下には届かない)。
→ **同じ内容を eval 直下と `run-N/` の両方に置く。**

---

## 出力品質 eval の回し方

`skill-creator` の「Running and evaluating test cases」に従う。
スクリプトはすべて **skill-creator のディレクトリから `python -m scripts.<name>` で** 実行する。

```bash
# プラグインキャッシュのパス。バージョンが変わると動くので毎回 find で解決すること
SC=$(find ~/.claude/plugins/cache -type d -name skill-creator -path '*skills*' | head -1)
EV=~/ghq/github.com/gigun-dev/claude-code/plugins/ios-skills/skills/ios-simulator/evals
```

### Step 1: with_skill と without_skill を**同じターンで**spawn する

`skill-creator` の指示: 先に with だけ回して後から baseline を取りに戻らないこと(条件が揃わない)。
ただしこのスキルでは **同時に走らせてはいけない**(下の「並列実行の禁止」)。
→ **「同じターンで spawn する」と「Simulator を同時に触らせない」を両立させるため、
プロンプト側で端末を分離し、かつ後述のとおり run ごとに端末名を一意にする。**
それでも録画を伴う eval(`eval-demo-video`)だけは**単独で走らせる**。

サブエージェントに渡すプロンプトのテンプレート:

```
Execute this task:
- Skill path: <skill 側は with_skill のときだけ渡す>
- Task: <evals.json の prompt をそのまま>
- Save outputs to: <EV>/iteration-<N>/<eval-name>/<with_skill|without_skill>/run-1/outputs/
- Outputs to save: 成果物一式 + transcript.md(何をどの順で実行したか。コマンドは省略せずそのまま)

【この環境の約束事 — 必ず守ること】
- 作ってよい Simulator は、名前が `EVAL-<eval-name>-<config>` で始まるものだけ。
- それ以外の既存 Simulator(Booted かどうかに関わらず)には、install / launch /
  terminate / erase / boot / shutdown / 設定変更を一切しない。読み取りもしない。
- 作業が終わったら、自分で作った `EVAL-` 端末は削除せず残し、UDID を報告する
  (採点で `Accounts3.sqlite` を見るため)。後始末は採点後に人が行う。
- ホスト macOS の設定(システムプロキシ、Proxyman のルール等)を変更した場合は、
  終了時に必ず元に戻し、変更した内容と復元したことを報告する。
- 本番サーバーに書き込んだテストデータは必ず消し、消したことを確認して報告する。
```

> **なぜ「保護対象を触るな」を毎回プロンプトに書くのか**: iteration-1 の `eval-demo-video` で、
> シェル変数展開のミスから**保護対象の端末にアプリを install/launch する事故**が起きた。
> これは eval の副作用として最も高くつくクラスの失敗なので、expectation にも入れてあるし、
> 各 run のプロンプトにも明示的な境界として書く。

### Step 2: 走っている間に expectation を見直す

`evals.json` の `expectations` を読み直し、**両構成で常に PASS しそうなもの**に印をつけておく。
grading の後に消す判断が速くなる。

### Step 3: 完了通知が来たら**即座に** `timing.json` を書く

```json
{ "total_tokens": 258665, "duration_ms": 3302249, "total_duration_seconds": 3302.2 }
```

> `total_tokens` と `duration_ms` は**サブエージェントの完了通知にしか出てこない**。
> どこにも永続化されないので、通知を受けた時点で書く。後から復元する手段は無い。

### Step 4: 採点 → 集計 → ビューア

```bash
# 採点: grader サブエージェントに $SC/agents/grader.md を読ませ、transcript と outputs を渡す
#   → 各 run-N/grading.json({"expectations":[{text,passed,evidence}], "summary":{...}})

# 集計
cd "$SC" && python -m scripts.aggregate_benchmark "$EV/iteration-<N>" --skill-name ios-simulator
#   → benchmark.json / benchmark.md。★ baseline が無い間は delta を手で N/A に潰す(罠2)

# 人間レビュー用ビューア
cd "$SC" && nohup python eval-viewer/generate_review.py "$EV/iteration-<N>" \
  --skill-name ios-simulator --benchmark "$EV/iteration-<N>/benchmark.json" \
  > /dev/null 2>&1 &
# iteration-2 以降は --previous-workspace "$EV/iteration-<N-1>" も渡す
```

### Step 5: `feedback.json` を読んで SKILL.md を直す

自分でビューアを作らない(`generate_review.py` を使う)。人が見る前に自分で結論を出さない。

---

## このスキル固有の運用ルール

### 端末の命名規約と後始末

- eval が作る端末は必ず **`EVAL-` プレフィックス**。`EVAL-<eval-name>-<config>` を推奨。
- 削除は**採点が終わってから人が行う**。採点で `Accounts3.sqlite` を直接見るため、
  run 終了時点で消させない。
- 溜まった端末の掃除(人が実行する。エージェントには任せない):
  `xcrun simctl list devices | grep EVAL-` で確認してから消す。

### 並列実行の禁止

端末を分ければ `idb` の所有権は分離できる(SKILL.md「デバイスの所有権」)。だが:

- **システムプロキシはホスト単位**。ある run が CA を入れる/プロキシを触ると他の run に効く。
- **`SimRenderServer` は複数端末で競合する。** iteration-1 で、他プロセスが別端末を操作している
  最中に `simctl io recordVideo` が `SimRenderServer.SimulatorError` で開始に失敗した
  (エージェントの推論であって確定した因果ではない。ただしリスクとしては十分)。
- **ペーストボード (`simctl pbcopy`) は UDID 指定なので分離される**が、ブート直後は失敗する。

→ **直列で回す。** 6本 × 2構成 = 12 run を全部直列に回すと約 11 時間。現実的でない。次項へ。

### どれを回すか(コスト戦略)

全部は回さない。優先順位は:

1. **iteration-2 でまず取るのは `eval-caldav-account-sync` と `eval-demo-video` の
   `without_skill`。** iteration-1 に with_skill の実測があるので、この2本で初めて delta が出る。
   ここを飛ばすと、以降どれだけ eval を増やしても「スキルに価値があるか」を一度も言えない。
2. その次に `eval-account-fanout`(状態プロビジョニングの中核)。
3. `eval-webview-card-dark` は **Simulator をほとんど使わない**ので所要時間が短いはず。
   コスト対効果が良く、しかも「Simulator を使わない判断」という他の eval では測れない軸を持つ。
4. `eval-japanese-text-entry` / `eval-onboarding-walkthrough` は後回しでよい。

### transcript を必ず残す(iteration-1 の反省)

iteration-1 は**自己申告レポートしか残っていない**ため、
「すべてのコマンドが UDID を明示していたか」のような expectation を採点できなかった
(`eval-caldav-account-sync` の grading.json 末尾の項目を参照。証拠不足のため PASS にしていない)。
`skill-creator` の grader は `transcript_path` を前提にしている。
**iteration-2 からは `run-N/transcript.md` を必ず保存する。**

---

## description のトリガー eval の回し方

`skill-creator` の「Description Optimization」に従う。

```bash
cd "$SC" && python -m scripts.run_loop \
  --eval-set "$EV/trigger_queries.json" \
  --skill-path ~/ghq/github.com/gigun-dev/claude-code/plugins/ios-skills/skills/ios-simulator \
  --model <このセッションを動かしているモデル ID> \
  --max-iterations 5 --verbose
```

**こちらは Simulator を一切操作しない**(`claude -p` でスキルがロードされるかだけを見る)ので、
出力品質 eval と違って気軽に回せる。**先にこちらを回すのが合理的。**

### train / validation ファイルの位置づけ

`run_loop.py` は `--eval-set` に渡された配列を **自分で 60/40 に分割する**
(`--holdout 0.4`、seed 42、`should_trigger` で層化)。
つまり **`train_queries.json` / `validation_queries.json` をツールに渡す必要はない。**

この2ファイルは、公式ドキュメントの手動 bash スクリプト経路で回すときと、
人が「どのクエリがどちら側か」を目で確認するために置いてある。
**中身は `run_loop.py` の `split_eval_set()` を同じ入力・同じ seed で再現して生成したもの**なので、
ツールが実際に使う分割と一致する。

- train (12): t06 t07 t10 t05 t01 t02 / t12 t19 t18 t11 t17 t20
- validation = holdout test (8): t08 t04 t03 t09 / t14 t16 t13 t15

⚠️ **分割は `trigger_queries.json` の並び順に依存する。** クエリを追加・並べ替えたら
分割が変わるので、この2ファイルも作り直すこと(README 末尾のスニペット)。

<details>
<summary>train/validation を再生成するスニペット</summary>

```python
import json, random
def split_eval_set(eval_set, holdout, seed=42):          # run_loop.py と同一
    random.seed(seed)
    t = [e for e in eval_set if e["should_trigger"]]
    n = [e for e in eval_set if not e["should_trigger"]]
    random.shuffle(t); random.shuffle(n)
    nt, nn = max(1, int(len(t)*holdout)), max(1, int(len(n)*holdout))
    return t[nt:] + n[nn:], t[:nt] + n[:nn]              # (train, test)

qs = json.load(open("trigger_queries.json"))
train, test = split_eval_set(qs, 0.4)
json.dump(train, open("train_queries.json", "w"), ensure_ascii=False, indent=2)
json.dump(test,  open("validation_queries.json", "w"), ensure_ascii=False, indent=2)
```
</details>

---

## この構造は動作確認済み

`iteration-1/` は、Simulator を一切触らずに **2本のスクリプトを実際に通して**検証してある:

- `python -m scripts.aggregate_benchmark evals/iteration-1 --skill-name ios-simulator`
  → `benchmark.json` / `benchmark.md` が生成され、pass_rate・時間・トークンが正しく読まれた
  (トークンが 0 になる罠1 はここで見つけて直した)
- `python eval-viewer/generate_review.py evals/iteration-1 --benchmark … --static <path>`
  → 2 run とも検出され、prompt・outputs・grading が表示された

構造を変えたら、この2つを通し直してから次の run を回すこと。**壊れた構造で 55 分を捨てないため。**

---

## 現在地

- **iteration-1**: `eval-demo-video` と `eval-caldav-account-sync` の **`with_skill` のみ**実測あり
  (2026-08-01 深夜)。`without_skill` は未取得なので **`benchmark.json` の delta は N/A**。
- **未実行**: eval 3〜6 の全構成、eval 1〜2 の `without_skill`、トリガー eval の全クエリ。
- **次の一手**: (a) トリガー eval を回す(安いので先に)。(b) eval 1〜2 の `without_skill` を取る。
