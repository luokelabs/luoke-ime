// 生成输入法菜单栏图标（模板图，仿系统"拼"：圆角方框里一个字）。
//   swift scripts/make-icon.swift <out.pdf>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
var box = CGRect(x: 0, y: 0, width: 16, height: 16)
guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { exit(1) }
ctx.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
NSColor.black.setStroke()
let frame = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 0.75, width: 14.5, height: 14.5), xRadius: 3, yRadius: 3)
frame.lineWidth = 1.1
frame.stroke()
let font = NSFont(name: "PingFangSC-Medium", size: 10.5) ?? NSFont.systemFont(ofSize: 10.5, weight: .medium)
let glyph = NSAttributedString(string: "螺", attributes: [.font: font, .foregroundColor: NSColor.black])
let size = glyph.size()
glyph.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2 + 0.3))
ctx.endPDFPage()
ctx.closePDF()
