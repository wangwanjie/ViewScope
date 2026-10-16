import AppKit
import CoreGraphics

// 生成 ViewScope 应用图标：深色圆角底 + 三层等距图层 + 选中框
// 用法：
//   swift scripts/generate_app_icon.swift /tmp/icon_1024.png
//   然后用 sips 缩放出 AppIcon.appiconset 所需的 16~1024 各尺寸
let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS 图标网格：824 内容区，四周 100 留白
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 底板投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x0E1428))
ctx.fillPath()
ctx.restoreGState()

// 底板渐变
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x232B52), rgb(0x0B1020)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// 中心柔光
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x2E7BFF, 0.35), rgb(0x2E7BFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
ctx.restoreGState()

// 底板内描边高光
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// 圆角菱形（等距平面）
func diamond(center c: CGPoint, halfWidth w: CGFloat, halfHeight h: CGFloat, radius r: CGFloat) -> CGPath {
    let pts = [CGPoint(x: c.x, y: c.y + h), CGPoint(x: c.x + w, y: c.y), CGPoint(x: c.x, y: c.y - h), CGPoint(x: c.x - w, y: c.y)]
    let p = CGMutablePath()
    let start = CGPoint(x: (pts[3].x + pts[0].x) / 2, y: (pts[3].y + pts[0].y) / 2)
    p.move(to: start)
    for i in 0..<4 {
        p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: r)
    }
    p.closeSubpath()
    return p
}

struct Layer {
    let y: CGFloat
    let top: UInt32
    let bottom: UInt32
    let fillAlpha: CGFloat
    let stroke: UInt32
    let strokeAlpha: CGFloat
}

let hw: CGFloat = 290
let hh: CGFloat = 168
let layers = [
    Layer(y: 352, top: 0x4C3FE0, bottom: 0x2A2390, fillAlpha: 0.80, stroke: 0x8B80FF, strokeAlpha: 0.75),
    Layer(y: 494, top: 0x1F8BFF, bottom: 0x1650C8, fillAlpha: 0.78, stroke: 0x7CC0FF, strokeAlpha: 0.80),
    Layer(y: 636, top: 0x3EE6F5, bottom: 0x14A8D6, fillAlpha: 0.95, stroke: 0xE6FDFF, strokeAlpha: 0.95)
]

for layer in layers {
    let path = diamond(center: CGPoint(x: 512, y: layer.y), halfWidth: hw, halfHeight: hh, radius: 34)
    // 图层厚度：向下偏移的暗色副本
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: rgb(0x000000, 0.45))
    ctx.translateBy(x: 0, y: -14)
    ctx.addPath(path)
    ctx.setFillColor(rgb(layer.bottom, 0.95))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(layer.top, layer.fillAlpha), rgb(layer.bottom, layer.fillAlpha)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512 - hw * 0.5, y: layer.y + hh), end: CGPoint(x: 512 + hw * 0.5, y: layer.y - hh), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(layer.stroke, layer.strokeAlpha))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()
}

// 顶层上的选中元素：琥珀色描边小菱形 + 四角控制点
let selCenter = CGPoint(x: 512 + 70, y: 636 + 18)
let sw: CGFloat = 118
let sh: CGFloat = 68
let selPath = diamond(center: selCenter, halfWidth: sw, halfHeight: sh, radius: 14)
ctx.saveGState()
ctx.addPath(selPath)
ctx.setFillColor(rgb(0xFFB020, 0.28))
ctx.fillPath()
ctx.addPath(selPath)
ctx.setStrokeColor(rgb(0xFFB020))
ctx.setLineWidth(10)
ctx.setShadow(offset: .zero, blur: 18, color: rgb(0xFFB020, 0.7))
ctx.strokePath()
ctx.restoreGState()

for p in [CGPoint(x: selCenter.x, y: selCenter.y + sh), CGPoint(x: selCenter.x + sw, y: selCenter.y), CGPoint(x: selCenter.x, y: selCenter.y - sh), CGPoint(x: selCenter.x - sw, y: selCenter.y)] {
    let r: CGFloat = 15
    ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    ctx.setStrokeColor(rgb(0xFFB020))
    ctx.setLineWidth(6)
    ctx.strokePath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let out = CommandLine.arguments[1]
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
