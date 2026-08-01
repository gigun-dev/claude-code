#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""アクセシビリティ・ラベルが現れるまでポーリングして待つ。

Why: sim-tap.py は「今この瞬間の describe-all」を1回読んで即タップする。だがアニメーション中や
非同期処理(接続中スピナー・API 待ちなど)は要素がまだ存在しない/まだラベルが変わっていない
瞬間に当たりやすい。「無いなら無いで即エラー」ではなく「出るまで待つ」を単独コマンドとして
切り出しておくと、tap 前の事前条件チェックにも、tap 後の事後条件チェック(= sim-act.py の内部)
にも同じロジックを使い回せる。

ボツ案: sim-tap.py に --wait フラグを足して1本に統合する
  → task 指示が「既存2本は壊さない」なので、たとえ後方互換な追加でも触らない方針を貫く。
    加えて「待つだけ」(タップしない)ユースケースが独立して要る
    (例: 「起動直後にホーム画面が出るまで待って良否だけ判定したい」)。

Why UDID 必須(booted 排除): このリポジトリのタスクは複数 simulator を並行稼働させる運用を
前提にしており、`booted` は「複数 booted なら不定」という事故を起こす
(実地で踏んだ: sim-shot.sh が `simctl io booted screenshot` で無関係な端末を撮ってしまった。
2026-08-01 に4本すべて --udid 必須へ揃えた)。
idb 自体は --udid 省略時に IDB_UDID 環境変数へフォールバックする仕様があるので、
このスクリプトでは --udid か環境変数 SIM_UDID のどちらか必須にし、「省略したら暗黙に何かへ飛ぶ」
経路を構造的に塞ぐ(IDB_UDID を直接使わないのは、sim-shot.sh 用の慣習に揃えて
このリポジトリ内では SIM_UDID に統一するため)。

uv の PEP 723 インラインスクリプトとして実行する(事前 pip 不要・stdlib のみ)。
  ./scripts/sim-wait.py "続ける" --udid EF5D841C-...
  SIM_UDID=EF5D841C-... ./scripts/sim-wait.py "続ける" --timeout 20
"""
import argparse
import json
import os
import subprocess
import sys
import time


def iter_elements(node):
    """describe-all の JSON を歩いて「要素っぽい dict」だけを文書順に列挙する。

    Why 再帰: 現行の `idb ui describe-all --json` は flat な JSON 配列を返すが、
    過去には**入れ子の JSON 配列**を返す形も観測されている(SKILL.md「JSONL ではない」節)。
    frame(x/y/width/height を持つ dict)を目印に再帰で拾えば両方の形に効く。
    sim-tap.py / sim-act.py と同一実装(スクリプト単体で完結させる方針を踏襲して意図的に非共有)。
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
    """idb ui describe-all --udid <udid> の要素を配列で返す(配列/入れ子/JSON-lines 対応)。

    アプリが前面に無い/companion 未接続だと空文字列や CalledProcessError になりうるが、
    ポーリング中の一過性の失敗で全体を落とすと使い勝手が悪い(接続中の一瞬だけ describe-all が
    コケることが実地であった)ので、呼び出し側でリトライできるよう例外は投げず空配列を返す。
    """
    try:
        raw = subprocess.run(
            ["idb", "ui", "describe-all", "--udid", udid, "--json"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except FileNotFoundError:
        sys.exit("idb が見つからない。uv tool install fb-idb で導入し、idb connect <UDID> で接続してからリトライ。")
    except subprocess.CalledProcessError:
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
        sys.exit(
            "UDID 未指定。--udid <UDID> か環境変数 SIM_UDID を指定すること。\n"
            "  → xcrun simctl list devices booted で対象を確認してから明示する\n"
            "    (複数 booted は現実に起きる。実地で4台同時 booted の日があり、'booted' 指定は\n"
            "     不定に化けて他人の端末へ飛ぶ事故になったため、意図的に必須化している)。"
        )
    return udid


def find(udid: str, label: str, index: int) -> tuple[dict, tuple[int, int]] | None:
    hits = [(el, c) for el in describe_all(udid) if matches(el, label) and (c := center(el))]
    if index >= len(hits):
        return None
    return hits[index]


def main() -> None:
    ap = argparse.ArgumentParser(description="ラベル一致要素が describe-all に現れるまで待つ")
    ap.add_argument("label", help="AXLabel/AXValue 等への部分一致文字列")
    ap.add_argument("--udid", default=None, help="対象 simulator の UDID(省略時は環境変数 SIM_UDID)")
    ap.add_argument("--timeout", type=float, default=15.0, help="待機上限秒(既定 15)")
    ap.add_argument("--interval", type=float, default=0.4, help="ポーリング間隔秒(既定 0.4)")
    ap.add_argument("--index", type=int, default=0, help="同名要素が複数ある時の選択(0始まり)")
    ap.add_argument("--gone", action="store_true", help="逆モード: 要素が消える(見えなくなる)まで待つ")
    args = ap.parse_args()

    udid = resolve_udid(args.udid)
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
            sys.exit(
                f"タイムアウト({args.timeout}s): ラベル '{args.label}' が{verb}のを確認できなかった。\n"
                f"  → scripts/sim-shot.sh --udid {udid} で現在の画面を確認するか、"
                "ラベル文言・timeout を見直してリトライ。\n"
                "  → describe-all が要素1個・frame 全部 0 を返しているなら、それは AX/HID の故障ではなく\n"
                f"    『対象アプリが前面にいない』印。xcrun simctl launch --terminate-running-process {udid} "
                "<bundle-id> して数秒待つ。"
            )
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
