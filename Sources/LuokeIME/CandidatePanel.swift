import AppKit
import LuokeShell

/// 候选窗：壳自己画，外观仿系统简体拼音——毛玻璃底、数字编号、高亮用系统强调色、跟随深浅色。
/// 引擎唯一能影响外观的是候选后面的注释（灰色小字）。
/// 先快后好的两个轻提示：候选标了 more（引擎还在算）时末尾有个慢慢浮现、缓缓呼吸的 ✦；
/// 补发换掉了首选时，新的首选淡入，看起来是有意的更新而不是闪了一下。引擎可以在它改过的候选的注释里写 ✦，
/// 这样 ✦ 始终是同一个意思：呼吸时是还在算，停在某个候选后面是那个候选是它改的。
final class CandidatePanel {
    static let shared = CandidatePanel()

    private let window: NSPanel
    private let effect = NSVisualEffectView()
    private let content = CandidateView()
    private let badge: NSPanel
    private let badgeLabel = NSTextField(labelWithString: "")
    private var badgeHide: DispatchWorkItem?
    /// 联想提示：刚上屏、有联想时光标旁淡淡的"⇥ 联想"。
    private let hint: NSPanel
    private let hintLabel = NSTextField(labelWithString: "⇥ 联想")

    private init() {
        window = Self.makePanel()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        window.contentView = effect

        badge = Self.makePanel()
        let badgeEffect = NSVisualEffectView()
        badgeEffect.material = .menu
        badgeEffect.state = .active
        badgeEffect.wantsLayer = true
        badgeEffect.layer?.cornerRadius = 6
        badgeEffect.layer?.masksToBounds = true
        badgeLabel.font = .systemFont(ofSize: 15, weight: .medium)
        badgeLabel.alignment = .center
        badgeEffect.addSubview(badgeLabel)
        badge.contentView = badgeEffect

        hint = Self.makePanel()
        hint.hasShadow = false
        hint.alphaValue = 0.85
        let hintEffect = NSVisualEffectView()
        hintEffect.material = .menu
        hintEffect.state = .active
        hintEffect.wantsLayer = true
        hintEffect.layer?.cornerRadius = 5
        hintEffect.layer?.masksToBounds = true
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintEffect.addSubview(hintLabel)
        hint.contentView = hintEffect
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        return p
    }

