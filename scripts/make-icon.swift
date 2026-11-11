// 生成输入法菜单栏图标（模板图，和系统的「双」「A」「あ」一样：22×16 的实心圆角长方形，字镂空）。
//   swift scripts/make-icon.swift <out.pdf>
// 镂空：从圆角长方形的路径里减掉字的轮廓（PDF 里不能用「清除」混合；字的笔画互相重叠，奇偶填充会把重叠处填回去）。
import AppKit
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let W: CGFloat = 22, H: CGFloat = 16
var box = CGRect(x: 0, y: 0, width: W, height: H)
guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { exit(1) }
ctx.beginPDFPage(nil)
var path = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 11.5, nil)
var ch: [UniChar] = Array("螺".utf16)
var glyph = CGGlyph(0)
CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
if let g = CTFontCreatePathForGlyph(font, glyph, nil) {
    let b = g.boundingBoxOfPath // 按字形的实际边界居中，不按字体的行高
    var t = CGAffineTransform(translationX: (W - b.width) / 2 - b.minX, y: (H - b.height) / 2 - b.minY)
    if let placed = g.copy(using: &t) { path = path.subtracting(placed) }
}
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.endPDFPage()
ctx.closePDF()
