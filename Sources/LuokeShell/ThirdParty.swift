import CryptoKit
import Foundation

/// 第三方引擎（装在引擎目录里、不是随输入法发布的）的规矩（luokelabs/luoke-ime#6）：
/// - 一律不许联网，也不许 GPU 和数据目录以外的写入位置（要用模型就经主控的任务）；
/// - 用户确认过才启用，确认绑在引擎说明里和权限有关的内容上（`fingerprint`），这些变了要重新确认；只改代码不重问，
///   因为沙盒只放行声明过的。
/// 自带的引擎随输入法签名发布，不受这几条限制。
public enum ThirdParty {
    /// 第三方引擎不能有的声明；都没有时为 nil。
    public static func refusal(_ m: Manifest) -> String? {
        var no: [String] = []
        if m.permissions.network != .none { no.append("联网（network: \(m.permissions.network.rawValue)）") }
        if m.permissions.gpu { no.append("用 GPU") }
        if !m.permissions.write.isEmpty { no.append("写自己数据目录以外的地方（write）") }
        guard !no.isEmpty else { return nil }
        return "螺壳不让第三方引擎" + no.joined(separator: "、") + "。要用模型请经主控的任务（asks 里写 hub），自己的数据写到 LUOKE_IME_DATA"
    }

    /// 引擎说明里和权限、身份有关的内容（name、kind、run、input_keys、permissions、asks、context、app、feedback、forget_all、
    /// hotkey）的指纹：改了名字也要重新确认，免得改成和自带引擎一样的名字冒充。选项（options）、标点表改了不变。读不懂时为 nil。
    public static func fingerprint(engineJSON data: Data) -> String? {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var subset: [String: Any] = [:]
        for k in ["name", "kind", "run", "input_keys", "permissions", "asks", "context", "app", "feedback", "forget_all", "hotkey"] {
            subset[k] = m[k]
        }
        guard let canon = try? JSONSerialization.data(withJSONObject: subset, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: canon).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func fingerprint(engineDir: URL) -> String? {
        (try? Data(contentsOf: engineDir.appendingPathComponent("engine.json"))).flatMap(fingerprint(engineJSON:))
    }

    /// 确认框里列的：启用以后它能做什么、不能做什么。
    public static func describe(_ m: Manifest) -> [String] {
        var out: [String] = []
        switch m.kind {
        case .typing: out.append("能看到你用它打的每一个键（打字引擎都能）")
        case .hotkey: out.append("按住快捷键时由它出字")
        case .personal:
            out.append("代替螺壳自带的个人化组件")
            out.append("能收到你在所有引擎里上屏的字（你允许了保存到本机记忆时才给）")
            out.append("给候选打分、联想时，会拿到光标前的文字（允许记忆、没禁止记录的应用里才给）")
        }
        if m.context > 0 { out.append("读光标前最多 \(m.context) 个字") }
        if m.app { out.append("知道你在哪个应用里打字") }
        if m.feedback { out.append("收到你上屏、删改、忘掉了什么") }
        let p = m.permissions
        if p.microphone { out.append("用麦克风") }
        if p.camera { out.append("用摄像头") }
        if p.screen { out.append("录屏") }
        if p.memory { out.append("读写螺壳的记忆（还要你在输入法设置的「通用」里另外打开记忆记录）") }
        if m.asks.contains(.hub) { out.append("请螺壳用模型帮它算（会把光标前的文字交给螺壳，都在本机）") }
        if m.asks.contains(.personal) { out.append("请个人化组件按你的习惯打分（会把光标前的文字交给它）") }
        out.append("不能联网，只能写它自己的数据目录")
        return out
    }
}
