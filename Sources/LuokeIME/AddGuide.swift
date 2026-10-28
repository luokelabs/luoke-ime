import AppKit
import Carbon
import SwiftUI

/// 添加输入源的引导窗口：用户自己打开了 LuokeIME.app（Finder 里双击、`open`），螺壳却还没被添加时弹出来，
/// 一步步带着在系统设置里加好；每秒看一次加好了没有，加好了就换成"可以用了"。
/// 系统只拉起已经添加的输入法，所以输入法自己能弹这个窗口的只有这一种情况；走主控安装的，引导在主控的首次运行里
/// （文字和螺壳的完成页一致）。窗口开着时进程照旧是输入法服务：用户加好以后系统直接用它。
final class AddGuide: NSObject, NSWindowDelegate {
    static let shared = AddGuide()
    /// 后起的那份拿不到单实例锁时发给在跑的那份：用户又打开了一次，没添加就弹引导。
    static let showRequest = Notification.Name("ai.luoke.inputmethod.Luoke.showAddGuide")

    final class Model: ObservableObject {
        @Published var added = false
    }

    let model = Model()
    private var window: NSWindow?
    var isOpen: Bool { window?.isVisible == true }
    private var timer: Timer?

    /// 还没添加就弹出来；已经添加的什么都不做。
    func showIfNeeded() {
        guard !EnabledWatch.consented() else { return }
        if window?.isVisible == true { window?.orderFrontRegardless(); return }
        // macOS 26 起只注册（让螺壳出现在"编辑… → +"的列表里），不请求启用：请求启用的确认点了也不生效
        if !InputSource.sources().contains(where: { InputSource.identifier($0) == InputSource.modeID }) {
            TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        }
        let w = window ?? makeWindow()
        window = w
        SettingsWindow.allowFront()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        model.added = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.model.added, EnabledWatch.consented() else { return }
            self.model.added = true
            SettingsWindow.allowFront()
            self.window?.orderFrontRegardless()
        }
    }

    func handleReopen() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(reopen(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
    }

    @objc private func reopen(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { showIfNeeded() }

    private func makeWindow() -> NSWindow {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470), styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.becomesKeyOnlyIfNeeded = false
        w.hidesOnDeactivate = false
        w.title = "添加螺壳输入法"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: AddGuideView(model: model, close: { [weak w] in w?.close() }))
        w.delegate = self
        w.center()
        return w
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if !SettingsWindow.shared.isOpen { NSApp.setActivationPolicy(.prohibited) }
    }

    /// 离屏画成图片（检查外观用：LuokeIME --render-guide <out.png> [added] [dark]）。
    static func snapshot(to url: URL, added: Bool, dark: Bool) -> Bool {
        let model = Model()
        model.added = added
        let view = NSHostingView(rootView: AddGuideView(model: model, close: {}))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 470)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

struct AddGuideView: View {
    @ObservedObject var model: AddGuide.Model
    let close: () -> Void

    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
    /// 和主控完成页里输入法卡片的步骤一致（luoke-brand ui/screenshots/install-4.png，luokelabs/luoke-ime#14）
    static let steps = ["打开键盘设置", "输入源 · 编辑…", "左下角 +", "简体中文", "螺壳", "添加"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                header
                card
                hint
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            Spacer(minLength: 0)
            Divider().overlay(Color.lkBorder)
            footer.padding(.horizontal, 32).padding(.vertical, 14)
        }
        .frame(width: 520, height: 470)
        .background(Color.lkBackground)
        .foregroundStyle(Color.lkForeground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.added ? "加好了，螺壳可以用了" : "还差一步：把螺壳添加到系统")
                    .font(.system(size: 20, weight: .semibold)).kerning(-0.2)
                Text(model.added ? "以后在菜单栏的输入法菜单里选「螺壳」就能用。" : "macOS 要你自己在系统设置里加一次，以后换新版不用再加。")
                    .font(.system(size: 13)).foregroundStyle(Color.lkMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(.system(size: 14)).foregroundStyle(Color.lkMuted)
                Text("照这几步添加").font(.system(size: 14, weight: .medium))
                Spacer()
                if model.added {
                    LKBadge(text: "已添加", foreground: .lkSuccess, background: .lkSuccessSoft)
                } else {
                    LKBadge(text: "待添加", foreground: .lkWarning, background: .lkWarningSoft)
                }
            }
            FlowLayout(spacing: 6, lineSpacing: 8) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                    if i > 0 { Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Color.lkMuted) }
                    Text(step).font(.system(size: 13))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.lkMutedBackground, in: .rect(cornerRadius: 6))
                }
            }
            Text("英文系统里是 Chinese, Simplified 和 Luoke 螺壳。列表里没有螺壳：先完全退出系统设置（⌘Q）再打开。")
                .font(.system(size: 12)).foregroundStyle(Color.lkMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if model.added {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.lkSuccess)
                    Text("已添加。切过去以后，在任意输入框里打 nihao 试试。").font(.system(size: 13)).foregroundStyle(Color.lkMuted)
                } else {
                    ProgressView().controlSize(.mini)
                    Text("添加好了这里会自动更新").font(.system(size: 13)).foregroundStyle(Color.lkMuted)
                }
            }
        }
        .padding(16)
        .background(Color.lkCard, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.lkBorder, lineWidth: 1))
    }

    /// 规范第 6 节的提示块：muted 底，圆角 10，13px，左侧一个图标。
    private var hint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(Color.lkMuted).padding(.top, 1)
            Text("系统可能会提醒「输入法能看到你输入的内容」，所有输入法都有这条。螺壳输入法不联网：你打的字在这台 Mac 上处理，默认记进本机的螺壳记忆，不交给能读到内容的云服务；不想记，可以在设置的「通用」里关掉「记录输入内容到记忆」。")
                .font(.system(size: 12)).foregroundStyle(Color.lkMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.lkMutedBackground, in: .rect(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Button(model.added ? "完成" : "以后再说", action: close).buttonStyle(.borderless).controlSize(.large)
                .foregroundStyle(Color.lkMuted)
            Spacer()
            if model.added {
                Button("切换到螺壳") {
                    _ = InputSource.select(InputSource.modeID)
                    close()
                }
                .buttonStyle(LKPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button { NSWorkspace.shared.open(Self.keyboardSettings) } label: {
                    HStack(spacing: 8) { Text("打开键盘设置"); Image(systemName: "arrow.up.right.square").font(.system(size: 14)) }
                }
                .buttonStyle(LKPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }
}
