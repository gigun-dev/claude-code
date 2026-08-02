// レイヤー定義 JSON から、.icon 用のレイヤー PNG 群を描画する。
//
// なぜ CoreGraphics で描くか:
// SVG→PNG 変換系(rsvg-convert / inkscape / ImageMagick / cairosvg)は入っていない環境が多い。
// macOS に必ずある CoreGraphics で直接ラスタライズすれば、追加インストールなしで完結する。
//
// なぜ bbox を実測して autofit するか:
// 「はみ出していないか」を目で判断すると失敗する。回転はカードの外接矩形を対角方向へ
// 膨らませるので、角度・サイズ・位置の3つを人間が同時に見積もるのは無理がある。
// 実際、この skill の元になった作業では手で座標を詰めて3世代連続ではみ出した
// (右端 1024px まで溢れているのに気づかなかった)。1回試し描きして外接矩形を測り、
// 中心を canvas 中央へ寄せてから安全域に収まる倍率を掛ければ、この失敗は構造的に起きない。
// 副次的な利点として「余白を詰めたい」という要求にも自動で応えられる(常に安全域いっぱいを使う)。
//
// 使い方:
//   swift draw_layers.swift <layers.json> <出力ディレクトリ>
//
// layers.json の形式:
// {
//   "canvas": 1024,           // 省略可(既定 1024)
//   "safeMargin": 96,         // 省略可(既定 96 = Apple のグリッドに合わせた安全域)
//   "autofit": true,          // 省略可(既定 true)
//   "layers": [
//     { "name": "01-back", "shape": "roundedRect",
//       "cx": 452, "cy": 468, "w": 620, "h": 486, "r": 128, "angle": -6, "color": "#ffffff" },
//     { "name": "02-front", "shape": "circle",
//       "cx": 652, "cy": 664, "d": 356, "color": "#fbbf24" },
//     { "name": "03-mark", "shape": "path",
//       "cx": 512, "cy": 512, "w": 880, "viewBox": 1000,
//       "d": "M120 300H880A100 100 0 010 500Z",   // shape:"path" では d が SVG パス
//       "thickness": 96,                          // 書くと塗りではなく線で描く
//       "fillRule": "evenOdd",                    // 塗りのとき、重なりを穴にする
//       "color": "#f4f2ec" }
//   ]
// }
// 座標は「左上原点・上から測った y」で書く(デザインツールと同じ感覚)。
// CoreGraphics の左下原点はスクリプト側で吸収する。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 入力

