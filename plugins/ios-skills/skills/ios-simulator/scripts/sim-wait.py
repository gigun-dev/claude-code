#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""アクセシビリティ・ラベルが現れる(または消える)までポーリングして待つ。

Why: sim-tap.py は「今この瞬間の describe-all」を1回読んで即タップする。だがアニメーション中や
非同期処理(接続中スピナー・API 待ちなど)は要素がまだ存在しない/まだラベルが変わっていない
瞬間に当たりやすい。「無いなら無いで即エラー」ではなく「出るまで待つ」を単独コマンドとして
切り出しておくと、tap 前の事前条件チェックにも、tap 後の事後条件チェック(= sim-act.py の内部)
にも同じロジックを使い回せる。

ボツ案: sim-tap.py に --wait フラグを足して1本に統合する
  → 「待つだけ」(タップしない)ユースケースが独立して要る
    (例: 「起動直後にホーム画面が出るまで待って良否だけ判定したい」)。
    1本に混ぜると「待つのか撃つのか」が呼び出し側から読めなくなる。

Why UDID 必須(booted 排除): このスキルは複数 simulator を並行稼働させる運用を前提にしており、
`booted` は「複数 booted なら不定」という事故を起こす(実地で踏んだ: sim-shot.sh が
`simctl io booted screenshot` で無関係な端末を撮ってしまった)。
idb 自体は --udid 省略時に IDB_UDID 環境変数へフォールバックする仕様があるが、
このスキル内では SIM_UDID に統一する(名前が割れると覚え違いの事故が起きる)。
"""
import argparse
import json
import os
import subprocess
import sys
import time

# ---- 終了コード(このスキルの全スクリプトで統一。--help にも同じ表を出す) ----
EX_OK, EX_USAGE, EX_DEVICE, EX_NOTFOUND, EX_TIMEOUT, EX_IDB, EX_ENV = 0, 2, 3, 4, 5, 6, 7

EXIT_CODES_HELP = """終了コード(このスキルの全スクリプト共通):
  0 成功 / 2 引数不正 / 3 端末が見つからない・Booted でない / 4 要素が見つからない
  5 タイムアウト / 6 idb 未導入・companion 未接続・idb 失敗 / 7 前提不足(外部ツール等)"""

IDB_TIMEOUT = 30.0  # 1回の describe-all の上限。非対話シェルで無限待ちを作らないため。


def fail(code: int, *lines: str) -> None:
    print("\n".join(lines), file=sys.stderr)
    sys.exit(code)


def iter_elements(node):
    """describe-all の JSON を歩いて「要素っぽい dict」だけを文書順に列挙する。

    Why 再帰: 現行の `idb ui describe-all --json` は flat な JSON 配列を返すが、
    過去には**入れ子の JSON 配列**を返す形も観測されている(SKILL.md「JSONL ではない」節)。
    frame(x/y/width/height を持つ dict)を目印に再帰で拾えば両方の形に効く。
    sim-tap.py / sim-act.py / sim-nav.py と同一実装(スクリプト単体で完結させる方針で意図的に非共有)。
    """
    if isinstance(node, list):
        for item in node:
            yield from iter_elements(item)
        return
    if isinstance(node, dict):
        f = node.get("frame")
        if isinstance(f, dict) and all(isinstance(f.get(k), (int, float)) for k in ("x", "y", "width", "height")):
            yield node
        for v in node.values():
            yield from iter_elements(v)


def describe_all(udid: str) -> list[dict]:
    """idb ui describe-all の要素を配列で返す(配列/入れ子/JSON-lines 対応)。

    アプリが前面に無い/companion 未接続だと空文字列や CalledProcessError になりうるが、
    ポーリング中の一過性の失敗で全体を落とすと使い勝手が悪い(接続中の一瞬だけ describe-all が
    コケることが実地であった)ので、呼び出し側でリトライできるよう例外は投げず空配列を返す。
    ただし **idb が存在しない**のは一過性ではないので即 EX_IDB で落とす(待っても直らない)。
    """
    try:
        raw = subprocess.run(
            ["idb", "ui", "describe-all", "--udid", udid, "--json"],
            capture_output=True, text=True, check=True, timeout=IDB_TIMEOUT,
        ).stdout.strip()
    except FileNotFoundError:
        fail(EX_IDB, "idb が見つからない。",
             "  → uv tool install fb-idb で導入し、idb connect <UDID> で接続してからリトライ。")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return []
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = [json.loads(line) for line in raw.splitlines() if line.strip()]
    return list(iter_elements(data))


def matches(el: dict, query: str) -> bool:
    """AXLabel / AXValue / title などに query を部分一致(大文字小文字無視)。sim-tap.py と同一ロジック。"""
    q = query.lower()
    for key in ("AXLabel", "AXValue", "AXIdentifier", "title", "label", "value"):
        v = el.get(key)
        if isinstance(v, str) and q in v.lower():
            return True
    return False


def center(el: dict) -> tuple[int, int] | None:
    f = el.get("frame") or {}
    try:
        x, y, w, h = f["x"], f["y"], f["width"], f["height"]
    except (KeyError, TypeError):
        return None
    return round(x + w / 2), round(y + h / 2)


def resolve_udid(cli_udid: str | None) -> str:
    """--udid > 環境変数 SIM_UDID の順で解決。両方無ければ即エラー(booted 禁止の構造化)。"""
    udid = cli_udid or os.environ.get("SIM_UDID")
    if not udid:
        fail(EX_USAGE,
             "UDID 未指定。--udid <UDID> か環境変数 SIM_UDID を指定すること。",
             "  → xcrun simctl list devices booted で対象を確認してから明示する",
             "    (複数 booted は現実に起きる。実地で4台同時 booted の日があり、'booted' 指定は",
             "     不定に化けて他人の端末へ飛ぶ事故になったため、意図的に必須化している)。",
             "  → scripts/sim-preflight.sh --udid <UDID> で環境ごと確認するのが早い。")
    return udid


def ensure_booted(udid: str) -> None:
    """指定 UDID が Booted か確認する。違えば Booted 一覧を添えて EX_DEVICE(sim-tap.py と同一実装)。"""
    try:
        out = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                             capture_output=True, text=True, timeout=30).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return
    if udid.upper() in out.upper():
        return
    fail(EX_DEVICE,
         f"UDID '{udid}' は Booted な端末として見つからない。",
         "  → 現在 Booted な端末:",
         out.rstrip() or "    (なし)",
         f"  → 起動するなら xcrun simctl boot \"{udid}\"(他人が使っている端末を落とさないこと)。")


def find(udid: str, label: str, index: int) -> tuple[dict, tuple[int, int]] | None:
    hits = [(el, c) for el in describe_all(udid) if matches(el, label) and (c := center(el))]
    if index >= len(hits):
        return None
    return hits[index]


def main() -> None:
    ap = argparse.ArgumentParser(
        description="ラベル一致要素が describe-all に現れる(--gone なら消える)まで待つ",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""stdout(JSON): {{"status":"found","label":"...","x":201,"y":654,"frame":{{...}}}}
        または {{"status":"gone","label":"..."}}。経過は stderr(--verbose 時)。

{EXIT_CODES_HELP}
  ※ 待っても条件が満たされなかった場合は 5(タイムアウト)。

使用例:
  scripts/sim-wait.py "続ける" --udid EF5D841C-...
  SIM_UDID=EF5D841C-... scripts/sim-wait.py "接続中" --gone --timeout 20""")
    ap.add_argument("label", help="AXLabel/AXValue 等への部分一致文字列")
    ap.add_argument("--udid", default=None, help="対象 simulator の UDID(省略時は環境変数 SIM_UDID)")
    ap.add_argument("--timeout", type=float, default=15.0, help="待機上限秒(既定 15)")
    ap.add_argument("--interval", type=float, default=0.4, help="ポーリング間隔秒(既定 0.4)")
    ap.add_argument("--index", type=int, default=0, help="同名要素が複数ある時の選択(0始まり)")
    ap.add_argument("--gone", action="store_true", help="逆モード: 要素が消える(見えなくなる)まで待つ")
    ap.add_argument("--verbose", action="store_true", help="ポーリング経過を stderr に出す")
    args = ap.parse_args()

    udid = resolve_udid(args.udid)
    ensure_booted(udid)
    deadline = time.monotonic() + args.timeout

    while True:
        hit = find(udid, args.label, args.index)
        found = hit is not None
        # --gone なら「消えた」が成功条件、通常は「現れた」が成功条件。
        if found != args.gone:
            if args.gone:
                print(json.dumps({"status": "gone", "label": args.label}, ensure_ascii=False))
            else:
                el, (x, y) = hit
                print(json.dumps(
                    {"status": "found", "label": args.label, "x": x, "y": y, "frame": el.get("frame")},
                    ensure_ascii=False,
                ))
            return
        if time.monotonic() >= deadline:
            verb = "消える" if args.gone else "現れる"
            fail(EX_TIMEOUT,
                 f"タイムアウト({args.timeout}s): ラベル '{args.label}' が{verb}のを確認できなかった。",
                 f"  → scripts/sim-shot.sh --udid {udid} で現在の画面を確認するか、ラベル文言・timeout を見直す。",
                 "  → describe-all が要素1個・frame 全部 0 を返しているなら、それは AX/HID の故障ではなく",
                 f"    『対象アプリが前面にいない』印。xcrun simctl launch --terminate-running-process {udid} "
                 "<bundle-id> して数秒待つ。")
        if args.verbose:
            print(f"waiting... ({args.label!r}, gone={args.gone}, 残り {deadline - time.monotonic():.1f}s)",
                  file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
