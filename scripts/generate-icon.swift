import AppKit
import Foundation

// Reproducible artwork using native vector drawing; no downloaded assets.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("dist/Stoneaxe.iconset")
let docs = root.appendingPathComponent("docs/images")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
let shapes: [(String, [(CGFloat, CGFloat)])] = [
    ("#B57647", [(266,714),(266,666),(490,442),(550,502),(326,726),(278,726)]),
    ("#E4A56A", [(266,666),(490,442),(512,464),(288,688)]),
    ("#865136", [(302,700),(526,476),(550,502),(326,726),(302,726)]),
    ("#B9C7C8", [(254,334),(302,286),(398,262),(494,262),(494,286),(566,310),(638,382),(710,478),(758,574),(758,646),(710,598),(662,526),(590,454),(494,382),(398,358),(326,358),(254,382)]),
    ("#F0F3E9", [(254,334),(302,286),(398,262),(494,262),(494,286),(566,310),(638,382),(614,406),(542,334),(470,310),(374,310),(302,334),(254,358)]),
    ("#849B9E", [(590,454),(638,478),(710,550),(758,646),(710,598),(662,526)]),
    ("#DB965A", [(466,382),(490,358),(562,430),(538,454)]),
    ("#F4C48B", [(722,288),(746,288),(746,312),(770,312),(770,336),(746,336),(746,360),(722,360),(722,336),(698,336),(698,312),(722,312)])
]
func color(_ hex: String) -> NSColor {
    let v = UInt32(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 255)/255, green: CGFloat((v >> 8) & 255)/255, blue: CGFloat(v & 255)/255, alpha: 1)
}
func png(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGradient(starting: color("#35464B"), ending: color("#1B272D"))!.draw(in: tile, angle: 90)
    for (fill, points) in shapes {
        let path = NSBezierPath(); path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for p in points.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
        path.close(); color(fill).setFill(); path.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16,32,128,256,512] {
    try png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size*2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try png(512).write(to: docs.appendingPathComponent("stoneaxe-icon.png"))
print("Generated Stoneaxe iconset and README artwork")
