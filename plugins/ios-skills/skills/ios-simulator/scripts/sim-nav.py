#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""AXUniqueId(言語非依存の識別子)で要素を探し、必要ならスクロールして、タップし、効いたか検証する。

Why(2026-08-02 の実測): `idb ui describe-all --json` の各要素は **AXUniqueId** を持ち、これは
**言語設定に依存しない** —— 端末を英語に切り替えてラベルが全部英語になっても、識別子の集合は
diff ゼロだった。ラベル一致(sim-tap.py)は「日本語だと『アプリ』/英語だと『Apps』」で壊れるので、
**識別子が分かっているなら常にこちらを使う**。

このスクリプトが「1コマンド」で引き受ける4つのこと(散文の注意書きでは守られなかったもの):
  1. 座標を手で組み立てない  … 識別子 → frame 中心(points)を内部で解決する。
     スクショの pixel 座標を割り算する経路が存在しないので、座標系の取り違えが起こりえない。
  2. 木に無ければスクロールして探す … iOS のテーブルは**可視セルしかアクセシビリティに出さない**。
     「設定ルートの『アプリ』が画面外にいて見つからない」は実地で必ず踏む。
  3. 撃つ直前に座標を読み直す … スクロールの慣性で位置がずれる。探索時の座標で撃つと空振りする。
  4. 撃った後に検証する … `idb ui tap` は当たっても外れても無言で exit 0(実測)。
     タップ前後で AXUniqueId 集合が変化したかを見て、変化が無ければ**失敗として非ゼロ終了**する。
     これが無いと「嘘の成功」を返し、後続の全手順が誤った前提の上に積み上がる。

★ 検証方式の限界(承知の上で採っている): 「id 集合の変化」はトグル(スイッチの ON/OFF など、
  id は同じで AXValue だけ変わる操作)を検出できない。画面遷移・シート提示・セル展開のような
  「木が変わる」操作向けの判定である。トグルには --no-verify を明示するか、
  値の変化を見る別手段(describe-all の撮り直し)を使うこと。
  ボツ案: (id, label, value) の三つ組で比較して感度を上げる
    → ステータスバーの時刻ラベルが分単位で変わるため、何もしていなくても「変化した」と
      誤って成功判定しうる。誤検出(嘘の成功)は誤検出漏れより高くつくので id 集合に留めた。

Why UDID 必須: 実走行で **シェル変数の展開ミスにより意図しない端末へ install/launch した**事故が
  ある。全スクリプトで --udid か SIM_UDID を必須にし、暗黙の宛先を構造的に消す。

Why subprocess のリスト渡し: 実走行で zsh の `idb ui tap --udid $U $coords` が「201 654」を
  1引数として渡してしまい、しかも stderr を捨てていたため失敗に気づかず誤った原因分析をした
  事故がある。ここでは単語分割の存在しないリスト渡しにし、idb の stderr は必ず中継する。
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
  5 タイムアウト(撃ったが画面が変わらない/--until-id が現れない) / 6 idb 未導入・companion 未接続
  7 前提不足(外部ツール等)"""

IDB_TIMEOUT = 30.0   # 1回の idb 呼び出しの上限(非対話シェルで無限待ちを作らない)
MAX_LIST = 80        # --list の既定件数。ハーネスの出力打ち切り(10-30K 文字)に収まる量に絞る
MAX_REPORT_IDS = 15  # 検証結果に載せる「増えた id」の上限。木が丸ごと入れ替わると数百件になるため


def fail(code: int, *lines: str) -> None:
    print("\n".join(lines), file=sys.stderr)
    sys.exit(code)


def iter_elements(node):
    """describe-all の JSON を歩いて「要素っぽい dict」だけを文書順に列挙する。

    sim-tap.py / sim-wait.py / sim-act.py と同一実装(単体完結の方針で意図的に非共有)。
    flat な配列でも入れ子でも JSON-lines でも効くよう frame を目印にした再帰にしてある。
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


