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
  **AXUniqueId が分かっているなら sim-nav.py の方が堅い**(ラベルは言語設定で変わるが
  識別子は変わらない — 2026-08-02 の実測)。このスクリプトは「ラベルで1回撃つだけ」の
  低レベルプリミティブとして残してある。

Why UDID 必須(2026-08-01 変更・後方互換を意図的に壊した):
  旧版は内部の `idb ui tap` に --udid を渡しておらず、companion が複数繋がっていると
  どの端末へ飛ぶか不定だった(同日、姉妹スクリプトの sim-shot.sh が同じ理由で
  他エージェントの端末を撮る事故を起こしている)。全スクリプトで --udid か環境変数 SIM_UDID を
  必須にして、「省略したら暗黙に何かへ飛ぶ」経路を構造的に塞ぐ。
  ボツ案: idb 標準の IDB_UDID 環境変数にフォールバックする
    → idb 自身の仕様に乗る方が筋は良いが、このスキルの中で名前が割れると
      「sim-shot は SIM_UDID、sim-tap は IDB_UDID」という覚え違いの事故が起きる。統一を優先した。

Why stdout は JSON(2026-08-02 変更): 公式ガイド「Use structured output」に合わせ、
  データ(座標・一致件数)は stdout に JSON、経過や注意書きは stderr に分離した。
  旧版は人間向けテキストを stdout に流していたため、パイプで繋ぐと座標が拾えなかった。
