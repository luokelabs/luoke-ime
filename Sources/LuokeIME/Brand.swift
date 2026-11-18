import AppKit
import SwiftUI

/// 螺壳应用界面规范 v2 的颜色 token（第 2、11 节，工作台那组）。
/// 浅色、深色都用暖色：浅色墨棕的字、奶白的底，深色深棕的底、奶油色的字。代码里不写死色值，都从这里取。
extension Color {
    static let lkBackground = Color(light: 0xFCFAF7, dark: 0x1F1511)
    static let lkCard = Color(light: 0xFFFFFF, dark: 0x2C1F19)
    static let lkForeground = Color(light: 0x2B1A12, dark: 0xFBF3E8)
    static let lkMuted = Color(light: 0x7A6558, dark: 0xBBA596)
    static let lkMutedBackground = Color(light: 0xF4EEE6, dark: 0x372720)
    static let lkBorder = Color(light: 0xECE4DA, dark: 0x3B2A22)
    static let lkPrimary = Color(light: 0x3A1F14, dark: 0xFDF4E4)
    static let lkPrimaryForeground = Color(light: 0xFDF8F1, dark: 0x2B1A12)
    static let lkBrand = Color(light: 0xE8556B, dark: 0xF2707F)
    static let lkSuccess = Color(light: 0x2F7A4F, dark: 0x5CC98A)
    static let lkSuccessSoft = Color(light: 0xE4F2E8, dark: 0x16301F)
    static let lkWarning = Color(light: 0xA86A12, dark: 0xE8B45A)
    static let lkWarningSoft = Color(light: 0xFBF0D9, dark: 0x33280F)
    static let lkDanger = Color(light: 0xC2412D, dark: 0xF07A66)
    /// 标记（Badge）上的字：浅色下 -soft 底上的 12px 字要压深一档才过 4.5:1，深色照用原色（第 2 节）。成功照用 lkSuccess。
    static let lkWarningText = Color(light: 0x8F590C, dark: 0xE8B45A)

    /// 按窗口的外观（浅色、深色）取两个值。
    init(light: UInt32, dark: UInt32) {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

/// 规范第 6 节的主按钮：primary 底、primary-foreground 字，高 40（large），圆角 10，14/500；每屏只有一个。
/// 不用系统的 borderedProminent：深色下系统按 tint 自己挑字的颜色，近白的底上配了白字。
struct LKPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.lkPrimaryForeground)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Color.lkPrimary.opacity(configuration.isPressed ? 0.85 : 1), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
    }
}

/// 规范第 6 节的小标记（Badge）：高约 20，12/500，圆角 6。
struct LKBadge: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(background, in: .rect(cornerRadius: 6))
    }
}

/// 一行放不下就换行的排法（引导里那串步骤小标签用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].items.isEmpty { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width = r.items.isEmpty ? size.width : r.width + spacing + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