def describe_all(udid: str, soft: bool = False) -> list[dict]:
    """要素配列を返す。soft=True なら一過性の失敗を空配列に潰す(ポーリング用)。"""
    try:
        raw = subprocess.run(
            ["idb", "ui", "describe-all", "--udid", udid, "--json"],
            capture_output=True, text=True, check=True, timeout=IDB_TIMEOUT,
        ).stdout.strip()
    except FileNotFoundError:
        fail(EX_IDB, "idb が見つからない。",
             "  → uv tool install fb-idb で導入し、idb connect <UDID> で接続してからリトライ。")
    except subprocess.TimeoutExpired:
        if soft:
            return []
        fail(EX_IDB, f"idb ui describe-all が {IDB_TIMEOUT}s 応答しない。",
             "  → idb kill && idb connect <UDID> で companion を張り直してリトライ。")
    except subprocess.CalledProcessError as e:
        if soft:
            return []
        fail(EX_IDB, f"idb ui describe-all に失敗: {(e.stderr or '').strip() or e}",
             f"  → idb list-targets で {udid} の companion 接続を確認"
             f"(No Companion Connected なら idb connect {udid})。")
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = [json.loads(line) for line in raw.splitlines() if line.strip()]
    return list(iter_elements(data))


def uid_of(el: dict) -> str | None:
    """要素の識別子。idb のバージョン差を吸収して AXUniqueId / AXIdentifier の両方を見る。"""
    for key in ("AXUniqueId", "AXIdentifier", "identifier"):
        v = el.get(key)
        if isinstance(v, str) and v:
            return v
    return None


def label_of(el: dict) -> str | None:
    for key in ("AXLabel", "label", "title", "AXValue"):
        v = el.get(key)
        if isinstance(v, str) and v:
            return v
    return None


def id_set(elements: list[dict]) -> set[str]:
    return {u for el in elements if (u := uid_of(el))}


def center(el: dict) -> tuple[int, int] | None:
    f = el.get("frame") or {}
    try:
        x, y, w, h = f["x"], f["y"], f["width"], f["height"]
    except (KeyError, TypeError):
        return None
    return round(x + w / 2), round(y + h / 2)


def screen_size(elements: list[dict]) -> tuple[int, int] | None:
    """面積最大の frame を画面全体(points)とみなす。スワイプ座標の算出に使う。"""
    best = None
    for el in elements:
        f = el.get("frame") or {}
        w, h = f.get("width"), f.get("height")
        if isinstance(w, (int, float)) and isinstance(h, (int, float)) and w > 0 and h > 0:
            if best is None or w * h > best[0] * best[1]:
                best = (w, h)
    return (round(best[0]), round(best[1])) if best else None


def resolve_udid(cli_udid: str | None) -> str:
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
    """指定 UDID が Booted か確認する(sim-tap.py と同一実装)。"""
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


def run_idb(cmd: list[str]) -> subprocess.CompletedProcess:
    """idb をリスト渡しで実行し、stderr は必ず中継する(握り潰さない)。"""
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=IDB_TIMEOUT)
    if p.stderr.strip():
        print(p.stderr.rstrip(), file=sys.stderr)
    return p


def swipe(udid: str, size: tuple[int, int], direction: str, duration: float) -> None:
    """画面中央を縦に drag してスクロールする。

    Why 遅め(既定 0.5s)の drag: 速いフリックは慣性でしばらく動き続け、直後に読んだ座標が
    もう古い、という空振りを生む。ゆっくり引くと慣性がほぼ乗らず、settle 待ちも短くて済む。
    """
    w, h = size
    cx = round(w / 2)
    # direction="down" = 「下方向へスクロールして続きを見る」= 指は下から上へ動かす。
    y_from, y_to = (round(h * 0.72), round(h * 0.32)) if direction == "down" else (round(h * 0.32), round(h * 0.72))
    base = ["idb", "ui", "swipe", "--udid", udid]
    coords = [str(cx), str(y_from), str(cx), str(y_to)]
    p = run_idb(base + ["--duration", str(duration)] + coords)
    if p.returncode != 0:
        # フォールバック: idb のバージョンによっては swipe に --duration が無い可能性がある。
        # 「オプションが無い」だけで探索そのものを諦めるのは惜しいので、素の swipe を試す。
        p = run_idb(base + coords)
    if p.returncode != 0:
        fail(EX_IDB, f"idb ui swipe が失敗(rc={p.returncode})。",
             f"  → idb list-targets で {udid} の companion 接続を確認してリトライ。")