let args = CommandLine.arguments
if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
    print("Usage: swift draw_layers.swift <layers.json> <out-dir>")
    exit(0)
}
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: swift draw_layers.swift <layers.json> <outDir>\n".data(using: .utf8)!)
    exit(2)
}
let specURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let raw = try? Data(contentsOf: specURL),
      let spec = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
      let rawLayers = spec["layers"] as? [[String: Any]], !rawLayers.isEmpty else {
    FileHandle.standardError.write("error: cannot read layers from \(specURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let S = CGFloat(spec["canvas"] as? Double ?? 1024)
let safeMargin = CGFloat(spec["safeMargin"] as? Double ?? 96)
let doAutofit = spec["autofit"] as? Bool ?? true

// MARK: - 描画基盤

/// `#rrggbb` を **sRGB の** CGColor にする。
///
/// 【色空間を明示する理由・2026-08-02 修正】`CGColor(red:green:blue:alpha:)` は
/// 色空間を取らず、生成される色は generic/device RGB になる。描画先のビットマップは
/// sRGB なので、描くときに CoreGraphics が変換をかけ、**書いた hex と出る色がずれる**。
/// 実測で `#fbbf24` → `#fdc92e`、`#6366f1` → `#7680f4`(いずれも明度・彩度が上がる方向)。
/// 誤差は小さいがエラーも警告も出ないので、「指定した色と違う」と気づきにくい ——
/// 実際、既存アイコンの PNG から色を測って spec と突き合わせるまで発覚しなかった。
/// ブランド色を指定する用途では致命的なので、色空間を明示して同一に保つ。
func hex(_ s: String) -> CGColor {
    var h = s.replacingOccurrences(of: "#", with: "")
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    let v = UInt32(h, radix: 16) ?? 0
    let c: [CGFloat] = [CGFloat((v >> 16) & 0xff) / 255,
                        CGFloat((v >> 8) & 0xff) / 255,
                        CGFloat(v & 0xff) / 255, 1]
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: c)!
}

func makeContext() -> CGContext {
    CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, _ name: String) {
    let url = outDir.appendingPathComponent(name.hasSuffix(".png") ? name : name + ".png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

/// 1レイヤー分の幾何。JSON から読んだ値を、autofit で一括変換できる形に正規化して持つ。
///
/// 【shape を増やした理由・2026-08-01】当初は roundedRect と circle だけだったが、
/// それだけだと表現できる構図が「面を重ねる」系にほぼ限られ、どのアプリのアイコンを作っても
/// 似た絵になった(実際、別アプリで作った案と見分けがつかないものが出た)。
/// NFC の波紋・カメラのレンズ・輪郭だけの図形は円環と円弧が要る。`ring` と `arc` を足すと
/// 「塗り面の重なり」以外の語彙が使えるようになり、モチーフの選択肢が一気に広がる。
struct Layer {
    var name: String
    var shape: String   // "roundedRect" | "circle" | "ring" | "arc" | "capsule" | "path"
    var cx: CGFloat, cy: CGFloat   // cy は上端基準
    var w: CGFloat, h: CGFloat, r: CGFloat
    var angle: CGFloat
    var thickness: CGFloat          // ring / arc の線幅
    var startAngle: CGFloat         // arc の開始角(度・0 = 右、時計回りが正)
    var endAngle: CGFloat           // arc の終了角(度)
    var pathD: String               // shape:"path" のときの SVG `d`
    var viewBox: CGFloat            // その d が前提とする正方 viewBox の一辺
    var evenOdd: Bool               // 重なった部分を「穴」にするか(下記参照)
    var strokePath: Bool            // shape:"path" を塗らず線で描くか(thickness 明示で ON)
    var color: String
    var gradient: Gradient?         // 指定されるとベタ塗りの代わりにこれで塗る
    var opacity: CGFloat
}

/// 素材そのものに焼き込むグラデーション。
///
/// 【なぜ素材側に要るか・2026-08-02】色は icon.json のレイヤー `fill` でも付けられるが、
/// あちらが持てるのは**2色の線形グラデーション1本**だけ。そのため素材は常に真っ平らで、
/// 見えている艶や陰影は全部 ictool の Liquid Glass が後から乗せたものになっていた
/// (「グラデーションが無く Liquid Glass に頼っている」と指摘されて発覚)。
/// 純正は Health のハート、Siri のオーブ、iCloud の雲のように**放射状・多段**の
/// グラデーションを持っており、その表現力の差がそのまま案の差になっていた。
/// 放射状と多段は icon.json では表現できないので、素材側で焼くしかない。
struct Gradient {
    var kind: String                  // "linear" | "radial"
    var stops: [(CGColor, CGFloat)]   // 色と位置(0..1)
    var angle: CGFloat                // linear: 0 = 左→右、反時計回りが正(度)
    var center: CGPoint               // radial: 図形の外接矩形内の正規化座標
    var radius: CGFloat               // radial: 外接矩形の対角半分に対する倍率
}

let layers: [Layer] = rawLayers.enumerated().map { (i, d) in
    let shape = d["shape"] as? String ?? "roundedRect"
    let diameter = CGFloat(d["d"] as? Double ?? 0)
    let isRound = (shape == "circle" || shape == "ring" || shape == "arc")
    return Layer(
        name: d["name"] as? String ?? String(format: "%02d-layer", i + 1),
        shape: shape,
        cx: CGFloat(d["cx"] as? Double ?? Double(S / 2)),
        cy: CGFloat(d["cy"] as? Double ?? Double(S / 2)),
        w: isRound ? diameter : CGFloat(d["w"] as? Double ?? 400),
        h: isRound ? diameter : CGFloat(d["h"] as? Double ?? 300),
        r: isRound ? diameter / 2 : CGFloat(d["r"] as? Double ?? 80),
        angle: CGFloat(d["angle"] as? Double ?? 0),
        thickness: CGFloat(d["thickness"] as? Double ?? 40),
        startAngle: CGFloat(d["startAngle"] as? Double ?? 0),
        endAngle: CGFloat(d["endAngle"] as? Double ?? 90),
        pathD: d["d"] as? String ?? "",
        viewBox: CGFloat(d["viewBox"] as? Double ?? 1024),
        evenOdd: (d["fillRule"] as? String ?? "") == "evenOdd",
        // thickness を「書いたかどうか」で塗り/線を切り替える。既定値(40)と区別が要るので
        // 値ではなくキーの有無を見る —— 塗りたいときに thickness を書く理由が無いので、
        // 書いてあること自体を「線で描きたい」という意思表示として扱ってよい。
        strokePath: shape == "path" && d["thickness"] != nil,
        color: d["color"] as? String ?? "#ffffff",
        gradient: parseGradient(d["gradient"] as? [String: Any]),
        opacity: CGFloat(d["opacity"] as? Double ?? 1.0))
}

/// `"gradient"` を読む。stops は `[["#fff", 0], ["#333", 1]]` か
/// `[{"color":"#fff","at":0}, ...]` のどちらでも書ける(手で書くとき前者が楽)。
func parseGradient(_ g: [String: Any]?) -> Gradient? {
    guard let g else { return nil }
    var stops: [(CGColor, CGFloat)] = []
    for raw in (g["stops"] as? [Any] ?? []) {
        if let a = raw as? [Any], a.count >= 2,
           let c = a[0] as? String, let at = a[1] as? Double {
            stops.append((hex(c), CGFloat(at)))
        } else if let d = raw as? [String: Any],
                  let c = d["color"] as? String {
            stops.append((hex(c), CGFloat(d["at"] as? Double ?? 0)))
        }
    }
    guard stops.count >= 2 else { return nil }
    let c = g["center"] as? [Double] ?? [0.5, 0.5]
    return Gradient(
        kind: g["type"] as? String ?? "linear",
        stops: stops,
        angle: CGFloat(g["angle"] as? Double ?? 90),
        center: CGPoint(x: c.first ?? 0.5, y: c.count > 1 ? c[1] : 0.5),
        radius: CGFloat(g["radius"] as? Double ?? 1.0))
}

/// SVG の `d` 属性を CGPath へ変換する(M/L/H/V/C/Q/Z と相対版に対応)。
///
/// 【なぜ必要か】角丸長方形・円・円環だけだと、作れる構図が「面と点の構成」に偏る。
/// どのアプリのアイコンを作っても似た絵になり、実際に「二番煎じ」と評価された。
/// 任意パスが描ければ、切り欠き・非対称な塊・記号的な曲線といった語彙が使え、
/// デザインツールや生成 AI の草案をそのまま持ち込める。
///
/// 対応するのは M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z(SVG のパスコマンドのほぼ全部)。
///
/// 【A(円弧)を後から足した理由・2026-08-02】当初は「使う場面が少なく実装コストが高い」として
/// 省き、円弧が要るなら shape:"arc" を使えとしていた。これが間違いだった —— shape:"arc" は
/// **独立したレイヤーとして線を1本引く**ものなので、「直線と円弧が繋がった1つの閉じた輪郭」が
/// 作れない。結果、パスで描けるのは多角形と手書きベジェだけになり、「大胆に1つのパスで勝負する」
/// タイプの構成(=プリミティブの積み重ねでは絶対に出ない形)が事実上できなかった。
/// デザインツールや生成 AI が吐く d 属性も A を多用するので、持ち込みの互換性という意味でも要る。
/// S/T(前の制御点の鏡像を使う省略記法)も同じ理由 —— 外部の d をそのまま貼れることが重要。
///
/// **SVG は y 軸が下向き**なので、ここで上下を反転してから CoreGraphics 座標へ渡す。
func parseSVGPath(_ d: String, viewBox: CGFloat) -> CGPath {
    let path = CGMutablePath()
    var cur = CGPoint.zero
    var start = CGPoint.zero
    var lastCtrl = CGPoint.zero

    // コマンド文字で区切りつつ、数値を取り出す簡易トークナイザ。
    var tokens: [(cmd: Character, nums: [CGFloat])] = []
    var currentCmd: Character?
    var numberBuf = ""
    var nums: [CGFloat] = []
    func flushNumber() {
        if !numberBuf.isEmpty, let v = Double(numberBuf) { nums.append(CGFloat(v)) }
        numberBuf = ""
    }
    func flushCmd() {
        flushNumber()
        if let c = currentCmd { tokens.append((c, nums)) }
        nums = []
    }
    /// いま読もうとしている数値が A/a の 0/1 フラグ位置(7つ組の4・5番目)か。
    func isArcFlagPosition() -> Bool {
        guard let c = currentCmd, c == "a" || c == "A", numberBuf.isEmpty else { return false }
        let i = nums.count % 7
        return i == 3 || i == 4
    }
    for ch in d {
        if ch.isLetter {
            flushCmd()
            currentCmd = ch
        } else if ch == "-" && !numberBuf.isEmpty && numberBuf.last != "e" {
            flushNumber()      // 区切りなしの負数("10-5")に対応
            numberBuf = "-"
        } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
            flushNumber()
        } else if isArcFlagPosition(), ch == "0" || ch == "1" {
            // 【A コマンド特有の罠】large-arc-flag と sweep-flag は 0/1 の1文字で、
            // SVG では区切り文字を省ける("a1 1 0 011 1" の "011" は 0,1,1 の3値)。
            // 素朴に空白/カンマだけで区切ると 11 や 011 という1つの数になり、
            // エラーにならないまま弧の形だけが壊れる。フラグの位置(7つ組の4・5番目)に
            // 来たら1文字だけ取って確定させる。デザインツールが吐く圧縮された d を
            // そのまま貼れることがこのパーサの存在意義なので、ここは仕様どおり実装する。
            nums.append(ch == "1" ? 1 : 0)
        } else {
            numberBuf.append(ch)
        }
    }
    flushCmd()

    // SVG(y 下向き・viewBox 基準)→ CoreGraphics(y 上向き・canvas 基準)。
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: viewBox - y) }

    /// SVG の楕円弧(endpoint parameterization)を三次ベジェ列へ落として path へ足す。
    ///
    /// 変換は SVG 仕様 F.6.5 の実装そのまま(端点表現 → 中心表現)。CGPath には
    /// 「傾いた楕円の弧」を直接足す API が無いので、90°以下の区画へ分割して各区画を
    /// ベジェ近似する(t = 4/3·tan(δ/4) が誤差最小の古典的な係数)。
    /// 計算は SVG 座標系(y 下向き)のまま行い、最後に pt() で反転する —— pt は
    /// アフィン変換なので、制御点だけ変換すれば曲線の形は保たれる。
    func addArc(_ p1: CGPoint, _ rxIn: CGFloat, _ ryIn: CGFloat, _ xRotDeg: CGFloat,
                _ largeArc: Bool, _ sweep: Bool, _ p2: CGPoint) {
        // 半径 0 は直線とみなす(仕様)。負値は絶対値を取る。
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: pt(p2.x, p2.y)); return }

        let phi = xRotDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
        let x1p = cosP * dx2 + sinP * dy2
        let y1p = -sinP * dx2 + cosP * dy2

        // 指定半径が小さすぎて2点を結べない場合は、仕様どおり等比で拡大する。
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }

        let rx2 = rx * rx, ry2 = ry * ry
        let num = max(0, rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p)
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        let coef = (largeArc != sweep ? 1 : -1) * sqrt(den == 0 ? 0 : num / den)
        let cxp = coef * rx * y1p / ry
        let cyp = coef * -ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (p1.x + p2.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p1.y + p2.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, len == 0 ? 1 : dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        // sweep フラグと回転方向を一致させる(仕様どおり ±2π で折り返す)。
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        for _ in 0 ..< segments {
            let next = theta + step
            // 楕円上の点とその接ベクトル(x 軸回転 phi 込み)。
            func point(_ a: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cosP * cos(a) - ry * sinP * sin(a),
                        y: cy + rx * sinP * cos(a) + ry * cosP * sin(a))
            }
            func deriv(_ a: CGFloat) -> CGPoint {
                CGPoint(x: -rx * cosP * sin(a) - ry * sinP * cos(a),
                        y: -rx * sinP * sin(a) + ry * cosP * cos(a))
            }
            let p0 = point(theta), p3 = point(next)
            let d0 = deriv(theta), d3 = deriv(next)
            let c1 = CGPoint(x: p0.x + t * d0.x, y: p0.y + t * d0.y)
            let c2 = CGPoint(x: p3.x - t * d3.x, y: p3.y - t * d3.y)
            path.addCurve(to: pt(p3.x, p3.y), control1: pt(c1.x, c1.y), control2: pt(c2.x, c2.y))
            theta = next
        }
    }

    // S/T(省略記法)は「直前が同種の曲線コマンドだったか」で制御点の求め方が変わるので、
    // 直前のコマンド種別を覚えておく(仕様: 直前が違えば鏡像ではなく現在点を使う)。
    var prevCmd: Character = " "

    for (cmd, n) in tokens {
        let rel = cmd.isLowercase
        let lower = Character(cmd.lowercased())
        defer { prevCmd = lower }
        switch lower {
        case "m":
            var i = 0
            while i + 1 < n.count {
                let p = rel ? CGPoint(x: cur.x + n[i], y: cur.y + n[i + 1]) : CGPoint(x: n[i], y: n[i + 1])
                if i == 0 { path.move(to: pt(p.x, p.y)); start = p } else { path.addLine(to: pt(p.x, p.y)) }
                cur = p; i += 2
            }
        case "l":
            var i = 0
            while i + 1 < n.count {
                let p = rel ? CGPoint(x: cur.x + n[i], y: cur.y + n[i + 1]) : CGPoint(x: n[i], y: n[i + 1])
                path.addLine(to: pt(p.x, p.y)); cur = p; i += 2
            }
        case "h":
            for v in n { let p = CGPoint(x: rel ? cur.x + v : v, y: cur.y); path.addLine(to: pt(p.x, p.y)); cur = p }
        case "v":
            for v in n { let p = CGPoint(x: cur.x, y: rel ? cur.y + v : v); path.addLine(to: pt(p.x, p.y)); cur = p }
        case "c":
            var i = 0
            while i + 5 < n.count {
                let c1 = rel ? CGPoint(x: cur.x + n[i], y: cur.y + n[i + 1]) : CGPoint(x: n[i], y: n[i + 1])
                let c2 = rel ? CGPoint(x: cur.x + n[i + 2], y: cur.y + n[i + 3]) : CGPoint(x: n[i + 2], y: n[i + 3])
                let p = rel ? CGPoint(x: cur.x + n[i + 4], y: cur.y + n[i + 5]) : CGPoint(x: n[i + 4], y: n[i + 5])
                path.addCurve(to: pt(p.x, p.y), control1: pt(c1.x, c1.y), control2: pt(c2.x, c2.y))
                cur = p; lastCtrl = c2; i += 6
            }
        case "s":
            // 第1制御点は「直前の三次曲線の第2制御点を現在点で反転したもの」。
            // 直前が C/S でなければ反転する材料が無いので現在点そのものを使う(仕様)。
            var i = 0
            while i + 3 < n.count {
                let mirrored = (prevCmd == "c" || prevCmd == "s")
                    ? CGPoint(x: 2 * cur.x - lastCtrl.x, y: 2 * cur.y - lastCtrl.y) : cur
                let c2 = rel ? CGPoint(x: cur.x + n[i], y: cur.y + n[i + 1]) : CGPoint(x: n[i], y: n[i + 1])
                let p = rel ? CGPoint(x: cur.x + n[i + 2], y: cur.y + n[i + 3]) : CGPoint(x: n[i + 2], y: n[i + 3])
                path.addCurve(to: pt(p.x, p.y), control1: pt(mirrored.x, mirrored.y), control2: pt(c2.x, c2.y))
                cur = p; lastCtrl = c2; i += 4
            }
        case "q":
            var i = 0
            while i + 3 < n.count {
                let c = rel ? CGPoint(x: cur.x + n[i], y: cur.y + n[i + 1]) : CGPoint(x: n[i], y: n[i + 1])
                let p = rel ? CGPoint(x: cur.x + n[i + 2], y: cur.y + n[i + 3]) : CGPoint(x: n[i + 2], y: n[i + 3])
                path.addQuadCurve(to: pt(p.x, p.y), control: pt(c.x, c.y))
                cur = p; lastCtrl = c; i += 4
            }
        case "t":
            // Q の省略記法。制御点は直前の二次曲線の制御点の鏡像(S と同じ理屈)。
            var i = 0
            while i + 1 < n.count {
                let c = (prevCmd == "q" || prevCmd == "t")
                    ? CGPoint(x: 2 * cur.x - lastCtrl.x, y: 2 * cur.y - lastCtrl.y) : cur
                let p = rel ? CGPoint(x: cur.x + n[i], y: cur.y + n[i + 1]) : CGPoint(x: n[i], y: n[i + 1])
                path.addQuadCurve(to: pt(p.x, p.y), control: pt(c.x, c.y))
                cur = p; lastCtrl = c; i += 2
            }
        case "a":
            // rx ry x-axis-rotation large-arc-flag sweep-flag x y の7つ1組。
            var i = 0
            while i + 6 < n.count {
                let p = rel ? CGPoint(x: cur.x + n[i + 5], y: cur.y + n[i + 6])
                            : CGPoint(x: n[i + 5], y: n[i + 6])
                addArc(cur, n[i], n[i + 1], n[i + 2], n[i + 3] != 0, n[i + 4] != 0, p)
                cur = p; i += 7
            }
        case "z":
            path.closeSubpath(); cur = start
        default:
            break
        }
    }
    return path
}

