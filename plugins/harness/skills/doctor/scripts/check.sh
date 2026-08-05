#!/usr/bin/env bash
# harness-template v0.7.0 — ベストプラクティス遵守を機械的に検査する(読み取り専用)。
#
# 設計意図(2026-08-05):
#   機械判定できる項目だけを確定的に検査する。スキルやハーネスを作った直後に
#   「本当に守れているか」を答えるのが目的。
#
#   判定基準の出典はベストプラクティス記事(要旨は ../references/audit-*.md)。
#   ただし**閾値や規約は Claude Code 側の仕様変更で陳腐化する**ので、SKILL.md の
#   「判定基準そのものを疑うとき」で一次情報を確認したら、ここの数字も見直すこと。
#
#   読み取り専用・必ず exit 0(検査が作業を止めない)。指摘は ⚠️、致命は ✗、良好は ✓。
set -uo pipefail

CLAUDE_MD_MAX=200      # ルート CLAUDE.md の推奨上限(記事の明示値)
SECTION_MAX=30         # CLAUDE.md 内の1節がこれを超えたら skill 化を検討
findings=0

note() { printf '  %s\n' "$*"; }
warn() { printf '  ⚠️ %s\n' "$*"; findings=$((findings+1)); }
bad()  { printf '  ✗ %s\n' "$*"; findings=$((findings+1)); }
ok()   { printf '  ✓ %s\n' "$*"; }

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || exit 0
echo "=== harness:doctor — $(basename "$root") ==="

# --- CLAUDE.md ---------------------------------------------------------------
echo
echo "## CLAUDE.md(常時ロード = 全行が毎セッションのコスト)"
if [ ! -e CLAUDE.md ]; then
  warn "CLAUDE.md が無い(プロジェクトの基盤情報が毎回ゼロから推測される)"
else
  lines=$(wc -l < CLAUDE.md | tr -d ' ')
  if [ "$lines" -gt "$CLAUDE_MD_MAX" ]; then
    warn "CLAUDE.md が ${lines} 行(推奨 ${CLAUDE_MD_MAX} 行以下)。長いほど指示の見落としが増える — 手順は skill、ファイル限定の制約は paths 付き rules へ"
  else
    ok "CLAUDE.md ${lines} 行(推奨 ${CLAUDE_MD_MAX} 行以下)"
  fi
  # 「毎回X したら Y」= 指示は必ず守られるとは限らない → Hook が正解(記事のアンチパターン)。
  if grep -nE '毎回|必ず[^。]*(実行|走ら|チェック)|する前に必ず|常に.*(実行|確認)' CLAUDE.md >/dev/null 2>&1; then
    warn "CLAUDE.md に「毎回/必ず〜する」系の自動化指示がある。指示は守られないことがあるので Hook(決定論的)へ移すのが正解:"
    grep -nE '毎回|必ず[^。]*(実行|走ら|チェック)|する前に必ず|常に.*(実行|確認)' CLAUDE.md | head -3 | sed 's/^/       /'
  fi
  # 「絶対に〜するな」= 長いセッションで破綻しうる → permissions/hooks で強制するのが正解。
  if grep -nE '絶対に[^。]*(な|禁止)|してはいけない|しないこと' CLAUDE.md >/dev/null 2>&1; then
    warn "CLAUDE.md に強い禁止指示がある。サーバー側(permissions / PreToolUse hook)で止める方が確実:"
    grep -nE '絶対に[^。]*(な|禁止)|してはいけない|しないこと' CLAUDE.md | head -3 | sed 's/^/       /'
  fi
  # 長い手順が埋まっていないか(節ごとの行数)。
  awk '/^## /{if(name && n>'"$SECTION_MAX"') print "       " name " (" n " 行)"; name=$0; n=0; next} {n++} END{if(name && n>'"$SECTION_MAX"') print "       " name " (" n " 行)"}' CLAUDE.md > /tmp/.doctor_sections 2>/dev/null
  if [ -s /tmp/.doctor_sections ]; then
    warn "CLAUDE.md に長い節がある(${SECTION_MAX} 行超)。手順なら skill へ移すと常時コストが消える:"
    cat /tmp/.doctor_sections
  fi
  rm -f /tmp/.doctor_sections
fi

# --- rules -------------------------------------------------------------------
echo
echo "## .claude/rules(paths 付きなら該当ファイル操作時のみロード)"
if [ ! -d .claude/rules ]; then
  note "rules 無し"
else
  for f in .claude/rules/*.md; do
    [ -e "$f" ] || continue
    if ! head -1 "$f" | grep -q '^---'; then
      warn "$(basename "$f"): frontmatter が無い = 常時ロード。paths を付けると無関係な作業でのコストが消える"
      continue
    fi
    if ! awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f' "$f" | grep -q '^paths:'; then
      warn "$(basename "$f"): paths: が無い = 常時ロード"
      continue
    fi
    # ⚠️ 最重要: glob が1つも実ファイルにマッチしないと silent に無効化される
    #    (swift-mcp-app で 2026-07-22 に実際に起きた。CLAUDE.md は「自動ロード」と
    #     書いてあったのに、TypeScript 用の src/** を Swift リポへ持ち込んで死んでいた)。
    globs=$(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f' "$f" | awk '/^paths:/{p=1;next} p&&/^[a-zA-Z]/{exit} p' | grep -oE '"[^"]+"' | tr -d '"')
    matched=0
    for g in $globs; do
      # ** を含む glob は git ls-files のパターンで概ね評価できる
      if git ls-files -- "$g" 2>/dev/null | head -1 | grep -q .; then matched=1; break; fi
    done
    if [ "$matched" -eq 1 ]; then
      ok "$(basename "$f"): paths 有効(マッチするファイルあり)"
    else
      bad "$(basename "$f"): paths がどのファイルにもマッチしない = 一度もロードされない。glob をこのリポジトリの構成に合わせること: $(echo "$globs" | tr '\n' ' ')"
    fi
  done
fi

# --- 個人設定の混入 -----------------------------------------------------------
echo
echo "## 個人環境の分離"
if git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
  bad ".claude/settings.local.json が git 追跡されている(個人の permission が共有される)。git rm --cached で外すこと"
elif grep -qs 'settings.local.json' .gitignore; then
  ok ".claude/settings.local.json は gitignore 済み"
else
  warn ".gitignore に .claude/settings.local.json が無い(生成されるとコミットされうる)"
fi

# --- ハーネス本体 -------------------------------------------------------------
echo
echo "## セッション引き継ぎハーネス"
nd=""
for cand in docs/next-directions.md docs/*/next-directions.md; do
  [ -f "$cand" ] && { nd="$cand"; break; }