"""
import argparse
import json
import os
import subprocess
import sys

# ---- 終了コード(このスキルの全スクリプトで統一。--help にも同じ表を出す) ----
# Why 統一: エージェントは失敗の種類で次の一手を変える(端末が落ちている→boot、
#   要素が無い→スクショで確認、companion 未接続→idb connect)。1 に潰すとこの分岐ができない。
EX_OK, EX_USAGE, EX_DEVICE, EX_NOTFOUND, EX_TIMEOUT, EX_IDB, EX_ENV = 0, 2, 3, 4, 5, 6, 7

EXIT_CODES_HELP = """終了コード(このスキルの全スクリプト共通):
  0 成功 / 2 引数不正 / 3 端末が見つからない・Booted でない / 4 要素が見つからない
  5 タイムアウト / 6 idb 未導入・companion 未接続・idb 失敗 / 7 前提不足(外部ツール等)"""

# idb 呼び出しのハングを防ぐ上限。エージェントは非対話シェルなので、無限待ちは
# 「セッションごと詰まる」形の最悪の失敗になる(公式ガイド「Avoid interactive prompts」の趣旨)。
IDB_TIMEOUT = 30.0


def fail(code: int, *lines: str) -> None:
    """エラーは必ず「何が起きたか + 次の一手」を stderr に出してから終わる。"""
    print("\n".join(lines), file=sys.stderr)
    sys.exit(code)


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
            capture_output=True, text=True, check=True, timeout=IDB_TIMEOUT,
        ).stdout.strip()
    except FileNotFoundError:
        fail(EX_IDB, "idb が見つからない。",
             "  → uv tool install fb-idb で導入し、idb connect <UDID> で接続してからリトライ。")
    except subprocess.TimeoutExpired:
        fail(EX_IDB, f"idb ui describe-all が {IDB_TIMEOUT}s 応答しない。",
             "  → idb kill && idb connect <UDID> で companion を張り直してリトライ。")
    except subprocess.CalledProcessError as e:
        fail(EX_IDB, f"idb ui describe-all に失敗: {(e.stderr or '').strip() or e}",
             f"  → idb list-targets で {udid} の companion 接続を確認(No Companion Connected なら idb connect {udid})。")
    if not raw:
        fail(EX_NOTFOUND, "アクセシビリティ要素が空。",
             "  → 対象アプリが前面にいない可能性が高い。xcrun simctl launch --terminate-running-process "
             f"{udid} <bundle-id> して数秒待つ。")
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
        fail(EX_USAGE,
             "UDID 未指定。--udid <UDID> か環境変数 SIM_UDID を指定すること。",
             "  → xcrun simctl list devices booted で対象を確認してから明示する",
             "    (複数 booted は現実に起きる。実地で4台同時 booted の日があり、'booted' 指定は",
             "     不定に化けて他人の端末へ飛ぶ事故になったため、意図的に必須化している)。",
             "  → scripts/sim-preflight.sh --udid <UDID> で環境ごと確認するのが早い。")
    return udid


def ensure_booted(udid: str) -> None:
    """指定 UDID が Booted か確認する。違えば Booted 一覧を添えて EX_DEVICE。

    Why: 実走行で **シェル変数の展開ミスにより意図しない端末へ install/launch した**事故がある。
    UDID の打ち間違い・空文字はここで全部止める(idb 側のエラーは原因が読み取りにくい)。
    ボツ案: idb 側の失敗に任せる → 「No targets」等の曖昧な文言になり、
      端末が落ちているのか UDID が違うのか companion が死んでいるのか切り分けられない。
    """
    try:
        out = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                             capture_output=True, text=True, timeout=30).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return  # xcrun が無い/遅い環境では検査を諦める(検査のために本処理を落とさない)
    if udid.upper() in out.upper():
        return
    fail(EX_DEVICE,
         f"UDID '{udid}' は Booted な端末として見つからない。",
         "  → 現在 Booted な端末:",
         out.rstrip() or "    (なし)",
         f"  → 起動するなら xcrun simctl boot \"{udid}\"(他人が使っている端末を落とさないこと)。")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="ラベル一致要素の中心(points)を idb で1回タップする(効果の検証はしない)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""stdout(JSON): {{"status":"ok","x":201,"y":654,"matches":2,"index":0,"udid":"...","label":"..."}}
経過・注意書きは stderr。

{EXIT_CODES_HELP}

使用例:
  scripts/sim-tap.py "続ける" --udid EF5D841C-...
  SIM_UDID=EF5D841C-... scripts/sim-tap.py "続ける" --index 1   # 同名複数は 0 始まりで選ぶ
  scripts/sim-tap.py "URL" --udid ... --duration 0.05           # 確実に短いタップ
注意: idb ui tap は当たっても外れても exit 0。効果まで確認するなら sim-act.py / sim-nav.py。""")
    ap.add_argument("label", help="AXLabel/AXValue 等への部分一致文字列")
    ap.add_argument("--udid", default=None, help="対象 simulator の UDID(省略時は環境変数 SIM_UDID)")
    ap.add_argument("--index", type=int, default=0, help="同名要素が複数ある時の選択(0始まり)")
    ap.add_argument("--dry-run", action="store_true", help="タップせず座標だけ JSON で返す")
    # Why --duration の使い分け(FEEDBACK 2026-08-01 §7 の実測):
    #   > 0.5 は long-press 相当。一方 **既定 duration のままでも、テキストが入っている入力欄では
    #   選択メニュー(Select / Select All / AutoFill)が出てしまうこと**がある。
    #   「短いタップ」を意図しているなら --duration 0.05 を明示した方が挙動が安定した。
    #   既定を 0.05 にしてしまう案はボツ: 既定値を変えると既存の呼び出しの意味が黙って変わる。
    ap.add_argument("--duration", type=float, default=None,
                    help="タップ長押し秒。>0.5 で long-press 相当 / 0.05 で『確実に短いタップ』")
    args = ap.parse_args()

    udid = resolve_udid(args.udid)
    ensure_booted(udid)

    hits = [(el, c) for el in describe_all(udid) if matches(el, args.label) and (c := center(el))]
    if not hits:
        fail(EX_NOTFOUND,
             f"ラベル '{args.label}' に一致する要素が無い。",
             f"  → scripts/sim-shot.sh --udid {udid} で画面を確認するか語を変えてリトライ。",
             f"  → 識別子で撃つ方が堅い: scripts/sim-nav.py --udid {udid} --list で AXUniqueId 一覧を見る。",
             "  → 要素が1個だけ・frame が全部 0 で返るなら、それは『対象アプリが前面にいない』印。",
             f"    xcrun simctl launch --terminate-running-process {udid} <bundle-id> して数秒待つ。")
    if args.index >= len(hits):
        fail(EX_USAGE, f"--index {args.index} は範囲外(一致 {len(hits)} 件、0始まり)。",
             "  → --index を 0..%d の範囲で指定する。" % (len(hits) - 1))

    (_, (x, y)) = hits[args.index]
    result = {"status": "ok", "x": x, "y": y, "matches": len(hits), "index": args.index,
              "udid": udid, "label": args.label, "dry_run": bool(args.dry_run)}

    if not args.dry_run:
        # Why subprocess のリスト渡し: 実走行で `idb ui tap --udid $U $coords` と書いたシェルが
        # 「201 654」を1引数として渡してしまい、しかも stderr を捨てていたため失敗に気づかず
        # 誤った原因分析をした事故がある。単語分割に依存しない + stderr を握り潰さない。
        cmd = ["idb", "ui", "tap", "--udid", udid, str(x), str(y)]
        if args.duration is not None:
            cmd += ["--duration", str(args.duration)]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=IDB_TIMEOUT)
        if p.stderr.strip():
            print(p.stderr.rstrip(), file=sys.stderr)
        if p.returncode != 0:
            fail(EX_IDB, f"idb ui tap が失敗(rc={p.returncode})。",
                 f"  → idb list-targets で {udid} の companion 接続を確認してリトライ。")

    print(json.dumps(result, ensure_ascii=False))
    # 「撃った」と「効いた」は別。ここで嘘の安心を与えないよう毎回添える(実地の誤診対策)。
    print("note: idb ui tap は当たっても外れても exit 0。効果の確認は sim-act.py / sim-nav.py で。",
          file=sys.stderr)


if __name__ == "__main__":
    main()