/// 現在パスを、ベタ塗りかグラデーションで塗る。
///
/// グラデーションは「パスでクリップしてから矩形いっぱいに描く」形で実装する。
/// clip() は現在パスを消費するので、この関数を呼ぶ前にパスを積んでおくこと。
/// 座標は呼び出し側の変換(平行移動・回転・拡大)がかかった空間のままで扱うので、
/// グラデーションの向きも図形と一緒に回る(回した板に光が同じ向きから当たる)。
func paint(_ ctx: CGContext, _ l: Layer, evenOdd: Bool = false) {
    guard let g = l.gradient else {
        ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        return
    }
    let box = ctx.boundingBoxOfPath
    ctx.clip(using: evenOdd ? .evenOdd : .winding)

    let colors = g.stops.map { $0.0 } as CFArray
    let locs = g.stops.map { $0.1 }
    guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                colors: colors, locations: locs) else { return }

    let c = CGPoint(x: box.minX + box.width * g.center.x,
                    y: box.minY + box.height * (1 - g.center.y))  // center.y は上端基準で書く
    if g.kind == "radial" {
        let rad = max(box.width, box.height) / 2 * g.radius
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: max(rad, 1),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    } else {
        // angle は 0 = 左→右、反時計回りが正。図形の外接矩形を端から端まで貫く長さを取る。
        let a = g.angle * .pi / 180
        let half = hypot(box.width, box.height) / 2
        let mid = CGPoint(x: box.midX, y: box.midY)
        let s = CGPoint(x: mid.x - cos(a) * half, y: mid.y - sin(a) * half)
        let e = CGPoint(x: mid.x + cos(a) * half, y: mid.y + sin(a) * half)
        ctx.drawLinearGradient(grad, start: s, end: e,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

/// 上端基準の座標で図形を塗る。回転は図形の中心まわり。
func draw(_ ctx: CGContext, _ l: Layer) {
    ctx.saveGState()
    ctx.setAlpha(l.opacity)
    ctx.translateBy(x: l.cx, y: S - l.cy)
    ctx.rotate(by: l.angle * .pi / 180)
    ctx.setFillColor(hex(l.color))
    ctx.setStrokeColor(hex(l.color))

    switch l.shape {
    case "circle":
        ctx.addEllipse(in: CGRect(x: -l.w / 2, y: -l.h / 2, width: l.w, height: l.h))
        paint(ctx, l)

    case "ring":
        // 線幅の中心が指定径になるよう、径から thickness の半分を引いた円を stroke する。
        // グラデーションを乗せるため、stroke を輪郭パスへ変換してから塗る。
        ctx.setLineWidth(l.thickness)
        let d = l.w - l.thickness
        ctx.addEllipse(in: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))
        ctx.replacePathWithStrokedPath()
        paint(ctx, l)

    case "arc":
        // 円弧。NFC の波紋やカメラの部分リングに使う。端は丸めて途切れ感を出さない。
        // CoreGraphics の角度は反時計回り・ラジアンなので、度→ラジアン変換して渡す。
        ctx.setLineWidth(l.thickness)
        ctx.setLineCap(.round)
        let radius = (l.w - l.thickness) / 2
        ctx.addArc(center: .zero, radius: radius,
                   startAngle: l.startAngle * .pi / 180,
                   endAngle: l.endAngle * .pi / 180,
                   clockwise: false)
        ctx.replacePathWithStrokedPath()
        paint(ctx, l)

    case "capsule":
        // 角丸を高さの半分に固定した帯。テキスト行やスライダの抽象に使う。
        let rect = CGRect(x: -l.w / 2, y: -l.h / 2, width: l.w, height: l.h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: l.h / 2, cornerHeight: l.h / 2,
                           transform: nil))
        paint(ctx, l)

    case "path":
        // SVG パス。cx/cy は「パスの viewBox 中心をどこへ置くか」として扱い、
        // w を指定すれば viewBox からの拡大率になる(未指定なら等倍)。
        //
        // 【fillRule】既定は非ゼロ塗り(nonZero)。`"fillRule": "evenOdd"` を指定すると
        // 重なった領域が穴になる。これが無いと **1つのパスで穴の空いた形が作れない** ——
        // 外側の輪郭と内側の輪郭を同じ向きで書いても、非ゼロ塗りでは内側が塗り潰されてしまい、
        // 「巻き方向を逆にする」ことでしか穴を開けられなかった(手書きの d では事故のもと)。
        // 生成 AI やデザインツールが吐く d は even-odd 前提のものが多いという事情もある。
        //
        // 【塗りか線か】既定は塗り。`"thickness"` を指定すると代わりに stroke する。
        // stroke が要る理由: 渦巻き・蛇行するリボンのような「一定の太さの1本の線」は、
        // 塗りで作ろうとすると輪郭のオフセット曲線を手で書くことになり事実上書けない。
        // 線で描ければ d は中心線1本で済み、太さは thickness で後から振れる。
        // 端と角は丸める —— アイコンでは尖った端は硬く見え、Apple の純正も丸で統一されている。
        let scale = l.w > 0 ? l.w / l.viewBox : 1
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -l.viewBox / 2, y: -l.viewBox / 2)
        ctx.addPath(parseSVGPath(l.pathD, viewBox: l.viewBox))
        if l.strokePath {
            // 線幅は viewBox 基準で書けるほうが d と単位が揃って考えやすいので、
            // scaleBy 後の座標系でそのまま thickness を使う(結果として w に比例して太る)。
            ctx.setLineWidth(l.thickness)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
            paint(ctx, l)
        } else {
            paint(ctx, l, evenOdd: l.evenOdd)
        }

    default:  // roundedRect
        ctx.addPath(CGPath(roundedRect: CGRect(x: -l.w / 2, y: -l.h / 2, width: l.w, height: l.h),
                           cornerWidth: l.r, cornerHeight: l.r, transform: nil))
        paint(ctx, l)
    }
    ctx.restoreGState()
}