done
if [ -z "$nd" ]; then
  warn "next-directions.md が無い(セッション間の引き継ぎが会話履歴頼みになる)。/harness:init で導入できる"
else
  ok "正典: $nd"
  if grep -q '^<!-- session-head-end' "$nd"; then
    head_lines=$(( $(grep -n '^<!-- session-head-end' "$nd" | head -1 | cut -d: -f1) - 1 ))
    [ "$head_lines" -gt 80 ] && warn "頭が ${head_lines} 行(目安 80)。棚卸しを検討" || ok "頭 ${head_lines} 行"
  else
    # pointer 方式(マーケットプレイス型)なら頭注入しないのでマーカーは不要。
    if grep -qs 'next-directions' .claude/hooks/session-start.sh 2>/dev/null; then
      note "マーカー無し(pointer 方式のフックなら正常)"
    else
      warn "$nd に session-head-end マーカーが無い(頭注入型フックでは fail-closed で止まる)"
    fi
  fi
  # 鮮度: 現在地の日付より新しいコミットがあるか。
  hd=$(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$nd" | head -1)
  lc=$(git log -1 --format=%cs 2>/dev/null)
  if [ -n "$hd" ] && [ -n "$lc" ] && [ "$lc" \> "$hd" ]; then
    warn "正典の日付($hd)より新しいコミット($lc)がある = 更新漏れの可能性"
  fi
fi
[ -e .claude/hooks/session-start.sh ] && ok "SessionStart フックあり" || warn "SessionStart フックが無い(正典が自動で思い出されない)"
if [ -x .githooks/pre-push ]; then
  # core.hooksPath は相対(.githooks)でも絶対(/path/to/repo/.githooks)でも設定できる。
  # 文字列一致で見ると絶対パス設定を「未配線」と誤検知するので、末尾で判定する。
  hp=$(git config core.hooksPath 2>/dev/null || true)
  case "$hp" in
    .githooks|*/.githooks) ok "pre-push 配線済み" ;;
    "") bad ".githooks/pre-push はあるが core.hooksPath 未設定 = 動いていない。git config core.hooksPath .githooks" ;;
    *) warn ".githooks/pre-push はあるが core.hooksPath が別の場所($hp)を指している" ;;
  esac
else
  warn "pre-push が無い(壊れたコードが main へ push されうる)"
fi

# --- skills ------------------------------------------------------------------
echo
echo "## skills"
found_skill=0
for s in .claude/skills/*/SKILL.md plugins/*/skills/*/SKILL.md; do
  [ -e "$s" ] || continue
  found_skill=1
  d=$(dirname "$s"); n=$(basename "$d")
  head -1 "$s" | grep -q '^---' || { bad "$n: frontmatter が無い"; continue; }
  fm=$(awk 'NR==1&&/^---/{g=1;next} g&&/^---/{exit} g' "$s")
  echo "$fm" | grep -q '^name:' || warn "$n: name が無い"
  # description は YAML の折り畳みスカラー(`description: >-` + 字下げ続き行)で書かれることが
  # 多い。1行目だけ見ると空に見えて「短い」と誤検知するので、続き行も連結して測る。
  desc_len=$(printf '%s' "$fm" | python3 -c '
import sys
lines = sys.stdin.read().split("\n")
out, capture = [], False
for ln in lines:
    if ln.startswith("description:"):
        rest = ln[len("description:"):].strip()
        if rest in (">", ">-", "|", "|-"):
            capture = True
        else:
            out.append(rest)
        continue
    if capture:
        if ln.startswith((" ", "\t")):
            out.append(ln.strip())
        else:
            capture = False
print(len(" ".join(out).strip()))
' 2>/dev/null || echo 0)
  if [ "${desc_len:-0}" -eq 0 ]; then
    warn "$n: description が無い(自動トリガーされない)"; continue
  fi
  [ "$desc_len" -lt 40 ] && warn "$n: description が ${desc_len} 字と短い。いつ使うかが書かれていないと自動で呼ばれない"
  # scripts があるなら実行可能か(chmod 忘れは頻出)
  for sc in "$d"/scripts/*.sh; do
    [ -e "$sc" ] || continue
    [ -x "$sc" ] || bad "$n: $(basename "$sc") に実行権限が無い"
  done
done
[ "$found_skill" -eq 1 ] || note "skill 無し"

echo
if [ "$findings" -eq 0 ]; then
  echo "指摘なし。"
else
  echo "指摘 ${findings} 件。各指摘の意味と直し方はこの skill の本文を参照。"
fi
exit 0
