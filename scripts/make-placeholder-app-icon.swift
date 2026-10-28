// 占位的 app 图标（等 luoke-community 的统一 logo，到时直接换掉 Resources/App/AppIcon.png）：圆角方块里一个"螺"。
//   swift scripts/make-placeholder-app-icon.swift Resources/App/AppIcon.png
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let side = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// macOS 图标的网格：内容区 824×824，圆角约 185
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.45, alpha: 1),
           ending: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.27, alpha: 1))?.draw(in: shape, angle: -90)
let font = NSFont(name: "PingFangSC-Semibold", size: 520) ?? NSFont.systemFont(ofSize: 520, weight: .semibold)
let glyph = NSAttributedString(string: "螺", attributes: [.font: font, .foregroundColor: NSColor.white])
let size = glyph.size()
glyph.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 20))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: out)
