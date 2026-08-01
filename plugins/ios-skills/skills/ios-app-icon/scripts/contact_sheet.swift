// ディレクトリ内の PNG を 1 枚の比較シートにまとめる。
//
// なぜ必要か:
// アイコンの良し悪しは並べないと判断できない。1案ずつ見ると全部それなりに見えてしまう。
// さらに重要なのが**実サイズでの確認**で、1024px で成立していても 80pt に落とすと
// 要素が潰れて何も読めない案が普通にある(3枚以上重ねた案はだいたいこれで落ちる)。
// そこで各画像を「大(角丸マスク付き)」と「120pt / 80pt 相当」の3つ並べて出す。
//
// 角丸は iOS の superellipse ではなく角丸長方形での近似(半径 22.37%)。
// 当たりを見るには十分で、正確な形状が要るときは実機で見る。
//
// 使い方:
//   swift contact_sheet.swift <PNGのあるディレクトリ> <出力.png> [列数]
// ファイルは名前順に並ぶので、01- 02- のように番号を振っておくと順序を制御できる。

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: swift contact_sheet.swift <dir> <out.png> [cols]\n".data(using: .utf8)!)
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let cols = args.count > 3 ? max(1, Int(args[3]) ?? 3) : 3

let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == "png" && !$0.lastPathComponent.hasPrefix("_") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    FileHandle.standardError.write("error: no png found in \(dir.path)\n".data(using: .utf8)!)
    exit(1)
}

let cell: CGFloat = 380
let pad: CGFloat = 24
let strip: CGFloat = 130          // 実サイズ見本の帯の高さ
let rows = (files.count + cols - 1) / cols
let W = CGFloat(cols) * (cell + pad) + pad
let H = CGFloat(rows) * (cell + strip + pad) + pad

let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

func rounded(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: r.width * 0.2237, cornerHeight: r.width * 0.2237, transform: nil)
}

func drawMasked(_ img: CGImage, _ rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(rounded(rect))
    ctx.clip()
    ctx.draw(img, in: rect)
    ctx.restoreGState()
}

for (i, f) in files.enumerated() {
    guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    let c = CGFloat(i % cols), r = CGFloat(i / cols)
    let x = pad + c * (cell + pad)
    let y = H - pad - (r + 1) * (cell + strip + pad) + strip

    drawMasked(img, CGRect(x: x, y: y, width: cell, height: cell))
    // ホーム画面での実寸に近いサイズ。ここで読めなければその案は落ちる。
    drawMasked(img, CGRect(x: x, y: y - strip + 10, width: 120, height: 120))
    drawMasked(img, CGRect(x: x + 140, y: y - strip + 30, width: 80, height: 80))
}

guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path) — \(files.count) icons: \(files.map { $0.lastPathComponent }.joined(separator: ", "))")
