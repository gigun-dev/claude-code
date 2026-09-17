#!/usr/bin/env bash
# =============================================================================
# plugins/agy-mcp/scripts/agy-run.sh — `agy` CLI を叩く唯一の直呼び経路
# =============================================================================
# 【このスクリプトが吸収するもの】(契約は skills/agy-cli-runtime/SKILL.md にも書く)
#   - `-p` の連結形式。`agy -p "..." --model X` は `-p` が `--model` を prompt
#     として食う(実測)。ここでは常に `-p=<text>` の `=` 連結を使う。
#   - 既定モデル。日本語の最終稿は gemini-3.8-flash-high。
#   - 返答冒頭の前置き剥がし。Gemini は「ご提示いただいた文章を…整えました」の
#     ような1〜2文を必ず先頭に付ける(実測)。プロンプト側で本文をマーカーで
#     挟ませ、マーカーの中身だけを抜き出す —— 前置きの文面そのものを
#     パターンマッチで狙う案は採らない(文面は言い回しが揺れる。マーカーは
#     位置で切るので言い回しに依存しない)。
#   - 長いプロンプト/長いファイル。ファイル経由で渡し、シェルのメタ文字と
#     改行を壊さない。
#   - ファイル入力のときはその場で書き戻さない契約。ただし agy 自身の設定
#     (~/.gemini/antigravity-cli/settings.json の agentMode: accept-edits /
#     toolPermission: always-proceed)は承認なしでファイル書き込みツールを
#     実行できるため、prompt に元ファイルの絶対パスを書くと agy がその場で
#     元ファイルを直接書き換えた(実測: 呼び出し前後で md5 が変化)。ここでは
#     prompt にファイル名(basename)だけを渡して絶対パスを書かず、agy の
#     CWD を呼び出しごとの空ディレクトリへ隔離し、環境変数
#     AGY_RUN_READONLY=1 を立てて書き込み系ツールを deny させ、さらに
#     呼び出し後に元ファイルの内容を退避分と照合して変わっていれば書き戻す。
#   - 呼び出しごとに道具を絞る引数は agy に無い(--allowed-tools 相当は
#     --help にもサブコマンドにも無く、--sandbox は file ツールを縛らず、
#     --mode plan は強制ではない)。代わりに ~/.gemini/config/hooks.json の
#     PreToolUse フック(実体は scripts/agy-readonly-hook.sh)が
#     AGY_RUN_READONLY=1 のときだけ write_to_file / replace_file_content を
#     deny する。設定は常設・実効は呼び出しごと、という形。
#     このフックは ~/.gemini/ 側の設定に依存するので、hooks.json が消えれば
#     無音で deny しなくなる。上の3つ(パスを渡さない・CWD 隔離・事後照合)は
#     フックとは独立に残す。
#
# 呼び出し元(MCP ツール以外で agy を直接叩きたい場面)は、
# 生の `agy` 文字列を組まず、必ずこのスクリプトを経由すること
# (plugins/agy-mcp/skills/agy-cli-runtime/SKILL.md)。
#
# 【なぜ agy 本体の skill 機構(skills.json / .agents/)を使わないのか】
#   一度検討して戻した。~/.gemini/antigravity-cli/builtin/skills/
#   agy-customizations/SKILL.md の Progressive Disclosure の節にある通り、
#   skill として登録しても本文が実際に読まれるかはモデルの判断に委ねられる
#   (「name と description だけが注入され、本文はモデルが要ると判断した
#   ときだけ読まれる」)。ここでの用途(1回きりの推敲に規範を強制する)は
#   賭けにできない。本文をこちらから prompt に確実に含めてしまう
#   `--rules` / `--skill`(内部は同じ経路)の形を採る。
# =============================================================================

set -euo pipefail

# 生成した一時パス(ディレクトリ・ファイル)をここへ積み、EXIT 時にまとめて消す。
# agy を呼ぶたびに CWD 隔離用の空ディレクトリを1つ作るので、trap は複数パス
# 前提で書く(1パスだけを消す前提の trap だと隔離ディレクトリが残り続ける)。
_tmp_paths=()
_cleanup_tmp_paths() {
	local p
	for p in "${_tmp_paths[@]}"; do
		rm -rf -- "$p"
	done
}
trap _cleanup_tmp_paths EXIT

