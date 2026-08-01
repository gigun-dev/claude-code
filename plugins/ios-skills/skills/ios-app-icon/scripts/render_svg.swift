// SVG を WebKit でラスタライズし、.icon 用のレイヤー PNG 群を書き出す。
//
// 【なぜ SVG を直接書く経路が要るか・2026-08-02】
// draw_layers.swift は「shape / cx / cy / w / h …」という自作の JSON DSL を通る表現しか
// 作れない。新しい表現(放射グラデーション、マスク、ブレンド、ぼかし)が要るたびに
// Swift 側を拡張する必要があり、**その DSL が表現力の上限になっていた**。実際、案が
// どれも平坦で「グラデーションが無く Liquid Glass に頼っている」と評価される状態が続いた。
// SVG ならその上限が無い ── グラデーション(多段・放射・円錐)、mask、clipPath、
// feGaussianBlur、mix-blend-mode、opacity、group transform が最初から全部使える。
// デザインツールや画像生成 AI が吐く SVG をそのまま貼れるという利点も大きい。
//
// 【なぜ WebKit か】macOS に追加インストールなしで載っている SVG 実装は QuickLook
// (qlmanage)か WebKit の2つ。qlmanage はサイズ指定が甘く、フィルタやブレンドの
// 対応が不透明で、透過の制御もできない。WebKit は Safari と同じレンダラなので
// SVG/CSS の仕様どおりに描け、出力サイズと透過を明示的に指定できる。
//
// 【レイヤー分割の作り方】.icon は層ごとに別 PNG が要る。SVG を層の数だけ書くと
// 位置がズレるので、**1枚の SVG に `data-layer` を付けたグループを並べ、同じ SVG を
// 「その層だけ表示」で N 回レンダリングする**。座標は1つの定義から来るのでズレようがない。
//
// 使い方:
//   swift render_svg.swift <input.svg> <outDir> [--size 1024]
// input.svg の中で層を分けたいときは:
//   <g data-layer="01-back"> … </g>
//   <g data-layer="02-front"> … </g>
// data-layer が1つも無ければ全体を composite.png として1枚だけ書き出す。

import AppKit
import WebKit

let argv = CommandLine.arguments
guard argv.count >= 3 else {
    fputs("usage: swift render_svg.swift <input.svg> <outDir> [--size N]\n", stderr)
    exit(2)
}
let inURL = URL(fileURLWithPath: argv[1])
let outDir = URL(fileURLWithPath: argv[2])
var size: CGFloat = 1024
if let i = argv.firstIndex(of: "--size"), i + 1 < argv.count, let v = Double(argv[i + 1]) {
    size = CGFloat(v)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let svg = try? String(contentsOf: inURL, encoding: .utf8) else {
    fputs("error: cannot read \(inURL.path)\n", stderr)
    exit(1)
}

/// `data-layer="..."` を出現順に拾う。順序は SVG の描画順(先が奥)のまま返す。
func layerNames(_ s: String) -> [String] {
    var names: [String] = []
    let pattern = "data-layer\\s*=\\s*[\"']([^\"']+)[\"']"
    let re = try! NSRegularExpression(pattern: pattern)
    let ns = s as NSString
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let n = ns.substring(with: m.range(at: 1))
        if !names.contains(n) { names.append(n) }
    }
    return names
}

let names = layerNames(svg)

/// 1層だけ表示する CSS。SVG でも display:none は効くので、これで層を切り替える。
/// CSS 属性セレクタの値はクォートで囲むので、値に " が入るとセレクタが壊れる ——
/// data-layer 名には英数とハイフンだけ使うこと(ここでは念のため除去する)。
func isolateCSS(_ name: String?) -> String {
    guard let name else { return "" }
    let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return "[data-layer]{display:none!important}[data-layer=\"\(safe)\"]{display:inline!important}"
}

func html(_ css: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;padding:0;background:transparent;overflow:hidden}
    svg{display:block;width:\(Int(size))px;height:\(Int(size))px}
    \(css)
    </style></head><body>\(svg)</body></html>
    """
}

// WKWebView はウィンドウに載っていないとスナップショットが空になることがあるので、
// 画面外にウィンドウを作って載せる(activationPolicy は prohibited なので UI は出ない)。
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let frame = CGRect(x: 0, y: 0, width: size, height: size)
let config = WKWebViewConfiguration()
let web = WKWebView(frame: frame, configuration: config)
web.setValue(false, forKey: "drawsBackground")   // 背景を透過にする(KVC が macOS での定石)
if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }

let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                      backing: .buffered, defer: false)
window.isOpaque = false
window.backgroundColor = .clear
window.contentView = web
window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
window.orderBack(nil)

final class Nav: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
        fputs("load failed: \(e)\n", stderr); done = true
    }
}
let nav = Nav()
web.navigationDelegate = nav

func pump(until cond: @escaping () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return cond()
}

func snapshot(_ name: String, css: String) {
    nav.done = false
    web.loadHTMLString(html(css), baseURL: inURL.deletingLastPathComponent())
    guard pump(until: { nav.done }) else {
        fputs("timeout loading \(name)\n", stderr); return
    }
    // 読み込み完了直後はまだ描画が済んでいないことがあるので1フレーム分待つ。
    _ = pump(until: { false }, timeout: 0.15)

    let cfg = WKSnapshotConfiguration()
    cfg.rect = frame
    cfg.snapshotWidth = NSNumber(value: Double(size))
    var image: NSImage?
    var finished = false
    web.takeSnapshot(with: cfg) { img, err in
        if let err { fputs("snapshot error: \(err)\n", stderr) }
        image = img; finished = true
    }
    // 【必ずピクセル数を固定する】WKSnapshotConfiguration.snapshotWidth は**ポイント**指定なので、
    // Retina では 2 倍のピクセル数で返る(1024 を頼んで 2048px の PNG が出る)。
    // そのまま .icon へ入れると ictool がレイヤーを 2 倍で扱い、絵が拡大されて縁で切れる
    // ——「素材は正しいのに最終レンダリングだけ拡大されている」という分かりにくい壊れ方をした。
    // NSImage の size もポイントなので当てにならない。ここで実ピクセルの
    // ビットマップへ描き直して、出力を必ず size×size ピクセルにする。
    guard pump(until: { finished }), let img = image else {
        fputs("snapshot failed for \(name)\n", stderr); return
    }
    let px = Int(size)
    guard let out = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("resize failed for \(name)\n", stderr); return
    }
    out.interpolationQuality = .high
    out.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let outImage = out.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              outDir.appendingPathComponent("\(name).png") as CFURL,
              "public.png" as CFString, 1, nil) else {
        fputs("encode failed for \(name)\n", stderr); return
    }
    CGImageDestinationAddImage(dest, outImage, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name).png (\(px)x\(px))")
}

if names.isEmpty {
    snapshot("composite", css: "")
} else {
    for n in names { snapshot(n, css: isolateCSS(n)) }
    snapshot("_composite", css: "")
    print("layers (奥→手前の描画順): \(names.joined(separator: ", "))")
    print("※ build_icon.sh へは **手前から** 渡すこと(icon.json の layers は先頭が最前面)")
}
exit(0)