/// アルファが立っているピクセルの外接矩形(左上原点)。
///
/// CGBitmapContext の描画座標系は左下原点だが、**メモリ上の並びは top-down**
/// (先頭バイトが左上ピクセル)。したがって row はそのまま左上原点の y になる。
/// ここを反転させると autofit の centering が上下にずれるので注意。
func alphaBounds(_ ctx: CGContext) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    guard let data = ctx.data else { return nil }
    let bpr = ctx.bytesPerRow
    let ptr = data.bindMemory(to: UInt8.self, capacity: bpr * Int(S))
    var minX = Int(S), minY = Int(S), maxX = -1, maxY = -1
    for row in 0..<Int(S) {
        for col in 0..<Int(S) where ptr[row * bpr + col * 4 + 3] > 8 {
            if col < minX { minX = col }
            if col > maxX { maxX = col }
            if row < minY { minY = row }
            if row > maxY { maxY = row }
        }
    }
    return maxX < 0 ? nil : (minX, minY, maxX, maxY)
}

func composite(_ ls: [Layer]) -> CGContext {
    let ctx = makeContext()
    for l in ls { draw(ctx, l) }
    return ctx
}

// MARK: - autofit(中央寄せ + 安全域いっぱいへスケール)

var placed = layers
if doAutofit, let b = alphaBounds(composite(layers)) {
    let cx = CGFloat(b.minX + b.maxX) / 2, cy = CGFloat(b.minY + b.maxY) / 2
    let w = CGFloat(b.maxX - b.minX), h = CGFloat(b.maxY - b.minY)
    // 0.997 は丸め誤差で 1px はみ出すのを防ぐための余裕。
    let scale = (S - 2 * safeMargin) / max(w, h) * 0.997
    placed = layers.map { l in
        var m = l
        m.cx = S / 2 + (l.cx - cx) * scale
        m.cy = S / 2 + (l.cy - cy) * scale
        // thickness も一緒に拡縮する。しないと autofit で図形だけ大きくなり線が相対的に細る。
        m.w *= scale; m.h *= scale; m.r *= scale; m.thickness *= scale
        return m
    }
}

// MARK: - 出力と検査

for l in placed {
    let ctx = makeContext()
    draw(ctx, l)
    save(ctx, l.name)
}

// 合成プレビュー(背景なし)。個別レイヤーだけでは重なりの具合が分からないため。
let comp = composite(placed)
save(comp, "_composite")

guard let b = alphaBounds(comp) else { print("EMPTY"); exit(1) }
let lo = Int(safeMargin), hi = Int(S - safeMargin)
let ok = b.minX >= lo && b.minY >= lo && b.maxX <= hi && b.maxY <= hi
print(String(format: "bbox=(%d,%d)-(%d,%d) size=%dx%d center=(%d,%d) %@",
             b.minX, b.minY, b.maxX, b.maxY,
             b.maxX - b.minX, b.maxY - b.minY,
             (b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2,
             ok ? "SAFE" : "*** OVERFLOW (safe area \(lo)..\(hi)) ***"))
print("layers: " + placed.map { $0.name }.joined(separator: ", "))
exit(ok ? 0 : 3)
