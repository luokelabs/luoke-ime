import Foundation

// 引擎协议第 1 版的消息（docs/引擎协议.md）。每条消息是一行 JSON。

public let protocolVersion = 1

/// 壳 → 引擎。
public enum ShellMessage: Equatable {
    case hello(options: JSONValue, dataDir: String)
    case query(id: Int, input: String, context: String?, app: String?)
    case committed(Committed)
    case deleted(after: Int, count: Int, followedBy: String)
    case forget(input: String, text: String, context: String?, source: String? = nil)
    /// 用户在菜单里要清掉引擎学到的东西（只发给声明了 `forget_all` 的引擎）。
    case forgetAll
    /// 用户在设置窗口里撤销忘掉某个词（只发给声明了 `forget_all` 的引擎）。
    case unforget(input: String, text: String)
    case arm(id: Int)
    case start(id: Int, context: String?, app: String?)
    case stop(id: Int)
    case cancel(id: Int, reason: CancelReason)
    /// 转给个人化组件的转问：`id` 是壳重新编的号，`from` 是发问的引擎。
    case ask(id: Int, from: String, method: String, params: JSONValue)
    /// 转问的答复，转回发问的引擎；`id` 是它自己发问时的号。
    case reply(Reply)

    public enum CancelReason: String { case esc, key, focus, timeout, short }

    public struct Committed: Equatable {
        public var id: Int
        public var text: String
        public var auto: Bool
        public var context: String?
        public var pieces: [Piece]
        /// 以下只发给个人化组件：哪个引擎出的字，是哪一类上屏，在哪个应用里（声明了 app 时）。
        public var source: String?
        public var kind: Kind?
        public var app: String?

        /// predict：用户选了一个联想。
        public enum Kind: String { case typing, punctuation, hotkey, predict, english }

        public init(id: Int, text: String, auto: Bool, context: String?, pieces: [Piece],
                    source: String? = nil, kind: Kind? = nil, app: String? = nil) {
            self.id = id
            self.text = text
            self.auto = auto
            self.context = context
            self.pieces = pieces
            self.source = source
            self.kind = kind
            self.app = app
        }
    }

    public var json: [String: Any] {
        switch self {
        case let .hello(options, dataDir):
            return ["type": "hello", "protocol": protocolVersion, "options": options.any, "data_dir": dataDir]
        case let .query(id, input, context, app):
            var m: [String: Any] = ["type": "query", "id": id, "input": input]
            m["context"] = context
            m["app"] = app
            return m
        case let .committed(c):
            var m: [String: Any] = ["type": "committed", "id": c.id, "text": c.text, "auto": c.auto]
            if c.kind == nil || c.kind == .typing { m["pieces"] = c.pieces.map(\.json) }
            m["context"] = c.context
            m["source"] = c.source
            m["kind"] = c.kind?.rawValue
            m["app"] = c.app
            return m
        case let .deleted(after, count, followedBy):
            var m: [String: Any] = ["type": "deleted", "after": after, "count": count]
            if !followedBy.isEmpty { m["followed_by"] = followedBy }
            return m
        case let .forget(input, text, context, source):
            var m: [String: Any] = ["type": "forget", "input": input, "text": text]
            m["context"] = context
            m["source"] = source
            return m
        case .forgetAll:
            return ["type": "forget_all"]
        case let .unforget(input, text):
            return ["type": "unforget", "input": input, "text": text]
        case let .arm(id):
            return ["type": "arm", "id": id]
        case let .start(id, context, app):
            var m: [String: Any] = ["type": "start", "id": id]
            m["context"] = context
            m["app"] = app
            return m
        case let .stop(id):
            return ["type": "stop", "id": id]
        case let .cancel(id, reason):
            return ["type": "cancel", "id": id, "reason": reason.rawValue]
        case let .ask(id, from, method, params):
            return ["type": "ask", "id": id, "from": from, "method": method, "params": params.any]
        case let .reply(r):
            return r.json
        }
    }

