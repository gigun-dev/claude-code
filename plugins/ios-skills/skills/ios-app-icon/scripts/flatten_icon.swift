// レイヤー PNG 群を背景色の上に合成して、appiconset 用のフラット 1024 画像を作る。
//
// なぜ ictool の出力を流用しないか:
// ictool --export-image は iOS の角丸マスクを**かけた状態**で書き出す。
// appiconset に入れるのは角丸なしの正方形フルブリード画像なので、
// マスク済み画像を入れると角丸が二重にかかって隅が削れる。
// 旧 OS には Liquid Glass が無いため光沢も不要で、素の合成でちょうどよい。
//
// なお .icon を入れておけば Xcode が旧 OS 用のフラット版を自動生成するので、
// appiconset は必須ではない。deploymentTarget が古く、確実を期したいときの保険として使う。
//
// 使い方:
//   swift flatten_icon.swift <背景色hex> <出力.png> <レイヤーPNG...>

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
    print("Usage: swift flatten_icon.swift <background-hex> <out.png> <layer.png> [layer.png ...]")
    exit(0)
}
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: swift flatten_icon.swift <bg-hex> <out.png> <layer.png...>\n".data(using: .utf8)!)
    exit(2)
}

func hex(_ s: String) -> CGColor {
    var h = s.replacingOccurrences(of: "#", with: "")
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    let v = UInt32(h, radix: 16) ?? 0
    return CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

let S = 1024
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(hex(args[1]))
ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(S), height: CGFloat(S)))

for path in args[3...] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(S), height: CGFloat(S)))
}

let out = URL(fileURLWithPath: args[2])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.lastPathComponent)")