def find_by_id(elements: list[dict], target: str) -> dict | None:
    """AXUniqueId の完全一致。部分一致にしない —— 「ACCOUNTS」と「ACCOUNTS_FOOTER」のような
    紛らわしい識別子を静かに取り違えるより、見つからないと言って --list を促す方が安全。"""
    for el in elements:
        if uid_of(el) == target:
            return el
    return None


def on_screen(xy: tuple[int, int], size: tuple[int, int] | None) -> bool:
    """中心が画面矩形の内側にあるか。部分的に見えているだけのセルは中心が外に出ることがあり、
    そこを撃つと「画面外タップ = 無反応」になる(idb は無言で成功を返す)。"""
    if size is None:
        return True
    x, y = xy
    w, h = size
    return 0 <= x <= w and 0 <= y <= h


def cmd_list(udid: str, limit: int, offset: int) -> None:
    els = describe_all(udid)
    if not els:
        fail(EX_NOTFOUND, "アクセシビリティ要素が空。",
             "  → 対象アプリが前面にいない可能性が高い。",
             f"    xcrun simctl launch --terminate-running-process {udid} <bundle-id> して数秒待つ。")
    rows = []
    for el in els:
        uid, lab = uid_of(el), label_of(el)
        if not uid and not lab:
            continue  # 識別子もラベルも無い要素は探索の役に立たない(出力を膨らませるだけ)
        c = center(el)
        rows.append({"id": uid, "label": lab, "type": el.get("type"), "center": list(c) if c else None})
    window = rows[offset:offset + limit]
    print(json.dumps({
        "status": "ok", "udid": udid, "total": len(rows), "offset": offset, "shown": len(window),
        "screen_points": list(screen_size(els) or []) or None,
        "elements": window,
        # 出力の予測可能性: 全件を吐くとハーネスに切り捨てられて肝心の要素が消える。
        # 続きは --offset で取る(公式ガイド「Predictable output size」)。
        "next_offset": (offset + len(window)) if offset + len(window) < len(rows) else None,
    }, ensure_ascii=False))