usage() {
	cat >&2 <<'USAGE'
Usage:
  agy-run.sh --file PATH [--instruction TEXT|--instruction-file PATH] [--rules PATH ...] [--skill NAME ...] [--model MODEL] [--max-followups N] [--json]
  agy-run.sh --prompt TEXT [--rules PATH ...] [--skill NAME ...] [--model MODEL] [--json]
  agy-run.sh --prompt-file PATH [--rules PATH ...] [--skill NAME ...] [--model MODEL] [--json]
  agy-run.sh --selftest-facts

--file モード(主):
  元ファイルを読み、instruction(省略時は日本語校正の既定指示)に従って
  agy に書き直させ、元ファイルは変更せず unified diff だけを標準出力へ出す。
  文字数(元/結果)を stderr に1行出す。
  結果の数値・URL・箇条書きと見出しの数を元と照合し、合わなければ同じ会話の
  次のターンでずれた箇所を名指しして直させる(既定 2 回まで)。
  固有名詞は機械で照合しない(できない)。

--prompt / --prompt-file モード(従):
  短い断片やファイルに紐づかない相談用。前置きを剥がした本文だけを標準出力へ返す。
  書き直しではないので事実照合は行わない(比較対象の元文が無い)。

Options:
  --model MODEL              既定: gemini-3.8-flash-high
  --rules PATH                固定の文章規範ファイルを instruction / prompt の後ろに
                               連結する。複数回指定でき、指定順に連結する
                               (--skill で引いたファイルとも同じ列に混ざる)。
                               instruction(タスク固有の指示)と両立させるための口。
                               その回だけの制約を書いたファイルを渡す用途に使う。
                               却下した語を溜める一覧は作らないこと(2026-09-17 の
                               裁定)。腐りかたは無限にあり、一覧は網羅に届かない
                               まま伸びる。規範を当て直すほうが安い。
  --skill NAME                 このリポジトリの plugins/*/skills/NAME/SKILL.md を
                               名前だけで引き当て、--rules と同じ経路(prompt への
                               連結)へ流す。複数回指定できる。呼び出し側は
                               プラグイン名を知らなくてよい。
  --max-followups N            事実照合が合わなかったときに聞き直す上限回数。
                               既定 2。0 で聞き直さない(--file モードのみ)。
  --json                       機械向けの payload(JSON)を標準出力へ出す。
                               このとき人向けの表示(diff・文字数)は標準エラーへ回す。
  --selftest-facts             事実照合の陽性対照・陰性対照を走らせる(agy を呼ばない)。
USAGE
	exit 1
}

# 日本語校正の既定指示。目的は AI 臭さの脱臭(不自然な言い回し・翻訳調の比喩・
# 空句を取り除くこと)であって、短縮ではない。短縮を主目的にすると文字数は
# ほとんど動かず、語の選択だけが劣化する(実測: 短縮を条件に入れても文字数は
# ほぼ変わらず、変わったのは「実測確認」→「確認済み」のような語の選び方だけ
# だった)。短くしたいときも、指示は語の選び方の側で書くこと。
#
# 事実を変えないことは、この指示で agy へ伝えたうえで、返ってきた結果を
# このスクリプトが機械で照合する(数値・URL・箇条書きと見出しの数)。
_DEFAULT_INSTRUCTION='次の文章を、意図や内容を変えずに、極めて自然かつ平易なビジネスユースの日本語へ校正すること。
普段の日本語では使わない言い回しや単語は避けること。難しい言葉を別の難しい言葉に置き換えるだけにしないこと。
数値・URL・固有名詞・項目数など事実に関わる部分は一切変えないこと。'

model="gemini-3.8-flash-high"
file=""
instruction=""
instruction_file=""
prompt=""
prompt_file=""
rules_files=()
skill_names=()
max_followups=2
want_json=0
selftest_facts=0

while [ $# -gt 0 ]; do
	case "$1" in
	--max-followups)
		max_followups="$2"
		shift 2
		;;
	--json)
		want_json=1
		shift
		;;
	--selftest-facts)
		selftest_facts=1
		shift
		;;
	--model)
		model="$2"
		shift 2
		;;
	--file)
		file="$2"
		shift 2
		;;
	--instruction)
		instruction="$2"
		shift 2
		;;
	--instruction-file)
		instruction_file="$2"
		shift 2
		;;
	--rules)
		rules_files+=("$2")
		shift 2
		;;
	--skill)
		skill_names+=("$2")
		shift 2
		;;
	--prompt)
		prompt="$2"
		shift 2
		;;
	--prompt-file)
		prompt_file="$2"
		shift 2
		;;
	-h | --help)
		usage
		;;
	*)
		echo "agy-run.sh: unknown argument: $1" >&2
		usage
		;;
	esac
done

case "$max_followups" in
'' | *[!0-9]*)
	echo "agy-run.sh: --max-followups には0以上の整数を渡すこと: $max_followups" >&2
	exit 1
	;;
esac

if ! command -v python3 >/dev/null 2>&1; then
	# 事実照合と JSON の組み立てを python3 で行う。無ければ黙って照合を
	# 飛ばさない —— 照合していないのに通ったように見えるのが一番悪い。
	echo "agy-run.sh: python3 が PATH にない(事実照合に必要)" >&2
	exit 1
fi

# -----------------------------------------------------------------------------
# 事実照合(機械で捕まえられるものだけ)
# -----------------------------------------------------------------------------
# 元文と結果文を受け取り、数値・URL・箇条書きと見出しの数を比べる。
# 呼び出し規約:
#   python3 <script> ORIG NEW OUT_JSON OUT_FOLLOWUP
#   標準出力の1行目が match / mismatch、2行目以降が人向けの要約。
#   OUT_JSON に機械向けの結果、OUT_FOLLOWUP に聞き直し用のプロンプトを書く。
_facts_py=""
_ensure_facts_py() {
	[ -n "$_facts_py" ] && return 0
	_facts_py=$(mktemp)
	_tmp_paths+=("$_facts_py")
	cat >"$_facts_py" <<'FACTS_PY'
import collections
import json
import re
import sys

# 全角数字と全角のカンマ・ピリオドだけを半角へ寄せる。NFKC 全体は掛けない
# (丸数字や合字まで変形し、比べている対象が元文と別物になる)。
_WIDE = str.maketrans("０１２３４５６７８９，．", "0123456789,.")

# URL は行末の句読点や閉じ括弧を含めないところで切る。
_URL_RE = re.compile(r'https?://[^\s<>"\'`）)】」』、。,]+')

# 数値の取り方。狭く取る —— 誤検知が続けばこの照合ごと無視されるので、
# 取りこぼしよりも取りすぎを避ける。決めたこと:
#   - URL を先に取り除いてから数える。URL は別枠で比べるので二重に数えない。
#   - 前後に ASCII 英字かアンダースコアが付く数字は取らない(GA4 / v2 / N1)。
#     識別子の断片であって、日本語の推敲で動く事実ではない。
#   - ハイフン隣接は取る。2026-09-17 のような日付を落とさないため。
#     版番号(gemini-3.8)も一緒に拾うが、推敲で書き換わらないので害は無い。
#   - 桁区切りのカンマは外して比べる(1,000 と 1000 を同じ数とみなす)。
#   - 小数点以下はそのまま残す(1.0 と 1 は別の数として扱う)。
#   - 漢数字は取らない。「一方」「第一」など数でない用法と区別できない。
#     算用数字と漢数字の書き換えは不一致として報告される。
#   - 日付や時刻は分解された数の並びとして扱う。9月14日 は 9 と 14 になり、
#     9/14 へ書き換えても多重集合は変わらない(表記の変更では鳴らない)。
_NUM_RE = re.compile(r'(?<![0-9A-Za-z_])[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?(?![0-9A-Za-z_])')

# 箇条書きは行頭の記号と空白1つ以上で判定する。文中の「・」は数えない。
_BULLET_RE = re.compile(r'^[ \t]*(?:[-*+•・]|\(?[0-9]+[.)])[ \t]+\S')
# 見出しは ATX 形式(# 〜 ######)だけ。下線形式(===)は数えない。
_HEADING_RE = re.compile(r'^[ \t]{0,3}#{1,6}[ \t]+\S')


def urls(text):
    return [m.group(0) for m in _URL_RE.finditer(text)]


def numbers(text):
    stripped = _URL_RE.sub(" ", text.translate(_WIDE))
    return [m.group(0).replace(",", "") for m in _NUM_RE.finditer(stripped)]


def line_counts(text):
    bullets = 0
    headings = 0
    for line in text.splitlines():
        if _HEADING_RE.match(line):
            headings += 1
        elif _BULLET_RE.match(line):
            bullets += 1
    return bullets, headings


def multiset_diff(before, after):
    """消えたもの・増えたものを個数つきで返す。順序の入れ替えは差分にしない。"""
    lost = collections.Counter(before) - collections.Counter(after)
    gained = collections.Counter(after) - collections.Counter(before)
    return sorted(lost.elements()), sorted(gained.elements())


NOT_CHECKED = [
    "固有名詞: 機械では判定できないので照合していない(人が読むこと)",
    "散文中の項目: 箇条書きと見出しだけを数えており、文章の中で列挙された"
    "「項目」は数えられないので対象外",
]


def check(original, result):
    num_lost, num_gained = multiset_diff(numbers(original), numbers(result))
    url_lost, url_gained = multiset_diff(urls(original), urls(result))
    ob, oh = line_counts(original)
    nb, nh = line_counts(result)
    report = {
        "numbers": {"missing": num_lost, "added": num_gained},
        "urls": {"missing": url_lost, "added": url_gained},
        "bullets": {"original": ob, "result": nb},
        "headings": {"original": oh, "result": nh},
        "not_machine_checked": NOT_CHECKED,
    }
    report["match"] = not (
        num_lost or num_gained or url_lost or url_gained or ob != nb or oh != nh
    )
    return report


def summarize(report):
    lines = []
    for key, label in (("numbers", "数値"), ("urls", "URL")):
        missing = report[key]["missing"]
        added = report[key]["added"]
        if missing:
            lines.append("%sが元文から消えた: %s" % (label, ", ".join(missing)))
        if added:
            lines.append("%sが元文に無いのに増えた: %s" % (label, ", ".join(added)))
    for key, label in (("bullets", "箇条書きの項目数"), ("headings", "見出しの数")):
        before = report[key]["original"]
        after = report[key]["result"]
        if before != after:
            lines.append("%sが %d から %d へ変わった" % (label, before, after))
    return lines


def followup_prompt(report):
    """聞き直しのプロンプト。文書は送り直さない(同じ会話の続きとして投げる)。"""
    lines = [
        "直前に返してもらった本文で、元の文章にあった事実が変わっている箇所がある。",
        "次の点だけを元の文章どおりに直し、本文全体を同じマーカー形式でもう一度返すこと。",
        "指摘した箇所以外の書き直しはしないこと。",
        "",
    ]
    lines += ["- " + line for line in summarize(report)]
    return "\n".join(lines) + "\n"


def main(argv):
    with open(argv[1], encoding="utf-8") as fp:
        original = fp.read()
    with open(argv[2], encoding="utf-8") as fp:
        result = fp.read()
    report = check(original, result)
    with open(argv[3], "w", encoding="utf-8") as fp:
        json.dump(report, fp, ensure_ascii=False)
    summary = summarize(report)
    with open(argv[4], "w", encoding="utf-8") as fp:
        fp.write("" if report["match"] else followup_prompt(report))
    print("match" if report["match"] else "mismatch")
    for line in summary:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
FACTS_PY
}

# --selftest-facts: agy を呼ばずに照合の陽性対照・陰性対照を走らせる。
# 検知しない照合を積んでも意味が無いので、「落ちるべきときに落ちるか」を
# 材料つきで確かめられる口を残す。
if [ "$selftest_facts" -eq 1 ]; then
	_ensure_facts_py
	st_dir=$(mktemp -d)
	_tmp_paths+=("$st_dir")
	cat >"$st_dir/orig" <<'ORIG'
# 実績の報告

2026-09-14 の計測では、応答は 1,200 ミリ秒で、成功率は 99.5% だった。
詳細は https://example.com/report/42 を参照。

- 取り込みの経路を1本にした
- 再試行の上限を 3 回にした
ORIG
	# 陰性対照: 語の選び方だけを変え、事実はすべて保つ書き直し。
	cat >"$st_dir/good" <<'GOOD'
# 実績の報告

２０２６-０９-１４ の計測では、応答は 1200 ミリ秒、成功率は 99.5% でした。
詳しくは https://example.com/report/42 をご覧ください。

- 取り込みの経路を 1 本にまとめた
- 再試行の上限を 3 回に定めた
GOOD
	# 陽性対照: 数値が落ち、URL が消え、箇条書きが1つ減っている。
	cat >"$st_dir/bad" <<'BAD'
# 実績の報告

2026-09-14 の計測では、応答は十分に速く、成功率も高い水準でした。
詳細は報告書を参照してください。

- 取り込みの経路を1本にした
BAD
	st_failed=0
	for case in good bad; do
		set +e
		st_out=$(python3 "$_facts_py" "$st_dir/orig" "$st_dir/$case" "$st_dir/$case.json" "$st_dir/$case.followup" 2>&1)
		st_rc=$?
		set -e
		st_status=$(printf '%s\n' "$st_out" | sed -n '1p')
		if [ "$st_rc" -ne 0 ]; then
			echo "NG [$case] 照合の実行自体が失敗した"
			printf '%s\n' "$st_out" | sed 's/^/    /'
			st_failed=1
			continue
		fi
		echo "--- $case ---"
		printf '%s\n' "$st_out" | sed 's/^/    /'
		if [ "$case" = "good" ] && [ "$st_status" != "match" ]; then
			echo "NG [good] 事実を保った書き直しを不一致と誤検知した"
			st_failed=1
		fi
		if [ "$case" = "bad" ]; then
			if [ "$st_status" != "mismatch" ]; then
				echo "NG [bad] 数値と URL が落ちた結果を検出できなかった"
				st_failed=1
			else
				echo "    聞き直しのプロンプト:"
				sed 's/^/      /' "$st_dir/$case.followup"
			fi
		fi
	done
	if [ "$st_failed" -ne 0 ]; then
		echo "NG selftest-facts: 失敗あり"
		exit 1
	fi
	echo "OK selftest-facts: 陰性対照は誤検知せず、陽性対照は検出した"
	exit 0
fi

if ! command -v agy >/dev/null 2>&1; then
	echo "agy-run.sh: agy が PATH にない" >&2
	exit 1
fi

# --skill は名前から実ファイルを引き当て、--rules と同じ列(rules_files)へ
# 積む。ここで解決を終わらせ、以降の連結処理を1本にする(同じ文字列が
# 2通りの経路で入ると、片方だけ直す事故が起きる)。
if [ "${#skill_names[@]}" -gt 0 ]; then
	script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
	# plugins/agy-mcp/scripts から3つ上がこのリポジトリの root
	# (plugins/agy-mcp/scripts → plugins/agy-mcp → plugins → root)。
	repo_root=$(cd -- "$script_dir/../../.." && pwd)

	for skill_name in "${skill_names[@]}"; do
		hit=""
		for candidate in "$repo_root"/plugins/*/skills/"$skill_name"/SKILL.md; do
			[ -f "$candidate" ] || continue
			if [ -n "$hit" ]; then
				echo "agy-run.sh: skill '$skill_name' が複数の plugin に見つかった(あいまい): $hit / $candidate" >&2
				exit 1
			fi
			hit="$candidate"
		done
		if [ -z "$hit" ]; then
			echo "agy-run.sh: skill が見つからない: $skill_name (plugins/*/skills/$skill_name/SKILL.md を探した)" >&2
			exit 1
		fi
		rules_files+=("$hit")
	done
fi

# --rules / --skill は指定順に連結する。全文を渡す(要点への圧縮はしない)。理由:
# 規範文書(例: japanese-tech-writing の SKILL.md)は「AI っぽい表現」「翻訳調の
# 比喩」などを個別の禁止語ではなく判定手順(字義どおりの動作を想像できるか→
# 主体と対象を具体語で言い直せるか)で定めていることが多い。要点だけを抜くと
# 判定手順が失われ、抜き出した禁止語リストだけが残って結局「別の難しい言葉への
# 置換」を誘発する(このリポジトリが既に踏んだ失敗のパターン)。渡すファイルは
# 数百行程度の想定で、1回の書き直し呼び出しあたりのトークン費用は無視できる
# 規模であり、費用を理由に要約しない。
rules_text=""
if [ "${#rules_files[@]}" -gt 0 ]; then
	for _rf in "${rules_files[@]}"; do
		[ -f "$_rf" ] || {
			echo "agy-run.sh: rules file not found: $_rf" >&2
			exit 1
		}
		if [ -n "$rules_text" ]; then
			rules_text="${rules_text}

$(cat -- "$_rf")"
		else
			rules_text="$(cat -- "$_rf")"
		fi
	done
fi

# マーカーは衝突しにくい固定文字列にする。本文に元々この文字列が含まれることは
# 通常ないが、絶対に無いとは言えないので前提として書いておく(その場合は抽出がずれる)。
_begin_marker="=====AGY_RUN_BODY_BEGIN====="
_end_marker="=====AGY_RUN_BODY_END====="

# agy の stdout から JSON ペイロードを取り出し、response 本文をファイルへ書く。
# 標準出力へは "status<TAB>conversation_id" の1行を返す。
#
# 単純な json.load を使わない理由は server.py の _parse_agy_stdout と同じ(実測):
#   - response に生の制御文字が混ざることがある(strict=False で受け入れる)。
#   - JSON 行の前に別の行(権限拒否の通知など)が出ることがある。
# 末尾の非空行から順に行境界を手前へずらし、最初に dict として読めたものを採る。
_split_py=""
_ensure_split_py() {
	[ -n "$_split_py" ] && return 0
	_split_py=$(mktemp)
	_tmp_paths+=("$_split_py")
	cat >"$_split_py" <<'SPLIT_PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fp:
    stdout = fp.read()

lines = stdout.splitlines()
payload = None
for i in reversed([n for n, line in enumerate(lines) if line.strip()]):
    try:
        parsed = json.loads("\n".join(lines[i:]).strip(), strict=False)
    except ValueError:
        continue
    if isinstance(parsed, dict):
        payload = parsed
        break

if payload is None:
    sys.stderr.write("agy の stdout から JSON ペイロードを取り出せなかった\n")
    sys.exit(1)

with open(sys.argv[2], "w", encoding="utf-8") as fp:
    fp.write(payload.get("response") or "")
print("%s\t%s" % (payload.get("status") or "", payload.get("conversation_id") or ""))
SPLIT_PY
}

# `agy` を1回呼び、前置きを剥がした本文を指定ファイルへ書く。
# 失敗(マーカーが見当たらない等)は非0で返し、生応答を stderr に残す。
#
# 引数: <プロンプト> <本文の書き出し先> [継続したい会話 ID]
# 会話 ID を渡すとその会話の次のターンとして実行する。省略すれば新規会話。
# 実行後の会話 ID は _last_cid に入る(呼び出し元が次のターンで使う)。
#
# agy は自分の CWD を ls して回り、prompt 本文に書かれた絶対パスまで勝手に
# 開く(実測)。呼び出しごとに空の一時ディレクトリを作り、そこへ cd してから
# agy を起動することで、呼び出し元のリポジトリ全体(および CWD 配下の
# .agents/skills 等)を見えなくする。
_last_cid=""
_call_agy() {
	local body_prompt="$1"
	local out_file="$2"
	local resume_cid="${3-}"
	local wrapped
	wrapped="$(
		cat <<EOF
${body_prompt}

---
出力形式についての指示(この指示自体への言及・前置きの文は一切書かないこと):
前置きも後書きも書かず、本文だけを次の2行のマーカーで挟んで返すこと。
マーカーの外には1文字も書かないこと。

${_begin_marker}
(ここに本文)
${_end_marker}
EOF
	)"

	local isolated_cwd
	isolated_cwd=$(mktemp -d)
	_tmp_paths+=("$isolated_cwd")

	local raw_file resp_file
	raw_file=$(mktemp)
	resp_file=$(mktemp)
	_tmp_paths+=("$raw_file" "$resp_file")

	# --conversation は毎回新しい空ディレクトリから呼んでも会話を継続する
	# (実測 2026-09-17: 別ディレクトリからの 2 ターン目が num_turns=2 で
	# 同じ会話 ID を返し、1 ターン目に渡した文字列を復唱した)。
	# -c(--continue)は使わない —— ここでは「直近の会話」を紐づける作業空間が
	# 毎回消えるうえ、継続に失敗しても新規会話として平然と成功する(server.py の
	# 同じ判断を参照)。
	local agy_args=(-p="${wrapped}" --model "${model}" --output-format json --disable-slash-commands)
	if [ -n "$resume_cid" ]; then
		agy_args+=(--conversation "$resume_cid")
	fi

	# AGY_RUN_READONLY=1 は agy の PreToolUse フックが読む(scripts/agy-readonly-hook.sh)。
	# この呼び出しの間だけ write_to_file / replace_file_content が deny される。
	# --file モードだけでなく --prompt / --prompt-file モードでも立てる
	# —— どちらの用途でも agy にファイルを書かせる理由が無い。
	if ! (cd -- "$isolated_cwd" && AGY_RUN_READONLY=1 agy "${agy_args[@]}") >"$raw_file"; then
		echo "agy-run.sh: agy が非0で終了した" >&2
		sed 's/^/    /' "$raw_file" >&2
		return 1
	fi

	_ensure_split_py
	local split_line status returned_cid
	if ! split_line=$(python3 "$_split_py" "$raw_file" "$resp_file"); then
		sed 's/^/    /' "$raw_file" >&2
		return 1
	fi
	status=${split_line%%$'\t'*}
	returned_cid=${split_line#*$'\t'}

	if [ "$status" != "SUCCESS" ]; then
		echo "agy-run.sh: agy が status=${status} を返した" >&2
		sed 's/^/    /' "$raw_file" >&2
		return 1
	fi

	# 継続を頼んだのに別の会話 ID が返ってきたら、それは新規会話として
	# 答えたということ。成功と区別が付かない形で黙って通さない。
	if [ -n "$resume_cid" ] && [ "$returned_cid" != "$resume_cid" ]; then
		echo "agy-run.sh: 会話の継続に失敗した(要求 ${resume_cid} / 返り ${returned_cid})" >&2
		return 1
	fi
	_last_cid="$returned_cid"

	awk -v b="$_begin_marker" -v e="$_end_marker" '
		$0 ~ b { flag = 1; next }
		$0 ~ e { flag = 0 }
		flag { if (NF || started) { print; started = 1 } }
	' "$resp_file" >"$out_file"

	if [ -z "$(tr -d '[:space:]' <"$out_file")" ]; then
		echo "agy-run.sh: 応答からマーカーで囲まれた本文を抽出できなかった" >&2
		echo "--- agy の生応答 ---" >&2
		cat "$resp_file" >&2
		echo "--------------------" >&2
		return 1
	fi
}

# -----------------------------------------------------------------------------
# 機械向けの payload(--json)
# -----------------------------------------------------------------------------
# 引数: <mode> <diff ファイル|空> <本文ファイル> <照合結果 JSON|空> <元文字数> <結果文字数>
# 値はすべて環境変数かファイル経由で python へ渡す。シェルで JSON を組み立てない
# (本文にも diff にも引用符と改行が入る。組み立てた側が必ず壊す)。
_payload_py=""
_emit_payload() {
	if [ -z "$_payload_py" ]; then
		_payload_py=$(mktemp)
		_tmp_paths+=("$_payload_py")
		cat >"$_payload_py" <<'PAYLOAD_PY'
import json
import os
import sys


def read(path):
    if not path:
        return None
    with open(path, encoding="utf-8") as fp:
        return fp.read()


mode, diff_path, body_path, check_path = sys.argv[1:5]
original_chars, result_chars = int(sys.argv[5]), int(sys.argv[6])

payload = {
    "mode": mode,
    "model": os.environ.get("AGY_RUN_MODEL", ""),
    "conversation_id": os.environ.get("AGY_RUN_CID") or None,
    "followups": int(os.environ.get("AGY_RUN_FOLLOWUPS", "0")),
    "max_followups": int(os.environ.get("AGY_RUN_MAX_FOLLOWUPS", "0")),
    "original_chars": original_chars,
    "result_chars": result_chars,
    "result": read(body_path),
}

if mode == "file":
    payload["file"] = os.environ.get("AGY_RUN_FILE", "")
    payload["diff"] = read(diff_path)

if check_path:
    payload["fact_check"] = json.loads(read(check_path))
else:
    # 照合していないときに fact_check を省略しない。キーが無いのと
    # 「照合していない」のとを読み手が区別できるようにする。
    payload["fact_check"] = None
    payload["fact_check_skipped"] = (
        "--prompt / --prompt-file モードは書き直しではなく、"
        "比較の基準になる元文が無いので事実照合を行わない"
    )

fact = payload["fact_check"]
payload["status"] = (
    "ok" if fact is None or fact.get("match") else "fact_mismatch_unresolved"
)

json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PAYLOAD_PY
	fi
	AGY_RUN_MODEL="$model" \
		AGY_RUN_CID="${cid-}" \
		AGY_RUN_FOLLOWUPS="${followups-0}" \
		AGY_RUN_MAX_FOLLOWUPS="$max_followups" \
		AGY_RUN_FILE="$file" \
		python3 "$_payload_py" "$1" "$2" "$3" "$4" "$5" "$6"
}

if [ -n "$file" ]; then
	if [ ! -f "$file" ]; then
		echo "agy-run.sh: file not found: $file" >&2
		exit 1
	fi
	if [ -n "$instruction_file" ]; then
		[ -f "$instruction_file" ] || {
			echo "agy-run.sh: instruction file not found: $instruction_file" >&2
			exit 1
		}
		instruction=$(cat -- "$instruction_file")
	fi
	[ -n "$instruction" ] || instruction="$_DEFAULT_INSTRUCTION"
	if [ -n "$rules_text" ]; then
		instruction="$instruction

$rules_text"
	fi

	original_content=$(cat -- "$file")
	# 絶対パスは書かない。ファイル名(拡張子)まではモデルへの推敲の手がかりに
	# なるので渡すが、agy が到達できる形の手がかり(ディレクトリ構造)は渡さない。
	body_prompt="$instruction

対象ファイル名: $(basename -- "$file")

--- 本文 ---
${original_content}"

	tmp_out=$(mktemp)
	orig_copy=$(mktemp)
	check_json=$(mktemp)
	followup_txt=$(mktemp)
	diff_file=$(mktemp)
	_tmp_paths+=("$tmp_out" "$orig_copy" "$check_json" "$followup_txt" "$diff_file")
	printf '%s\n' "$original_content" >"$orig_copy"

	_call_agy "$body_prompt" "$tmp_out"
	cid="$_last_cid"

	# 照合 → 合わなければ同じ会話の次のターンでずれた箇所を名指しして直させる。
	# 文書は送り直さない(会話が保持しているので、直す箇所だけを言えばよい)。
	# 上限に達したら最後の結果と「何が合わなかったか」を出して終わる。
	# 直っていないものを直ったことにはしない。
	_ensure_facts_py
	followups=0
	check_status=""
	check_summary=""
	while :; do
		set +e
		check_out=$(python3 "$_facts_py" "$orig_copy" "$tmp_out" "$check_json" "$followup_txt" 2>&1)
		check_rc=$?
		set -e
		if [ "$check_rc" -ne 0 ]; then
			echo "agy-run.sh: 事実照合の実行に失敗した" >&2
			printf '%s\n' "$check_out" | sed 's/^/    /' >&2
			exit 1
		fi
		check_status=$(printf '%s\n' "$check_out" | sed -n '1p')
		check_summary=$(printf '%s\n' "$check_out" | sed '1d')
		[ "$check_status" = "match" ] && break
		[ "$followups" -ge "$max_followups" ] && break
		if [ -z "$cid" ]; then
			echo "agy-run.sh: 会話 ID が取れなかったので聞き直せない" >&2
			break
		fi
		followups=$((followups + 1))
		echo "agy-run.sh: 事実照合が合わなかったので聞き直す(${followups}/${max_followups} 回目)" >&2
		printf '%s\n' "$check_summary" | sed 's/^/    /' >&2
		retry_out=$(mktemp)
		_tmp_paths+=("$retry_out")
		if ! _call_agy "$(cat -- "$followup_txt")" "$retry_out" "$cid"; then
			echo "agy-run.sh: 聞き直しが失敗した。直前の結果をそのまま返す" >&2
			break
		fi
		cat -- "$retry_out" >"$tmp_out"
	done

	# 上の対策(絶対パスを渡さない・CWD を隔離する・フックで deny する)で
	# 塞いだつもりでも、最後に実物を照合して契約を保つ。変わっていたら退避して
	# あった内容へ戻し、その事実(異常)を stderr に警告する。
	# 残っている到達経路は絶対パスでの書き込みだけ。agy の run_command は
	# enableTerminalSandbox: true により CWD が ~/.gemini/antigravity-cli/scratch へ
	# 固定されるので(実測)、相対パスでは呼び出し元のファイルに届かない。
	# フックは ~/.gemini/config/hooks.json に依存し、それが消えれば無音で
	# 効力を失う。この照合はフックが消えても残る最後の段。
	current_content=$(cat -- "$file")
	if [ "$current_content" != "$original_content" ]; then
		printf '%s' "$original_content" >"$file"
		echo "agy-run.sh: 警告 — agy が呼び出し中に元ファイル ${file} を書き換えた(本来 --file モードは元ファイルを変更しない契約)。退避しておいた元の内容へ書き戻した。書き換わったこと自体が異常であり、原因(prompt へのパス漏れや agy 側の設定変化)を調べること。" >&2
	fi

	orig_chars=$(printf '%s' "$original_content" | wc -m | tr -d ' ')
	new_chars=$(wc -m <"$tmp_out" | tr -d ' ')
	echo "agy-run.sh: 元 ${orig_chars} 文字 / 結果 ${new_chars} 文字(差 $((new_chars - orig_chars)))" >&2

	if [ "$check_status" = "match" ]; then
		echo "agy-run.sh: 事実照合(数値・URL・箇条書きと見出しの数)は合致(聞き直し ${followups} 回)" >&2
	else
		echo "agy-run.sh: 警告 — 事実照合が最後まで合わなかった(聞き直し ${followups} 回)。残っているずれ:" >&2
		printf '%s\n' "$check_summary" | sed 's/^/    /' >&2
	fi
	echo "agy-run.sh: 機械で照合していない — 固有名詞(機械では判定できない)と、箇条書き・見出し以外の散文中の項目。ここは人が読むこと。" >&2

	# diff は 0(差分なし)/1(差分あり)のどちらでも正常系。2以上だけ異常。
	set +e
	diff -u --label "a/${file}" --label "b/${file}(agy案)" "$file" "$tmp_out" >"$diff_file"
	diff_rc=$?
	set -e
	if [ "$diff_rc" -ge 2 ]; then
		echo "agy-run.sh: diff の実行自体が失敗した (rc=${diff_rc})" >&2
		exit "$diff_rc"
	fi

	# --json のときは標準出力を payload 専用にし、人向けの diff は標準エラーへ
	# 回す。両方を標準出力へ出すと、どちらの読み手にとっても読めないものになる。
	if [ "$want_json" -eq 1 ]; then
		cat -- "$diff_file" >&2
		_emit_payload file "$diff_file" "$tmp_out" "$check_json" "$orig_chars" "$new_chars"
	else
		cat -- "$diff_file"
	fi
	exit 0
fi

if [ -n "$prompt_file" ]; then
	[ -f "$prompt_file" ] || {
		echo "agy-run.sh: prompt file not found: $prompt_file" >&2
		exit 1
	}
	prompt=$(cat -- "$prompt_file")
elif [ -z "$prompt" ]; then
	echo "agy-run.sh: --file か --prompt か --prompt-file のいずれかが必須" >&2
	usage
fi

if [ -n "$rules_text" ]; then
	prompt="$prompt

$rules_text"
fi

# --prompt / --prompt-file では事実照合を行わない。ここは書き直しではなく
# 相談で、比較の基準になる元文が無い(プロンプト全文と回答を突き合わせると、
# 指示文に含まれる数値まで差分として並び、意味のある照合にならない)。
# payload にもその旨を書く —— 照合していないことを黙らない。
tmp_out=$(mktemp)
_tmp_paths+=("$tmp_out")
_call_agy "$prompt" "$tmp_out"
cid="$_last_cid"

prompt_chars=$(printf '%s' "$prompt" | wc -m | tr -d ' ')
result_chars=$(wc -m <"$tmp_out" | tr -d ' ')
echo "agy-run.sh: プロンプト ${prompt_chars} 文字 / 結果 ${result_chars} 文字" >&2
echo "agy-run.sh: 事実照合は行っていない(--prompt モードには比較対象の元文が無い)" >&2

if [ "$want_json" -eq 1 ]; then
	cat -- "$tmp_out" >&2
	_emit_payload prompt "" "$tmp_out" "" "$prompt_chars" "$result_chars"
else
	cat -- "$tmp_out"
fi
