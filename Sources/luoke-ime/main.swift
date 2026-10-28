import Foundation
import LuokeShell

let usage = """
用法：
  luoke-ime try <引擎文件夹> [选项]           在终端里像真的输入法一样打字
      --keys <按键脚本>                       不进交互界面，按脚本打字并逐键打印结果（给 agent 用）
      --context <文字>                        输入框里已有的文字（前文）
      --app <bundle id>                       假装当前应用是它
      --hotkey <引擎文件夹>                   同时装上一个快捷键引擎（Ctrl-R 触发）
      --personal <文件夹>                     同时装上一个个人化组件：上屏转给它，引擎可以转问它（记忆用临时的一份）
      --hub <socket>                          个人化组件转问主控时连这个主控（不给就不接主控，不连装好的那个）
      --data <文件夹>                         引擎的数据目录放这里（缺省是临时目录里固定的一份，不碰 ~/.luoke/ime）
      --auto-space                            中英文之间自动加空格
      --no-sandbox                            不用沙盒（只用于排查问题）
      --record                                打开开发模式，记录到数据目录旁的 records/<引擎>/
  luoke-ime check <引擎文件夹> [--no-sandbox] [--json]
                                              自动检查引擎，输出报告；有问题时退出码为 1
  luoke-ime replay <输入记录> [--engine <引擎文件夹>] [--fast] [--no-sandbox]
                                              把一段输入记录（try --record 或开发模式记下的）重放给引擎，
                                              逐键打印，并对比每次询问的首选和当时是否一样；--fast 不按原来的节奏
  luoke-ime list                              列出 ~/.luoke/ime/engines 里的引擎

按键脚本：普通字符照打；特殊键写在花括号里：
  {space} {enter} {bs} {esc} {tab} {left} {right} {up} {down} {pgup} {pgdn}
  {shift}（单按 Shift，切中英） {forget}（Shift+⌫） {hotkey}（按一下快捷键引擎的键）
  {wait:200}（等 200 毫秒） {cmd+a}（组合键，放行）  {{ 表示字面的 {
"""

// 这里起的引擎被沙盒拦下时，正在运行的输入法不能认成它自己的同名引擎
EngineConnection.sandboxTagPrefix = "cli.\(getpid())."

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(2)
}
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

switch command {
case "try":
    var o = TryOptions()
    o.keys = option("--keys")
    o.context = option("--context") ?? ""
    o.app = option("--app")
    o.hotkeyDir = option("--hotkey").map { URL(fileURLWithPath: $0) }
    o.personalDir = option("--personal").map { URL(fileURLWithPath: $0) }
    o.hubSocket = option("--hub")
    o.dataRoot = option("--data").map { URL(fileURLWithPath: $0) }
    o.autoSpace = flag("--auto-space")
    o.sandboxed = !flag("--no-sandbox")
    o.record = flag("--record")
    guard let dir = args.first else { fail("缺少引擎文件夹\n\n" + usage) }
    o.engineDir = URL(fileURLWithPath: dir)
    exit(runTry(o))
case "check":
    let sandboxed = !flag("--no-sandbox")
    let json = flag("--json")
    guard let dir = args.first else { fail("缺少引擎文件夹\n\n" + usage) }
    exit(runCheck(engineDir: URL(fileURLWithPath: dir), sandboxed: sandboxed, json: json))
case "replay":
    let engine = option("--engine").map { URL(fileURLWithPath: $0) }
    let fast = flag("--fast")
    let sandboxed = !flag("--no-sandbox")
    guard let file = args.first else { fail("缺少输入记录文件\n\n" + usage) }
    exit(runReplay(record: URL(fileURLWithPath: file), engineDir: engine, sandboxed: sandboxed, fast: fast))
case "list":
    exit(runList())
case "-h", "--help", "help":
    print(usage)
default:
    fail("不认识的命令：\(command)\n\n" + usage)
}