    /// 一行 JSON（不含换行）。
    public var line: String { JSONLine.encode(json) }
}

/// 已选部分的一段，也是上屏反馈里的一段。
public struct Piece: Equatable {
    public var input: String
    public var text: String
    /// 选的是第几个候选；原始字母时为 nil。
    public var index: Int?
    /// 当时的首选。
    public var top: String?
    /// 以词定字：只取了这个候选的第一个字（`first`）或最后一个字（`last`），`text` 就是那个字；平常是 nil。
    public var char: String?

    public var raw: Bool { index == nil }

    public init(input: String, text: String, index: Int?, top: String?, char: String? = nil) {
        self.input = input
        self.text = text
        self.index = index
        self.top = top
        self.char = char
    }

    public static func raw(_ input: String) -> Piece { Piece(input: input, text: input, index: nil, top: nil) }

    var json: [String: Any] {
        if raw { return ["input": input, "text": text, "raw": true] }
        var m: [String: Any] = ["input": input, "text": text, "index": index!]
        m["top"] = top
        m["char"] = char
        return m
    }
}

public struct Candidate: Equatable {
    public var text: String
    public var consume: Int
    public var note: String?

    public init(text: String, consume: Int, note: String? = nil) {
        self.text = text
        self.consume = consume
        self.note = note
    }
}

public struct Answer: Equatable {
    public var id: Int
    public var display: String?
    public var candidates: [Candidate]
    public var more: Bool
    public var autocommit: Bool

    public init(id: Int, display: String? = nil, candidates: [Candidate], more: Bool = false, autocommit: Bool = false) {
        self.id = id
        self.display = display
        self.candidates = candidates
        self.more = more
        self.autocommit = autocommit
    }
}

/// 转问（docs/引擎协议.md#转问）：引擎经壳向个人化组件或主控提的请求。壳只看 `to` 和声明，不看 `params`。
public struct Ask: Equatable {
    public var id: Int
    public var to: String
    public var method: String
    public var params: JSONValue

    public init(id: Int, to: String, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.to = to
        self.method = method
        self.params = params
    }
}

/// 转问的答复：`result` 和 `error` 恰好有一个。
public struct Reply: Equatable {
    public var id: Int
    public var result: JSONValue?
    public var error: JSONValue?

    public init(id: Int, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: Int, error code: String, message: String) {
        self.id = id
        self.error = .object(["code": .string(code), "message": .string(message)])
    }

    init(id: Int, result: JSONValue?, error: JSONValue?) {
        self.id = id
        self.result = result
        self.error = error
    }

    /// 错误码，比如壳给的 `unavailable`、`not_allowed`、`bad_request`。
    public var errorCode: String? {
        if case let .string(s)? = error?["code"] { return s }
        return nil
    }

    var json: [String: Any] {
        var m: [String: Any] = ["type": "reply", "id": id]
        if let error { m["error"] = error.any } else { m["result"] = (result ?? .null).any }
        return m
    }
}

/// 引擎 → 壳。
public enum EngineMessage: Equatable {
    case answer(Answer)
    /// hint：光标处的提示（比如语音的「整理中…」），没有时壳按自己的规矩提示。
    /// listening：用麦克风的引擎说话筒还没真的开始收音（蓝牙耳机切模式这类），壳显示「准备中…」；不写时算在听。
    case show(id: Int, text: String, hint: String? = nil, listening: Bool? = nil)
    case commit(id: Int, text: String)
    case end(id: Int)
    case ask(Ask)
    /// 个人化组件对一次转问的答复。
    case reply(Reply)
    /// 不认识的类型：按协议忽略。
    case unknown(type: String)

    public var id: Int? {
        switch self {
        case let .answer(a): return a.id
        case let .show(id, _, _, _), let .commit(id, _), let .end(id): return id
        case let .ask(a): return a.id
        case let .reply(r): return r.id
        case .unknown: return nil
        }
    }