def cmd_nav(udid: str, args) -> None:
    target = args.id
    scrolls = 0
    els = describe_all(udid)
    size = screen_size(els)
    el = find_by_id(els, target)

    # 1) 見つからない/画面外なら、スクロールして探す(iOS は可視セルしか AX に出さない)。
    while (el is None or not on_screen(center(el) or (0, 0), size)) and scrolls < args.scroll_max:
        if args.dry_run:
            break  # --dry-run は画面を動かさない(スクロールも状態変化なので撃たない)
        if size is None:
            fail(EX_NOTFOUND, "画面サイズ(points)を特定できないためスクロールできない。",
                 "  → describe-all が空 or frame 全部 0 = 対象アプリが前面にいない印。",
                 f"    xcrun simctl launch --terminate-running-process {udid} <bundle-id> して数秒待つ。")
        scrolls += 1
        print(f"[scroll {scrolls}/{args.scroll_max}] '{target}' が見えないので {args.scroll_direction} 方向へスクロール",
              file=sys.stderr)
        swipe(udid, size, args.scroll_direction, args.scroll_duration)
        time.sleep(args.settle)  # 慣性が止まるのを待つ。ここを削ると次の describe-all が古い座標を返す
        els = describe_all(udid)
        size = screen_size(els) or size
        el = find_by_id(els, target)

    if el is None:
        fail(EX_NOTFOUND,
             f"AXUniqueId '{target}' が見つからない(スクロール {scrolls} 回)。",
             f"  → scripts/sim-nav.py --udid {udid} --list で現在画面の識別子一覧を確認する。",
             "  → 目的の画面にまだ到達していない可能性。--scroll-max を増やすか、"
             "--scroll-direction up も試す。",
             f"  → 画面そのものを確認するなら scripts/sim-shot.sh --udid {udid}。")

    xy = center(el)
    if xy is None:
        fail(EX_NOTFOUND, f"'{target}' は見つかったが frame から中心座標を出せない。",
             "  → --list で frame を確認する(frame が全部 0 なら対象アプリが前面にいない印)。")

    if args.dry_run:
        print(json.dumps({"status": "dry-run", "id": target, "x": xy[0], "y": xy[1],
                          "label": label_of(el), "scrolls": scrolls,
                          "on_screen": on_screen(xy, size)}, ensure_ascii=False))
        return

    if not on_screen(xy, size):
        fail(EX_NOTFOUND,
             f"'{target}' の中心 {xy} が画面 {size} の外(セルが部分的にしか見えていない)。",
             "  → --scroll-max を増やして完全に画面内へ入れてからリトライ。")

    # 2) 撃つ直前に読み直す。スクロール直後は慣性で位置がずれるため、探索時の座標は信用しない。
    fresh = find_by_id(describe_all(udid), target)
    if fresh is not None and (c := center(fresh)) is not None:
        if c != xy:
            print(f"note: 座標が {xy} → {c} にずれていたので読み直した値で撃つ", file=sys.stderr)
        xy = c

    before = id_set(describe_all(udid))

    cmd = ["idb", "ui", "tap", "--udid", udid, str(xy[0]), str(xy[1])]
    if args.duration is not None:
        cmd += ["--duration", str(args.duration)]
    print(f"tap ({xy[0]}, {xy[1]}) points  [id '{target}' label={label_of(el)!r}]", file=sys.stderr)
    p = run_idb(cmd)
    if p.returncode != 0:
        fail(EX_IDB, f"idb ui tap が失敗(rc={p.returncode})。",
             f"  → idb list-targets で {udid} の companion 接続を確認してリトライ。")

    # 3) 効いたかを検証する。idb は当たっても外れても exit 0 なので、ここが唯一の真実。
    deadline = time.monotonic() + args.verify_timeout
    while True:
        after = id_set(describe_all(udid, soft=True))
        if args.until_id is not None:
            ok = args.until_id in after
            reason = "until_id"
        else:
            ok = bool(after) and after != before
            reason = "id_set_changed"
        if ok:
            print(json.dumps({
                "status": "ok", "id": target, "x": xy[0], "y": xy[1], "label": label_of(el),
                "scrolls": scrolls, "verified": True, "verified_by": reason,
                "new_ids": sorted(after - before)[:MAX_REPORT_IDS],
                "new_id_count": len(after - before),
            }, ensure_ascii=False))
            return
        if time.monotonic() >= deadline:
            break
        time.sleep(args.poll_interval)

    if args.no_verify:
        # 「検証できなかったが撃った」を **verified:false** として明示的に返す。
        # 黙って成功を返すのは、このスクリプトが潰そうとしている失敗そのものなので絶対にしない。
        print(json.dumps({"status": "unverified", "id": target, "x": xy[0], "y": xy[1],
                          "scrolls": scrolls, "verified": False}, ensure_ascii=False))
        return
    fail(EX_TIMEOUT,
         f"'{target}' をタップしたが、{args.verify_timeout}s 待っても画面の変化を確認できなかった。",
         "  → idb ui tap は外れても exit 0 を返すので、これは『効かなかった』の可能性が高い。",
         f"  → scripts/sim-shot.sh --udid {udid} で実際の画面を確認する。",
         "  → 期待する変化が『id 集合の変化』でない操作(トグル等)なら --no-verify か --until-id を使う。",
         "  → キーボードやモーダルが被さっていないか、対象が enabled かも --list で確認する。")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="AXUniqueId(言語非依存)で要素を探し、スクロールし、タップし、効いたか検証する",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""stdout(JSON):
  --id  : {{"status":"ok","id":"ACCOUNTS","x":201,"y":337,"verified":true,
           "verified_by":"id_set_changed","new_ids":[...],"scrolls":1}}
  --list: {{"status":"ok","total":42,"shown":42,"elements":[{{"id":...,"label":...,"center":[x,y]}}],
           "next_offset":null}}
