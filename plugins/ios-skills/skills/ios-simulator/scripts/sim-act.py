#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""tap → 期待ラベルが現れる/消えるまで待つ → 現れなければ再タップ、を最大 N 回繰り返す。

Why: sim-tap.py は「ラベル一致の要素中心を1回タップして終わり」。iOS Simulator の実地運用では
これで十分なことは少ない —— アニメーション中にタップが当たり判定の外に落ちる、
描画が1フレーム遅れてまだ古い座標のままタップしてしまう、等でタップが「成功はしたが効いていない」
ケースが起きる(過去に時間を溶かした原因そのもの)。sim-tap.py 単体では「効いたかどうか」を
呼び出し側が別途 sleep + screenshot で確認する運用になりがちで、確認を忘れると気づかず先に進む。

このスクリプトは「タップ後に効果を assert し、効いていなければ同じ操作をやり直す」を1コマンドに
閉じ込める。assert 条件は2種類:
  --until "<label>"       … このラベルが新たに現れたら成功(例: 次の画面の見出し)
  --until-gone "<label>"  … このラベルが消えたら成功(例: ローディングスピナー、確認ダイアログ)
どちらか一方は必須(両方省略すると「効いたかどうか判定不能」になり sim-tap.py と同じ弱点に戻るため、
CLI 側で必須化して事故を防ぐ)。

ボツ案: 「tap 後に画面全体のハッシュが変わったら成功」という汎用判定にする
  → スクロール位置やアニメーションの端数だけで画面ハッシュは容易に変わってしまい、
    「本当に意図した遷移が起きたか」を保証できない。ラベル指定の方が narrow だが確実。
  (なお sim-nav.py は「AXUniqueId の集合が変化したか」で判定する。あちらは
   『識別子で1手進む』専用なので、この粗い判定でも意味が保てる。)

★★ 使ってはいけない場面(2026-08-01 の実地の教訓・必読) ★★
  **非冪等な操作(トグル類)にこのリトライループを使うと、意図と逆の状態になる。**
  例: サイドバーの開閉ボタン。1回目のタップは実は効いていたのに assert の判定が
  アニメーション待ちで間に合わず「外れた」と見なされ、2回目のタップが飛ぶ → 閉じてしまう。
  安全に使えるのは「同じ操作を2回撃っても結果が同じ」= 冪等/準冪等な操作だけ
  (送信ボタン・画面遷移・ダイアログの閉じる など)。
  もう1つの落とし穴として、**assert 条件の選び方**でも実地で誤判定した:
  送信済みテキストがチャット履歴に残り続ける UI に対して `--until-gone "<送信した文字列>"` を
  指定したため、送信は成功していたのに条件が原理的に真にならず「3回失敗」と報告された。
  → --until-gone は「消えることが保証されている一時的な表示」(スピナー・ダイアログ)に使う。

Why UDID 必須: sim-wait.py と同じ理由(複数 booted 環境での `booted` 誤爆を構造的に排除)。
Why stdout は JSON(2026-08-02 変更): attempt ごとの経過は stderr、最終結果だけ stdout に JSON。
  旧版は経過も結果も stdout に混ぜていたので、パイプで結果だけ取れなかった。
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

IDB_TIMEOUT = 30.0


def fail(code: int, *lines: str) -> None:
    print("\n".join(lines), file=sys.stderr)
    sys.exit(code)