    /// 解析一行引擎输出。格式不对时抛出 `ProtocolError`，说明哪里不对。
    public static func parse(_ line: String) throws -> EngineMessage {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let raw = obj as? [String: Any] else {
            throw ProtocolError("不是一个 JSON 对象：\(line.prefix(80))")
        }
        let m = raw.filter { !($0.value is NSNull) } // null 当作没写
        guard let type = m["type"] as? String else { throw ProtocolError("缺少字符串字段 type") }
        func int(_ k: String) throws -> Int {
            guard let n = m[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue == n.doubleValue.rounded() else { throw ProtocolError("\(type) 的 \(k) 必须是整数") }
            return n.intValue
        }
        func string(_ k: String) throws -> String {
            guard let s = m[k] as? String else { throw ProtocolError("\(type) 的 \(k) 必须是字符串") }
            return s
        }
        func bool(_ k: String) throws -> Bool {
            guard let v = m[k] else { return false }
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                throw ProtocolError("\(type) 的 \(k) 必须是 true 或 false")
            }
            return n.boolValue
        }
        switch type {
        case "answer":
            guard let list = m["candidates"] as? [Any] else { throw ProtocolError("answer 的 candidates 必须是数组") }
            var cands: [Candidate] = []
            for (i, item) in list.enumerated() {
                guard var c = item as? [String: Any] else { throw ProtocolError("candidates[\(i)] 必须是对象") }
                c = c.filter { !($0.value is NSNull) }
                guard let text = c["text"] as? String else { throw ProtocolError("candidates[\(i)].text 必须是字符串") }
                guard let n = c["consume"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue == n.doubleValue.rounded() else {
                    throw ProtocolError("candidates[\(i)].consume 必须是整数")
                }
                if c["note"] != nil, !(c["note"] is String) { throw ProtocolError("candidates[\(i)].note 必须是字符串") }
                cands.append(Candidate(text: text, consume: n.intValue, note: c["note"] as? String))
            }
            if m["display"] != nil, !(m["display"] is String) { throw ProtocolError("answer 的 display 必须是字符串") }
            return .answer(Answer(id: try int("id"), display: m["display"] as? String, candidates: cands,
                                  more: try bool("more"), autocommit: try bool("autocommit")))
        case "show":
            if m["hint"] != nil, !(m["hint"] is String) { throw ProtocolError("show 的 hint 必须是字符串") }
            if m["listening"] != nil, !(m["listening"] is Bool) { throw ProtocolError("show 的 listening 必须是 true 或 false") }
            return .show(id: try int("id"), text: try string("text"), hint: m["hint"] as? String, listening: m["listening"] as? Bool)
        case "commit": return .commit(id: try int("id"), text: try string("text"))
        case "end": return .end(id: try int("id"))
        case "ask":
            let params = m["params"] ?? [String: Any]()
            guard params is [String: Any] else { throw ProtocolError("ask 的 params 必须是对象") }
            return .ask(Ask(id: try int("id"), to: try string("to"), method: try string("method"), params: JSONValue(params)))
        case "reply":
            let hasResult = raw.keys.contains("result"), hasError = m["error"] != nil
            guard hasResult != hasError else { throw ProtocolError("reply 要有 result 或 error 之一，且只能有一个") }
            if hasError {
                guard let e = m["error"] as? [String: Any], e["code"] is String else {
                    throw ProtocolError("reply 的 error 必须是带字符串 code 的对象")
                }
                return .reply(Reply(id: try int("id"), result: nil, error: JSONValue(e)))
            }
            return .reply(Reply(id: try int("id"), result: JSONValue(raw["result"]), error: nil))
        default: return .unknown(type: type)
        }
    }
}

public struct ProtocolError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

enum JSONLine {
    static func encode(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// 任意 JSON 值，用于选项值这类壳不关心结构的数据。
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(d): return d == d.rounded() && abs(d) < 1e15 ? Int(d) as Any : d as Any
        case let .string(s): return s
        case let .array(a): return a.map(\.any)
        case let .object(o): return o.mapValues(\.any)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
}
