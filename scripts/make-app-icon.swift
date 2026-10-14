import AppKit
import CoreGraphics

// Renders the MacMiniMixer app icon at every asset-catalog size: three faders on a
// transparent canvas, no background tile.
// Usage: swift scripts/make-app-icon.swift MacMiniMixer/Support/Assets.xcassets/AppIcon.appiconset
let outDir = CommandLine.arguments[1]

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
}

func capsule(_ r: CGRect) -> CGPath {
    let radius = min(r.width, r.height) / 2
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Colors chosen to read on both light and dark Finder/Dock backgrounds.
    let accent = rgb(0x3D8BFF)
    let trackOff = rgb(0xA3A6AE)
    let knob = rgb(0xFFFFFF)
    let knobRing = rgb(0x000000, 0.14)

    // three faders, sized to fill the 824pt macOS icon grid
    let xs: [CGFloat] = [282, 512, 742]
    let levels: [CGFloat] = [0.42, 0.74, 0.28]   // knob position 0..1
    let bottom: CGFloat = 200, top: CGFloat = 824
    let tw: CGFloat = 96, kr: CGFloat = 104
    for (x, lv) in zip(xs, levels) {
        let ky = bottom + (top - bottom) * lv
        // unfilled track, with a soft shadow so the whole fader lifts off any background
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: rgb(0x000000, 0.22))
        ctx.addPath(capsule(CGRect(x: x - tw/2, y: bottom - tw/2, width: tw, height: top - bottom + tw)))
        ctx.setFillColor(trackOff); ctx.fillPath()
        ctx.restoreGState()
        // filled part
        ctx.addPath(capsule(CGRect(x: x - tw/2, y: bottom - tw/2, width: tw, height: ky - bottom + tw/2)))
        ctx.setFillColor(accent); ctx.fillPath()
        // knob
        let knobRect = CGRect(x: x - kr, y: ky - kr, width: kr*2, height: kr*2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
        ctx.addEllipse(in: knobRect)
        ctx.setFillColor(knob); ctx.fillPath()
        ctx.restoreGState()
        ctx.addEllipse(in: knobRect.insetBy(dx: 3, dy: 3))
        ctx.setStrokeColor(knobRing); ctx.setLineWidth(6); ctx.strokePath()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(px).png"))
}
