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
//       "cx": 652, "cy": 664, "d": 356, "color": "#fbbf24" }
//   ]
// }
// 座標は「左上原点・上から測った y」で書く(デザインツールと同じ感覚)。
// CoreGraphics の左下原点はスクリプト側で吸収する。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 入力

let args = CommandLine.arguments
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

func hex(_ s: String) -> CGColor {
    var h = s.replacingOccurrences(of: "#", with: "")
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    let v = UInt32(h, radix: 16) ?? 0
    return CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
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
    var color: String
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
        color: d["color"] as? String ?? "#ffffff")
}

/// SVG の `d` 属性を CGPath へ変換する(M/L/H/V/C/Q/Z と相対版に対応)。
///
/// 【なぜ必要か】角丸長方形・円・円環だけだと、作れる構図が「面と点の構成」に偏る。
/// どのアプリのアイコンを作っても似た絵になり、実際に「二番煎じ」と評価された。
/// 任意パスが描ければ、切り欠き・非対称な塊・記号的な曲線といった語彙が使え、
/// デザインツールや生成 AI の草案をそのまま持ち込める。
///
/// 対応するのは M/m L/l H/h V/v C/c Q/q Z/z。円弧(A)は使う場面が少なく実装コストが高いので
/// 省いた —— 円弧が要るなら shape:"arc" を使う。
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
    for ch in d {
        if ch.isLetter {
            flushCmd()
            currentCmd = ch
        } else if ch == "-" && !numberBuf.isEmpty && numberBuf.last != "e" {
            flushNumber()      // 区切りなしの負数("10-5")に対応
            numberBuf = "-"
        } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
            flushNumber()
        } else {
            numberBuf.append(ch)
        }
    }
    flushCmd()

    // SVG(y 下向き・viewBox 基準)→ CoreGraphics(y 上向き・canvas 基準)。
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: viewBox - y) }

    for (cmd, n) in tokens {
        let rel = cmd.isLowercase
        switch Character(cmd.lowercased()) {
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
        case "q":
            var i = 0
            while i + 3 < n.count {
                let c = rel ? CGPoint(x: cur.x + n[i], y: cur.y + n[i + 1]) : CGPoint(x: n[i], y: n[i + 1])
                let p = rel ? CGPoint(x: cur.x + n[i + 2], y: cur.y + n[i + 3]) : CGPoint(x: n[i + 2], y: n[i + 3])
                path.addQuadCurve(to: pt(p.x, p.y), control: pt(c.x, c.y))
                cur = p; lastCtrl = c; i += 4
            }
        case "z":
            path.closeSubpath(); cur = start
        default:
            break
        }
        _ = lastCtrl
    }
    return path
}

/// 上端基準の座標で図形を塗る。回転は図形の中心まわり。
func draw(_ ctx: CGContext, _ l: Layer) {
    ctx.saveGState()
    ctx.translateBy(x: l.cx, y: S - l.cy)
    ctx.rotate(by: l.angle * .pi / 180)
    ctx.setFillColor(hex(l.color))
    ctx.setStrokeColor(hex(l.color))

    switch l.shape {
    case "circle":
        ctx.fillEllipse(in: CGRect(x: -l.w / 2, y: -l.h / 2, width: l.w, height: l.h))

    case "ring":
        // 線幅の中心が指定径になるよう、径から thickness の半分を引いた円を stroke する。
        ctx.setLineWidth(l.thickness)
        let d = l.w - l.thickness
        ctx.strokeEllipse(in: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))

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
        ctx.strokePath()

    case "capsule":
        // 角丸を高さの半分に固定した帯。テキスト行やスライダの抽象に使う。
        let rect = CGRect(x: -l.w / 2, y: -l.h / 2, width: l.w, height: l.h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: l.h / 2, cornerHeight: l.h / 2,
                           transform: nil))
        ctx.fillPath()

    case "path":
        // SVG パス。cx/cy は「パスの viewBox 中心をどこへ置くか」として扱い、
        // w を指定すれば viewBox からの拡大率になる(未指定なら等倍)。
        let scale = l.w > 0 ? l.w / l.viewBox : 1
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -l.viewBox / 2, y: -l.viewBox / 2)
        ctx.addPath(parseSVGPath(l.pathD, viewBox: l.viewBox))
        ctx.fillPath()

    default:  // roundedRect
        ctx.addPath(CGPath(roundedRect: CGRect(x: -l.w / 2, y: -l.h / 2, width: l.w, height: l.h),
                           cornerWidth: l.r, cornerHeight: l.r, transform: nil))
        ctx.fillPath()
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