経過(スクロール・座標の読み直し・idb の stderr)は stderr。

{EXIT_CODES_HELP}

なぜラベルでなく識別子か: AXUniqueId は端末の言語設定を変えても不変(2026-08-02 実測。
英語に切り替えてラベルが全部英語になっても識別子の集合は diff ゼロ)。ラベル一致の
sim-tap.py は言語で壊れる。識別子が分かっているならこちらを使う。

実測で確立している iOS 26 設定アプリのチェーン(CalDAV アカウント追加まで):
  com.apple.settings.apps   設定ルートの「アプリ」(★画面外のことがある → 自動スクロール)
  com.apple.mobilecal       アプリ一覧の「カレンダー」
  ACCOUNTS                  カレンダー設定の「カレンダーアカウント」
  ADD_ACCOUNT               「アカウントを追加」
  この先はラベル指定(sim-tap.py): 「その他のアカウントを追加…」→「CalDAVアカウント」

使用例:
  scripts/sim-nav.py --udid EF5D841C-... --list
  scripts/sim-nav.py --udid EF5D841C-... --id com.apple.settings.apps
  scripts/sim-nav.py --udid EF5D841C-... --id ACCOUNTS --until-id ADD_ACCOUNT
  SIM_UDID=EF5D841C-... scripts/sim-nav.py --id com.apple.mobilecal --scroll-max 5""")
    ap.add_argument("--udid", default=None, help="対象 simulator の UDID(省略時は環境変数 SIM_UDID)")
    ap.add_argument("--id", default=None, help="タップ対象の AXUniqueId(完全一致)")
    ap.add_argument("--list", action="store_true", help="現在画面の識別子/ラベル一覧を JSON で出す(探索用)")
    ap.add_argument("--limit", type=int, default=MAX_LIST, help=f"--list の最大件数(既定 {MAX_LIST})")
    ap.add_argument("--offset", type=int, default=0, help="--list の開始位置(続きは next_offset を使う)")
    ap.add_argument("--until-id", default=None,
                    help="この AXUniqueId が現れたら成功(既定は『id 集合が変化したら成功』)")
    ap.add_argument("--scroll-max", type=int, default=3, help="要素が見つからない時のスクロール回数上限(既定 3)")
    ap.add_argument("--scroll-direction", choices=("down", "up"), default="down",
                    help="スクロール方向(既定 down = 続きを見る)")
    ap.add_argument("--scroll-duration", type=float, default=0.5,
                    help="1回の drag 秒数(既定 0.5。速いと慣性で座標がずれる)")
    ap.add_argument("--settle", type=float, default=0.8, help="スクロール後の静止待ち秒(既定 0.8)")
    ap.add_argument("--duration", type=float, default=None,
                    help="tap 長押し秒(idb ui tap へ透過)。>0.5 で long-press / 0.05 で短いタップ")
    ap.add_argument("--verify-timeout", type=float, default=4.0, help="タップ後の変化を待つ秒(既定 4)")
    ap.add_argument("--poll-interval", type=float, default=0.4, help="検証ポーリング間隔秒(既定 0.4)")
    ap.add_argument("--no-verify", action="store_true",
                    help="変化を確認できなくても失敗にしない(status:'unverified' で返す。トグル等)")
    ap.add_argument("--dry-run", action="store_true",
                    help="スクロールもタップもせず、現在の木から座標だけ返す")
    args = ap.parse_args()

    # 入力の閉じた集合を強制する(公式ガイド「Input constraints」)。曖昧なら推測せず落とす。
    if bool(args.list) == bool(args.id):
        fail(EX_USAGE, "--id か --list のどちらか一方を指定すること。",
             "  → 何を撃てばよいか分からないなら、まず --list で識別子一覧を見る。")

    udid = resolve_udid(args.udid)
    ensure_booted(udid)

    if args.list:
        cmd_list(udid, args.limit, args.offset)
        return
    cmd_nav(udid, args)


if __name__ == "__main__":
    main()
