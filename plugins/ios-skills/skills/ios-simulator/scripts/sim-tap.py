#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""アクセシビリティ・ラベルで要素を探し、その中心(points)を idb でタップする。

Why: スクショ座標(pixels)から座標変換してタップするのは scale ズレの温床。
`idb ui describe-all` は各要素の frame を points で返すので、目的要素の中心を直接タップすれば
スケール変換もスクショ座標も一切要らない — これが「918px/402pt ズレ」を根絶する最短経路。

★このスクリプトの根本的な限界(必ず知っておくこと):
  `idb ui tap` は **当たっても外れても無言で exit 0 を返す**(実測)。したがって
  「subprocess.run(check=True) が通った = タップが効いた」ではない。ここを取り違えたことが
  2026-08-01 の一連の誤診(「pt では効かない、px が正解だ」という誤結論)の根っこだった。
  **効いたことを確認したいなら sim-act.py(tap → assert → リトライ)を使う。**
  このスクリプトは「1回撃つだけ」の低レベルプリミティブとして残してある。

Why UDID 必須(2026-08-01 変更・後方互換を意図的に壊した):
  旧版は内部の `idb ui tap` に --udid を渡しておらず、companion が複数繋がっていると
  どの端末へ飛ぶか不定だった(同日、姉妹スクリプトの sim-shot.sh が同じ理由で
  他エージェントの端末を撮る事故を起こしている)。4本すべて --udid か環境変数 SIM_UDID を
  必須にして、「省略したら暗黙に何かへ飛ぶ」経路を構造的に塞ぐ。
  ボツ案: idb 標準の IDB_UDID 環境変数にフォールバックする
    → idb 自身の仕様に乗る方が筋は良いが、このスキルの4本で名前が割れると
      「sim-shot は SIM_UDID、sim-tap は IDB_UDID」という覚え違いの事故が起きる。統一を優先した。

uv の PEP 723 インラインスクリプトとして実行する(事前 pip 不要・stdlib のみ)。
  ./scripts/sim-tap.py "続ける" --udid EF5D841C-...
  SIM_UDID=EF5D841C-... ./scripts/sim-tap.py "続ける" --index 1   # 同名複数は 0 始まりで選ぶ
  ./scripts/sim-tap.py "URL" --udid ... --duration 0.05           # 短いタップを明示(下記参照)
"""
import argparse
import json
import os
import subprocess
import sys


def iter_elements(node):
    """describe-all の JSON を歩いて「要素っぽい dict」だけを文書順に列挙する。

    Why 再帰: `idb ui describe-all --json` は現行版では **flat な JSON 配列**を返すが、
    過去には**入れ子の JSON 配列**を返す形も観測されている(SKILL.md の「JSONL ではない」節)。
    `for line in stdin: json.loads(line)` はもちろん、`list(data)` の flat 前提も
    バージョン差で壊れる。frame(x/y/width/height を持つ dict)を目印に再帰で拾えば両方に効く。

    ボツ案: トップレベルが list ならそのまま要素配列とみなす(旧実装)
      → flat のときだけ正しい。入れ子だと「1要素も見つからない」ではなく
        「意味のない dict をタップ候補にする」形で静かに壊れるので、目印での判定にした。
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
    """idb ui describe-all --udid <udid> の要素を配列で返す。"""
    try:
        raw = subprocess.run(
            ["idb", "ui", "describe-all", "--udid", udid, "--json"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except FileNotFoundError:
        sys.exit("idb が見つからない。uv tool install fb-idb で導入し、idb connect <UDID> で接続してからリトライ。")
    except subprocess.CalledProcessError as e:
        sys.exit(f"idb ui describe-all に失敗: {e.stderr.strip() or e}\n  → idb list-targets で当該 UDID の companion 接続を確認。")
    if not raw:
        sys.exit("アクセシビリティ要素が空。アプリが前面に出ているか確認。")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = [json.loads(line) for line in raw.splitlines() if line.strip()]
    return list(iter_elements(data))


def matches(el: dict, query: str) -> bool:
    """AXLabel / AXValue / title などに query を部分一致(大文字小文字無視)。"""
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


def main() -> None:
    ap = argparse.ArgumentParser(description="ラベル一致要素の中心(points)を idb でタップ")
    ap.add_argument("label", help="AXLabel/AXValue 等への部分一致文字列")
    ap.add_argument("--udid", default=None, help="対象 simulator の UDID(省略時は環境変数 SIM_UDID)")
    ap.add_argument("--index", type=int, default=0, help="同名要素が複数ある時の選択(0始まり)")
    ap.add_argument("--dry-run", action="store_true", help="タップせず座標だけ表示")
    # Why --duration の使い分け(FEEDBACK 2026-08-01 §7 の実測):
    #   > 0.5 は long-press 相当。一方 **既定 duration のままでも、テキストが入っている入力欄では
    #   選択メニュー(Select / Select All / AutoFill)が出てしまうこと**がある。
    #   「短いタップ」を意図しているなら --duration 0.05 を明示した方が挙動が安定した。
    #   既定を 0.05 にしてしまう案はボツ: 既定値を変えると既存の呼び出しの意味が黙って変わる。
    #   明示させる方が、後からログを読んだときに意図が分かる。
    ap.add_argument("--duration", type=float, default=None,
                    help="タップ長押し秒。>0.5 で long-press 相当 / 0.05 で『確実に短いタップ』")
    args = ap.parse_args()

    udid = resolve_udid(args.udid)

    hits = [(el, c) for el in describe_all(udid) if matches(el, args.label) and (c := center(el))]
    if not hits:
        sys.exit(
            f"ラベル '{args.label}' に一致する要素が無い。\n"
            f"  → scripts/sim-shot.sh --udid {udid} で画面を確認するか語を変えてリトライ。\n"
            "  → 要素が1個だけ・frame が全部 0 で返るなら、それは『対象アプリが前面にいない』印。\n"
            f"    xcrun simctl launch --terminate-running-process {udid} <bundle-id> して数秒待つ。"
        )
    if args.index >= len(hits):
        sys.exit(f"index {args.index} は範囲外(一致 {len(hits)} 件)。")

    (_, (x, y)) = hits[args.index]
    n = len(hits)
    print(f"tap ({x}, {y}) points  [ラベル '{args.label}' に一致 {n} 件中 index {args.index}]  udid={udid}")
    if args.dry_run:
        return

    cmd = ["idb", "ui", "tap", "--udid", udid, str(x), str(y)]
    if args.duration is not None:
        cmd += ["--duration", str(args.duration)]
    subprocess.run(cmd, check=True)
    # 「撃った」と「効いた」は別。ここで嘘の安心を与えないよう毎回添える(実地の誤診対策)。
    print("note: idb ui tap は当たっても外れても exit 0。効果の確認は describe-all の撮り直しか sim-act.py で。")


if __name__ == "__main__":
    main()