    /// 按状态机给出的画面更新；没有可画的就隐藏。`markedInPanel` 用于"显示串不内嵌"的应用。
    func show(_ v: SessionView, markedInPanel: String?, near caret: NSRect, fontSize: Double, orientation: ShellSettings.Orientation) {
        let marked = markedInPanel.flatMap { $0.isEmpty ? nil : $0 }
        guard !v.candidates.isEmpty || v.notice != nil || marked != nil else { hide(); return }
        content.model = .init(candidates: v.candidates, highlighted: v.highlighted, page: v.page, pageCount: v.pageCount,
                              notice: v.notice, marked: marked, fontSize: CGFloat(fontSize) * (v.predictHint ? 0.9 : 1),
                              vertical: orientation == .vertical, pending: v.pending, dimmed: v.predictHint, voice: v.voice,
                              level: v.voiceLevel)
        if v.topReplaced, window.isVisible { content.fadeInTop() }
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)
        window.setFrame(NSRect(origin: origin(for: size, near: caret), size: size), display: true)
        content.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
        hideHint()
    }

    /// 切换中英时在光标旁闪一下。
    func flash(_ text: String, near caret: NSRect) {
        badgeLabel.stringValue = text
        let size = NSSize(width: 30, height: 26)
        badgeLabel.frame = NSRect(x: 0, y: 3, width: size.width, height: 20)
        badge.setFrame(NSRect(origin: origin(for: size, near: caret), size: size), display: true)
        badge.orderFrontRegardless()
        badgeHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.badge.orderOut(nil) }
        badgeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// 联想提示：亮着的时候 Tab 打开联想（状态机决定什么时候亮、什么时候收起）。
    func showHint(near caret: NSRect) {
        let size = NSSize(width: hintLabel.intrinsicContentSize.width + 14, height: 20)
        hintLabel.frame = NSRect(x: 0, y: 2, width: size.width, height: 16)
        hint.setFrame(NSRect(origin: origin(for: size, near: caret), size: size), display: true)
        if !hint.isVisible { hint.orderFrontRegardless() }
    }

    func hideHint() {
        if hint.isVisible { hint.orderOut(nil) }
    }

    /// 放在光标下方；下面放不下就放到上方；左右不出屏幕。
    private func origin(for size: NSSize, near caret: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = caret.minX - CandidateView.padding
        var y = caret.minY - size.height - 4
        if y < area.minY { y = caret.maxY + 4 }
        x = min(max(x, area.minX), area.maxX - size.width)
        return NSPoint(x: x, y: y)
    }

    /// 离屏把候选窗画成 PNG，用于检查外观。
    static func snapshot(to url: URL, dark: Bool, pending: Bool = false, predict: Bool = false, voice: SessionView.Voice? = nil,
                         level: Double? = nil) -> Bool {
        let view = CandidateView()
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.model = .init(candidates: [Candidate(text: "我不知道", consume: 6), Candidate(text: "我", consume: 2),
                                        Candidate(text: "窝", consume: 2, note: "wō"), Candidate(text: "握", consume: 2),
                                        Candidate(text: "沃", consume: 2)],
                           highlighted: 0, page: 0, pageCount: 3, notice: nil, marked: nil, fontSize: 16, vertical: false, pending: pending)
        if predict { // 还没激活的联想（检查它别比打字时的候选窗大）
            view.model = .init(candidates: [Candidate(text: "一个", consume: 0), Candidate(text: "一个诺言", consume: 0),
                                            Candidate(text: "什么", consume: 0)],
                               highlighted: nil, page: 0, pageCount: 1, notice: nil, marked: nil, fontSize: 16 * 0.9, vertical: false,
                               pending: false, dimmed: true)
        }
        if let voice { // 语音：只有提示行（字在输入框里）
            view.model = .init(notice: voice == .preparing ? "准备中…" : voice == .listening ? "录音中" : "整理中…", fontSize: 16, voice: voice,
                               level: level)
        }
        let size = view.fittingSize
        let bg = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size.width + 40, height: size.height + 40)))
        bg.wantsLayer = true
        bg.appearance = view.appearance
        bg.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        let card = NSView(frame: NSRect(x: 20, y: 20, width: size.width, height: size.height))
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = (dark ? NSColor(white: 0.22, alpha: 1) : NSColor.white).cgColor
        view.frame = NSRect(origin: .zero, size: size)
        card.addSubview(view)
        bg.addSubview(card)
        guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { return false }
        bg.cacheDisplay(in: bg.bounds, to: rep)
        if pending, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            // cacheDisplay 不画独立的图层：把 ✦ 按它的位置补画上去（取呼吸前的不透明度）
            view.mark.removeAllAnimations()
            NSGraphicsContext.current = ctx
            let f = view.convert(view.mark.frame, to: bg)
            NSAttributedString(string: CandidateView.markGlyph, attributes: [.font: view.markFont,
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.55)]).draw(at: NSPoint(x: f.minX, y: f.minY))
            NSGraphicsContext.current = nil
        }
        if voice != nil, let ctx = NSGraphicsContext(bitmapImageRep: rep) { // 语音的点、音量条也是独立图层，补画上去
            NSGraphicsContext.current = ctx
            (voice == .preparing ? NSColor.systemYellow : voice == .listening ? NSColor.systemRed : NSColor.secondaryLabelColor).setFill()
            for l in [view.voiceDot] + view.voiceBars where !l.isHidden {
                let f = view.convert(l.frame, to: bg)
                let r = NSRect(x: f.minX, y: bg.bounds.height - f.maxY, width: f.width, height: f.height)
                NSBezierPath(roundedRect: r, xRadius: l.cornerRadius, yRadius: l.cornerRadius).fill()
            }
            NSGraphicsContext.current = nil
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

/// 候选窗里的内容：提示行、（不内嵌时的）显示串、候选。
final class CandidateView: NSView {
    struct Model {
        var candidates: [Candidate] = []
        var highlighted: Int?
        var page = 0
        var pageCount = 0
        var notice: String?
        var marked: String?
        var fontSize: CGFloat = 16
        var vertical = false
        var pending = false
        /// 联想还没激活：候选淡一点，不放编号（数字这时选不了），第一个前面放 ⇥（按 Tab 才能选）
        var dimmed = false
        /// 语音的状态：提示行前面画一个会动的点（在听是红的、一跳一跳；在识别、整理是灰的、慢慢呼吸），提示字也大一点、深一点
        var voice: SessionView.Voice?
        /// 在听时引擎报的音量（0–1）：有就把红点换成三根跟着声音动的音量条，说得太小声一眼看得出来
        var level: Double?
    }

    static let padding: CGFloat = 6
    var model = Model() {
        didSet {
            if model.pending != oldValue.pending { updateDot() }
            if model.voice != oldValue.voice || (model.level == nil) != (oldValue.level == nil) { updateVoiceDot() }
            if model.level != oldValue.level { layoutBars(animated: true) }
        }
    }

    override var isFlipped: Bool { true }

    // MARK: - 还在算的 ✦

    fileprivate let mark = CATextLayer()
    fileprivate static let markGlyph = "✦"
    fileprivate var markFont: NSFont { .systemFont(ofSize: model.fontSize * 0.72) }
    private var markSize: NSSize { NSAttributedString(string: Self.markGlyph, attributes: [.font: markFont]).size() }
    private var dotSlot: CGFloat { model.pending ? ceil(markSize.width) + 8 : 0 }

    // MARK: - 语音的点

    fileprivate let voiceDot = CALayer()
    private var voiceDotSize: CGFloat { round(model.fontSize * 0.55) }
    /// 提示行前面给点留的宽度（不是语音时为 0）。
    private var voiceSlot: CGFloat { model.voice == nil ? 0 : voiceDotSize + 7 }

    /// 音量条：三根竖条，中间那根最高，跟着引擎报的音量（0.1 秒一次）伸缩。
    fileprivate let voiceBars = (0..<3).map { _ in CALayer() }
    private var showsBars: Bool { model.voice == .listening && model.level != nil }

    private func layoutBars(animated: Bool) {
        guard showsBars else { return }
        let d = voiceDotSize, level = model.level ?? 0
        let w = max(2, round(d * 0.24)), gap = max(1.5, round(w * 0.6))
        let maxH = round(d * 1.6), minH = w
        let x0 = voiceDot.frame.midX - (3 * w + 2 * gap) / 2
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.09) } else { CATransaction.setDisableActions(true) }
        for (i, bar) in voiceBars.enumerated() {
            let h = round(minH + (maxH - minH) * min(1, level * (i == 1 ? 1 : 0.65)))
            bar.frame = NSRect(x: x0 + CGFloat(i) * (w + gap), y: voiceDot.frame.midY - h / 2, width: w, height: h)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
    }

    private func updateVoiceDot() {
        voiceDot.removeAllAnimations()
        voiceDot.isHidden = model.voice == nil || showsBars
        for bar in voiceBars {
            bar.isHidden = !showsBars
            bar.backgroundColor = NSColor.systemRed.cgColor
        }
        if showsBars { layoutBars(animated: false) }
        guard let v = model.voice, !showsBars else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        switch v {
        case .preparing: // 话筒还没开始收音：黄点，轻轻闪，等它变红再说
            voiceDot.backgroundColor = NSColor.systemYellow.cgColor
            pulse.fromValue = 1; pulse.toValue = 0.6
            scale.fromValue = 1; scale.toValue = 1
            pulse.duration = 0.35; scale.duration = 0.35
        case .listening: // 在听：红点一跳一跳，像录音灯
            voiceDot.backgroundColor = NSColor.systemRed.cgColor
            pulse.fromValue = 1; pulse.toValue = 0.35
            scale.fromValue = 1; scale.toValue = 0.75
            pulse.duration = 0.55; scale.duration = 0.55
        case .working: // 在识别、整理：灰点慢慢呼吸
            voiceDot.backgroundColor = NSColor.secondaryLabelColor.cgColor
            pulse.fromValue = 0.8; pulse.toValue = 0.2
            scale.fromValue = 1; scale.toValue = 1
            pulse.duration = 0.8; scale.duration = 0.8
        }
        let group = CAAnimationGroup()
        group.animations = [pulse, scale]
        group.duration = pulse.duration
        group.autoreverses = true
        group.repeatCount = .infinity
        voiceDot.add(group, forKey: "voice")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        mark.string = Self.markGlyph
        mark.alignmentMode = .center
        mark.isHidden = true
        layer?.addSublayer(mark)
        voiceDot.isHidden = true
        layer?.addSublayer(voiceDot)
        for bar in voiceBars {
            bar.isHidden = true
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 慢慢浮现（等得久才看得出来，补发很快就到时几乎看不见），然后缓缓呼吸。
    private func updateDot() {
        mark.removeAllAnimations()
        mark.isHidden = !model.pending
        guard model.pending else { return }
        mark.opacity = 0.55
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 0.55
        appear.duration = 0.35
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 0.2
        breathe.beginTime = 0.35
        breathe.duration = 0.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        let group = CAAnimationGroup()
        group.animations = [appear, breathe]
        group.duration = .infinity
        mark.add(group, forKey: "pending")
    }

    // MARK: - 首选淡入

    private var fadeStart: CFTimeInterval?
    private var fadeTimer: Timer?
    private let fadeDuration: CFTimeInterval = 0.12

    func fadeInTop() {
        fadeStart = CACurrentMediaTime()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.needsDisplay = true
            if self.topAlpha >= 1 { t.invalidate(); self.fadeStart = nil }
        }
    }

    private var topAlpha: CGFloat {
        guard let s = fadeStart else { return 1 }
        return min(1, 0.2 + 0.8 * CGFloat((CACurrentMediaTime() - s) / fadeDuration))
    }

    private struct Item {
        var number: NSAttributedString
        var text: NSAttributedString
        var note: NSAttributedString?
        var width: CGFloat
    }

    private var textFont: NSFont { .systemFont(ofSize: model.fontSize) }
    private var smallFont: NSFont { .monospacedDigitSystemFont(ofSize: model.fontSize * 0.72, weight: .regular) }
    /// 候选编号：比注释大一点、粗一点，远程桌面等低清晰度下也看得清
    private var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: model.fontSize * 0.82, weight: .medium) }
    private var rowHeight: CGFloat { ceil(model.fontSize * 1.6) }
    private let gap: CGFloat = 4

    private func items(highlighted: Int?) -> [Item] {
        model.candidates.enumerated().map { i, c in
            let on = i == highlighted
            let label = model.dimmed ? (i == 0 ? "⇥" : "") : "\(i + 1)"
            let number = NSAttributedString(string: label, attributes: [.font: numberFont, .foregroundColor: on ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor])
            let text = NSAttributedString(string: c.text, attributes: [.font: textFont, .foregroundColor: on ? NSColor.white : NSColor.labelColor])
            let note = c.note.map { NSAttributedString(string: $0, attributes: [.font: smallFont, .foregroundColor: on ? NSColor.white.withAlphaComponent(0.75) : NSColor.tertiaryLabelColor]) }
            let w = 6 + number.size().width + (label.isEmpty ? 0 : 4) + text.size().width + (note.map { 3 + $0.size().width } ?? 0) + 6
            return Item(number: number, text: text, note: note, width: ceil(w))
        }
    }

    private var lines: [NSAttributedString] {
        var out: [NSAttributedString] = []
        if let n = model.notice {
            let voice = model.voice != nil // 语音的提示大一点、深一点，一眼看得出在说话
            out.append(NSAttributedString(string: n, attributes: [.font: NSFont.systemFont(ofSize: model.fontSize * (voice ? 0.9 : 0.8), weight: voice ? .medium : .regular),
                                                                 .foregroundColor: voice ? NSColor.labelColor : NSColor.secondaryLabelColor]))
        }
        if let m = model.marked {
            out.append(NSAttributedString(string: m, attributes: [.font: textFont, .foregroundColor: NSColor.labelColor,
                                                                  .underlineStyle: NSUnderlineStyle.single.rawValue]))
        }
        return out
    }

    private var pageLabel: NSAttributedString? {
        guard model.pageCount > 1 else { return nil }
        return NSAttributedString(string: "\(model.page + 1)/\(model.pageCount)", attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    override var fittingSize: NSSize {
        let p = Self.padding
        let its = items(highlighted: model.highlighted)
        var width: CGFloat = 0
        var height = p
        for (i, l) in lines.enumerated() {
            width = max(width, ceil(l.size().width) + 6 + (i == 0 && model.notice != nil ? voiceSlot : 0))
            height += rowHeight
        }
        if !its.isEmpty {
            if model.vertical {
                width = max(width, its.map(\.width).max() ?? 0)
                height += CGFloat(its.count) * rowHeight
                if pageLabel != nil { height += rowHeight * 0.8 }
            } else {
                let row = its.map(\.width).reduce(0, +) + gap * CGFloat(its.count - 1) + (pageLabel.map { 8 + ceil($0.size().width) } ?? 0) + dotSlot
                width = max(width, row)
                height += rowHeight
            }
        }
        return NSSize(width: max(width + p * 2, 40), height: height + p)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Self.padding
        var y = p
        for (i, l) in lines.enumerated() {
            let indent = i == 0 && model.notice != nil ? voiceSlot : 0 // 语音的点画在提示行前面
            l.draw(at: NSPoint(x: p + 3 + indent, y: y + (rowHeight - l.size().height) / 2))
            y += rowHeight
        }
        let its = items(highlighted: model.highlighted)
        let dim = NSGraphicsContext.current?.cgContext
        if model.dimmed { dim?.saveGState(); dim?.setAlpha(0.5) }
        defer { if model.dimmed { dim?.restoreGState() } }
        var x = p
        for (i, item) in its.enumerated() {
            let rect = NSRect(x: x, y: y, width: model.vertical ? bounds.width - p * 2 : item.width, height: rowHeight)
            if i == model.highlighted {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            var cx = rect.minX + 6
            let mid = rect.midY
            let ctx = NSGraphicsContext.current?.cgContext
            if i == 0 { ctx?.saveGState(); ctx?.setAlpha(topAlpha * (model.dimmed ? 0.5 : 1)) } // setAlpha 是设，不是乘：淡的时候照样淡
            item.number.draw(at: NSPoint(x: cx, y: mid - item.number.size().height / 2 + 1))
            if item.number.length > 0 { cx += item.number.size().width + 4 }
            item.text.draw(at: NSPoint(x: cx, y: mid - item.text.size().height / 2))
            cx += item.text.size().width + 3
            item.note?.draw(at: NSPoint(x: cx, y: mid - (item.note?.size().height ?? 0) / 2 + 1))
            if i == 0 { ctx?.restoreGState() }
            if model.vertical { y += rowHeight } else { x += item.width + gap }
        }
        var end = x
        if let pl = pageLabel {
            let at = model.vertical ? NSPoint(x: bounds.width - p - pl.size().width - 4, y: y)
                                    : NSPoint(x: x + 4, y: y + (rowHeight - pl.size().height) / 2)
            pl.draw(at: at)
            end = x + 8 + ceil(pl.size().width)
        }
        // ✦：横排在最后面，竖排在第一行右边
        let m = markSize
        let firstMid = p + CGFloat(lines.count) * rowHeight + rowHeight / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 位置跟着候选走，不要隐式动画
        mark.frame = model.vertical
            ? NSRect(x: bounds.width - p - ceil(m.width) - 4, y: firstMid - m.height / 2, width: ceil(m.width), height: ceil(m.height))
            : NSRect(x: end + 4, y: firstMid - m.height / 2, width: ceil(m.width), height: ceil(m.height))
        mark.font = markFont
        mark.fontSize = markFont.pointSize
        mark.foregroundColor = NSColor.secondaryLabelColor.cgColor
        mark.contentsScale = window?.backingScaleFactor ?? 2
        let d = voiceDotSize
        voiceDot.frame = NSRect(x: p + 4, y: p + (rowHeight - d) / 2, width: d, height: d)
        voiceDot.cornerRadius = d / 2
        CATransaction.commit()
        layoutBars(animated: false)
    }
}
