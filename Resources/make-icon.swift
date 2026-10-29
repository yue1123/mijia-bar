// 生成 App 图标：swift Resources/make-icon.swift Resources/AppIcon.icns
//
// 深蓝夜空圆角方块上一盏亮着的灯泡，灯泡和光线照菜单栏图标（Tabler Icons 的 bulb-filled）的 24×24 网格画。
// 各尺寸都从矢量直接画，不是缩放一张大图；画完交给 iconutil 打成 .icns。
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // 按 1024 的画布写坐标，y 朝下，和 SVG 一致
    let k = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: k, y: -k)

    // 底板：macOS 图标网格，1024 画布里 824 的圆角方块，四周留 100 给阴影
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: 10)  // 坐标翻过，正值朝下
    shadow.set()
    NSColor.black.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.38, alpha: 1),
                        NSColor(red: 0.05, green: 0.06, blue: 0.15, alpha: 1)])!
        .draw(in: plate, angle: 90)
    // 灯泡周围的暖光
    NSGradient(colors: [NSColor(red: 1, green: 0.72, blue: 0.25, alpha: 0.55),
                        NSColor(red: 1, green: 0.55, blue: 0.15, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 400, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // 24 网格映射到画布：灯泡区域（x 3…21，y 3…22）放在底板中间
    let s: CGFloat = 30, ox: CGFloat = 512 - 12 * s, oy: CGFloat = 512 - 12.8 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }

    // 光线：M3 12h1m8 -9v1m8 8h1m-15.4 -6.4l.7 .7m12.1 -.7l-.7 .7
    let rays = NSBezierPath()
    for (a, b) in [((3, 12), (4, 12)), ((12, 3), (12, 4)), ((20, 12), (21, 12)),
                   ((5.6, 5.6), (6.3, 6.3)), ((18.4, 5.6), (17.7, 6.3))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
        rays.move(to: p(a.0, a.1))
        rays.line(to: p(b.0, b.1))
    }
    rays.lineWidth = 2 * s
    rays.lineCapStyle = .round
    NSColor(red: 1, green: 0.78, blue: 0.35, alpha: 1).setStroke()
    rays.stroke()

    // 玻璃：半径 6 的圆在 y=17 处截平
    let dx = CGFloat(11).squareRoot()
    let glass = NSBezierPath()
    func angle(_ x: CGFloat, _ y: CGFloat) -> CGFloat { atan2(y - 12, x - 12) * 180 / .pi }
    glass.appendArc(withCenter: p(12, 12), radius: 6 * s, startAngle: angle(12 - dx, 17), endAngle: angle(12 + dx, 17), clockwise: false)
    glass.close()
    NSGradient(colors: [NSColor(red: 1, green: 0.99, blue: 0.88, alpha: 1),
                        NSColor(red: 1, green: 0.84, blue: 0.40, alpha: 1),
                        NSColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 1)])!
        .draw(in: glass, relativeCenterPosition: NSPoint(x: -0.25, y: 0.3))

    // 灯头：顶边圆角 1，底部半径 3 的半圆
    let cap = NSBezierPath()
    cap.move(to: p(12, 18))
    cap.appendArc(from: p(15, 18), to: p(15, 19), radius: s)
    cap.appendArc(withCenter: p(12, 19), radius: 3 * s, startAngle: 0, endAngle: 180, clockwise: false)
    cap.appendArc(from: p(9, 18), to: p(12, 18), radius: s)
    cap.close()
    NSGradient(colors: [NSColor(white: 0.92, alpha: 1), NSColor(white: 0.62, alpha: 1)])!.draw(in: cap, angle: 90)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(output)
