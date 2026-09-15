# plugins/worktree の bin/sweep と bin/integrate が共有する判定ロジック。
# source して使う。関数だけを定義し、副作用は持たない。

# 既定ブランチを解決する。$1=root。標準出力に "base_ref\tbase_display" を返す。
# 失敗すれば標準エラーに理由を書いて rc=1。
resolve_base() {
  local root="$1" base rc local_branch base_ref base_display
  base=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  rc=$?
  if [ "$rc" -eq 1 ]; then
    base=main
  elif [ "$rc" -ne 0 ]; then
    echo "基準ブランチ取得失敗" >&2
    return 1
  fi
  # 基準はローカルの既定ブランチにする。統合はローカルで起きる(squash マージ含む)ため、
  # origin/HEAD がローカルより遅れていると取込済みの worktree まで未取込と誤判定する。
  case "$base" in
    origin/*) local_branch=${base#origin/} ;;
    *) local_branch=$base ;;
  esac
  if git -C "$root" show-ref --verify --quiet "refs/heads/$local_branch"; then
    base_ref="refs/heads/$local_branch"
    base_display="$local_branch (ローカル)"
  else
    base_ref="$base"
    base_display="$base"
  fi
  printf '%s\t%s\n' "$base_ref" "$base_display"
}

# squash 判定。$1=root $2=base_oid $3=head を受け取り、標準出力に
# "yes"|"no"|"undetermined" のいずれかと、理由の 1 行を tab 区切りで返す。
# rc は常に 0(判定自体の失敗は "undetermined" として理由に書く)。
#
# 判定できるのは「そのブランチが分岐後に触ったファイルが、基準ブランチと
# 差分なしか」だけ。基準側が独立に同じファイルを大きく変えていれば diff は
# 埋まらないので "no" に落ちる —— 「未取込」と「基準側が先に進んだ」を機械には
# 区別できない。活発なリポジトリでは "no"(人が決める)に落ちやすいのはこの
# ためで、判定の欠陥ではなく限界。integrate を主経路にすれば、取り込み直後に
# その場で片付けるので分岐点が古くならず、この限界に当たりにくい。
squash_equivalent() {
  local root="$1" base_oid="$2" head="$3"
  local merge_base
  if ! merge_base=$(git -C "$root" merge-base "$base_oid" "$head" 2>/dev/null); then
    printf 'undetermined\t共通の祖先が無く比較できない\n'
    return
  fi
  local touched=()
  while IFS= read -r -d '' f; do
    touched+=("$f")
  done < <(git -C "$root" diff --name-only -z "$merge_base" "$head" 2>/dev/null)
  if [ "${#touched[@]}" -eq 0 ]; then
    printf 'undetermined\t基準からの分岐後にブランチ固有の変更が見当たらず比較材料が無い\n'
    return
  fi
  local remaining
  if ! remaining=$(git -C "$root" diff "$base_oid" "$head" -- "${touched[@]}" 2>/dev/null); then
    printf 'undetermined\t差分の取得に失敗した\n'
    return
  fi
  local shown
  shown=$(printf '%s ' "${touched[@]:0:5}")
  if [ "${#touched[@]}" -gt 5 ]; then
    shown="${shown}他$(( ${#touched[@]} - 5 ))件"
  fi
  if [ -z "$remaining" ]; then
    printf 'yes\t触れた%d件のファイル(%s)が基準ブランチと差分なし\n' "${#touched[@]}" "$shown"
  else
    printf 'no\t触れた%d件のファイル(%s)のうち基準ブランチと差分が残るものがある\n' "${#touched[@]}" "$shown"
  fi
}
