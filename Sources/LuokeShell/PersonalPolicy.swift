/// 什么能交给个人化组件、打字引擎能不能学：一张表，壳的会话、转问、开发模式的记录都照它（顶层 ADR 0013；
/// 原来散在 Session、转问、联想、沙盒好几处，是一处处补出来的）。
///
/// 本机组件之间不为隐私设限；保留的都是安全上的：安全输入时什么都不给，用户自己设的"禁止记录""暂停"照办，
/// 第三方的个人化组件要用户另外同意才给。读写记忆文件本身由沙盒按 `enabled` 放行，不在这张表里按键算。
public enum PersonalPolicy {
    public struct Inputs: Equatable {
        /// 个人化组件是第三方的（不是随输入法发布的）。
        public var thirdParty: Bool
        /// 安全输入（密码框等），或者这一段组字里碰到过安全输入。
        public var secureInput: Bool
        /// 用户在这里不让记：这个应用设了"禁止记录"，或者暂停了所有记录。
        public var userStopped: Bool
        /// 记忆记录开着：自带的组件默认开、用户关了才是 false；第三方的要用户另外同意才是 true。
        public var enabled: Bool

        public init(thirdParty: Bool, secureInput: Bool, userStopped: Bool, enabled: Bool) {
            self.thirdParty = thirdParty
            self.secureInput = secureInput
            self.userStopped = userStopped
            self.enabled = enabled
        }
    }

    public struct Decision: Equatable {
        /// 上屏、删改、忘掉转给个人化组件（它写进记忆）。
        public var forwardEvents: Bool
        /// 打字引擎收反馈（它自己学改选过的词）。
        public var typingFeedback: Bool
        /// 引擎的转问（打分）交给个人化组件。
        public var relayAsks: Bool
        /// 壳上屏后问个人化组件联想。
        public var predict: Bool
        /// 开发模式的输入记录照写。
        public var devRecording: Bool

        public static let none = Decision(forwardEvents: false, typingFeedback: false, relayAsks: false, predict: false, devRecording: false)
    }

    public static func decide(_ i: Inputs) -> Decision {
        // 安全输入：什么都不给、不学、不记
        if i.secureInput { return .none }
        let recordable = !i.userStopped
        // 自带的组件不存转问和联想请求的内容：打分、联想照常给；第三方的只在能记、用户同意了时给
        let reachable = i.thirdParty ? recordable && i.enabled : true
        return Decision(forwardEvents: recordable && i.enabled, typingFeedback: recordable, relayAsks: reachable, predict: reachable,
                        devRecording: recordable)
    }
}