def iter_elements(node):
    """describe-all の JSON を歩いて「要素っぽい dict」だけを文書順に列挙する。

    sim-tap.py / sim-wait.py / sim-nav.py と同一実装(単体完結の方針で意図的に非共有)。
    現行 idb は flat な JSON 配列を返すが、入れ子の配列を返す形も観測されているため
    frame を目印にした再帰で両対応にしてある。
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
    """sim-wait.py と同一実装。ポーリング中の一過性失敗は空配列に潰し、idb 不在だけ即死。"""
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


def find(udid: str, label: str, index: int) -> tuple[dict, tuple[int, int]] | None:
    hits = [(el, c) for el in describe_all(udid) if matches(el, label) and (c := center(el))]
    if index >= len(hits):
        return None
    return hits[index]


def condition_met(udid: str, until: str | None, until_gone: str | None) -> bool:
    """--until は「現れた」、--until-gone は「消えた」で真。両方指定時は両方満たして真(AND)。"""
    ok = True
    if until is not None:
        ok = ok and find(udid, until, 0) is not None
    if until_gone is not None:
        ok = ok and find(udid, until_gone, 0) is None
    return ok


def wait_condition(udid: str, until: str | None, until_gone: str | None, timeout: float, interval: float) -> bool:
    deadline = time.monotonic() + timeout
    while True:
        if condition_met(udid, until, until_gone):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="tap → assert(現れる/消える) → 外れたら再タップ、を最大N回",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""stdout(JSON): {{"status":"ok","attempts":1,"x":201,"y":654,"condition":"until='ようこそ'"}}
attempt ごとの経過は stderr。

{EXIT_CODES_HELP}
  ※ 撃ったが条件を満たせなかった場合は 5(タイムアウト)。

★ 非冪等な操作(トグル類)には使わないこと。1回目が効いていたのに assert が間に合わず
  2回目を撃って元に戻す、という事故が実地で起きている(詳細はファイル冒頭のコメント)。

使用例:
  scripts/sim-act.py "続ける" --until "ようこそ" --udid EF5D841C-...
  scripts/sim-act.py "✕" --until-gone "確認" --max-attempts 5 --udid EF5D841C-...""")
    ap.add_argument("label", help="タップ対象のラベル(AXLabel/AXValue 等への部分一致)")
    ap.add_argument("--udid", default=None, help="対象 simulator の UDID(省略時は環境変数 SIM_UDID)")
    ap.add_argument("--until", default=None, help="このラベルが現れたら成功")
    ap.add_argument("--until-gone", default=None, help="このラベルが消えたら成功")
    ap.add_argument("--index", type=int, default=0, help="タップ対象ラベルが複数ある時の選択(0始まり)")
    ap.add_argument("--max-attempts", type=int, default=3, help="tap を試みる最大回数(既定 3)")
    ap.add_argument("--attempt-timeout", type=float, default=3.0, help="1回の tap ごとの assert 待機秒(既定 3)")
    ap.add_argument("--poll-interval", type=float, default=0.3, help="assert ポーリング間隔秒(既定 0.3)")
    # --duration: sim-tap.py と同じ意味論。>0.5 で long-press、0.05 で「確実に短いタップ」。
    # 既定のままだとテキスト入りの入力欄で選択メニュー(Select/Select All/AutoFill)が出ることがある
    # (FEEDBACK 2026-08-01 §7 の実測)。入力欄を狙うリトライでは 0.05 を明示した方が安定する。
    ap.add_argument("--duration", type=float, default=None,
                    help="tap 長押し秒(idb ui tap --duration へ透過)。>0.5 で long-press / 0.05 で短いタップ")
    ap.add_argument("--dry-run", action="store_true", help="タップせず座標と計画だけ返す")
    args = ap.parse_args()

    if args.until is None and args.until_gone is None:
        fail(EX_USAGE, "--until か --until-gone のどちらかが必須(無指定だと『効いたか』を判定できない)。",
             "  → 例: --until \"ようこそ\" / --until-gone \"接続中\"")

    udid = resolve_udid(args.udid)
    ensure_booted(udid)

    last_xy: tuple[int, int] | None = None
    for attempt in range(1, args.max_attempts + 1):
        hit = find(udid, args.label, args.index)
        if hit is None:
            print(f"[attempt {attempt}/{args.max_attempts}] タップ対象 '{args.label}' が見当たらない。再試行待ちへ。",
                  file=sys.stderr)
        else:
            _, (x, y) = hit
            last_xy = (x, y)
            print(f"[attempt {attempt}/{args.max_attempts}] tap ({x}, {y}) points  [ラベル '{args.label}']",
                  file=sys.stderr)
            if not args.dry_run:
                # Why リスト渡し + stderr を握り潰さない: シェルの単語分割で座標が1引数に潰れ、
                # かつ stderr を捨てていたせいで失敗に気づけなかった事故が実走行で起きている。
                cmd = ["idb", "ui", "tap", "--udid", udid, str(x), str(y)]
                if args.duration is not None:
                    cmd += ["--duration", str(args.duration)]
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=IDB_TIMEOUT)
                if p.stderr.strip():
                    print(p.stderr.rstrip(), file=sys.stderr)
                if p.returncode != 0:
                    fail(EX_IDB, f"idb ui tap が失敗(rc={p.returncode})。",
                         f"  → idb list-targets で {udid} の companion 接続を確認してリトライ。")

        if args.dry_run:
            print(json.dumps({"status": "dry-run", "x": last_xy[0] if last_xy else None,
                              "y": last_xy[1] if last_xy else None, "label": args.label,
                              "until": args.until, "until_gone": args.until_gone}, ensure_ascii=False))
            return

        if wait_condition(udid, args.until, args.until_gone, args.attempt_timeout, args.poll_interval):
            cond = f"until='{args.until}'" if args.until else ""
            cond += (" " if cond and args.until_gone else "") + (f"until-gone='{args.until_gone}'" if args.until_gone else "")
            print(json.dumps({"status": "ok", "attempts": attempt, "condition": cond,
                              "x": last_xy[0] if last_xy else None,
                              "y": last_xy[1] if last_xy else None}, ensure_ascii=False))
            return

        print(f"[attempt {attempt}/{args.max_attempts}] assert 不成立。{'次を試す' if attempt < args.max_attempts else '諦める'}。",
              file=sys.stderr)

    fail(EX_TIMEOUT,
         f"'{args.label}' タップを{args.max_attempts}回試したが、期待条件"
         f"(until={args.until!r}, until_gone={args.until_gone!r})を満たさなかった。",
         f"  → scripts/sim-shot.sh --udid {udid} で画面を確認し、ラベル文言/座標がズレていないか、"
         "アニメーションがまだ終わっていないかを確認してリトライ。",
         "  → **その assert 条件は原理的に真になりうるか**も疑う。実地では「送信済みテキストが",
         "    履歴に残り続ける UI」に --until-gone を掛けて『成功しているのに3回失敗』と誤判定した。")


if __name__ == "__main__":
    main()
