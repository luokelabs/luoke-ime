# 螺壳输入法 · 引擎 Seatbelt 沙盒实验

环境：macOS 27.0.1 (26A434) / Apple Silicon / `/usr/bin/python3` 3.9.6 / Swift 6.4。普通 admin 用户，无 sudo。
结果：`LUOKE_SBX_NO_EXTERNAL=1 ./run_tests.sh` 共 **168 项检查全部 PASS、0 FAIL**，另有 32 条 INFO（已知限制）、3 条 UNVERIFIED（见第 8 节）；不加该变量时多做一次到 `1.1.1.1:443` 的只握手连接，把其中一条 UNVERIFIED 变成 PASS（本机已实测通过）。

**一句话结论**：网络三档、写限制、子进程继承、麦克风/摄像头/屏幕/间接外发的"默认关"，Seatbelt 都能做到；但必须以 `(deny default)` 为底，**设计文档里"以允许为底、定向禁止"的写法不行**（实测 12 个危险 Mach 服务全部漏掉，见 6.1）。屏幕录制没有专门的操作，靠"让抓屏所需的系统服务连不上"间接实现；麦克风/摄像头/屏幕的"声明后放行"那一半没法在不弹窗的前提下实测。

## 文件

| 文件 | 作用 |
|---|---|
| `profile.sb` | 唯一的 SBPL 模板，带注释；全部能力由 `-D` 参数开关，**不需要生成 profile 文本** |
| `gen_args.py` | 参考实现：引擎说明里的 `permissions` → `sandbox-exec` 参数 + 引擎环境变量（含校验、`~` 展开、realpath、警告） |
| `denial_monitor.py` | 参考实现：`log stream` 违规监听器，解析字段并翻译成"该补哪条声明" |
| `run_tests.sh` / `run_tests.py` | 非交互重跑全部检查，逐条规则打印 PASS/FAIL/INFO/UNVERIFIED，有 FAIL 则退出码 1。`LUOKE_SBX_NO_EXTERNAL=1` 完全不碰外网（默认会对 1.1.1.1:443 做**一次**只握手不发数据的 TCP 连接） |
| `probes/` | 测试用的假引擎与探针：`engine_probe.py`、`py_workload.py`、`fprobe.swift`（纯 Foundation）、`sysprobe.swift`（只读系统查询）、`sbprobe.c`（`sandbox_check` / `bootstrap_look_up`）、`listener.py`（沙盒外的本机监听器）。Swift/C 探针由脚本编译到 `$TMPDIR/luoke-seatbelt-build/` |

测试安全边界：不 `open` 任何 URL/应用、不发 AppleEvent、不请求任何系统权限、不开麦克风/摄像头、不调 `screencapture`、不读剪贴板内容（只读 `changeCount`）、不改系统设置。麦克风/摄像头/屏幕/AppleEvent/LaunchServices 一律用 `sandbox_check()`、`bootstrap_look_up()`（只拿端口不发消息）、LaunchServices 只读查询、`CGPreflightScreenCaptureAccess` 与沙盒拒绝日志取证。

## 1. 启动方式

```sh
/usr/bin/sandbox-exec -f profile.sb \
  -D ENGINE_ID=pinyin -D ENGINE_DIR=<引擎文件夹> -D DATA_DIR=<数据目录> -D TMP_DIR=<临时目录> \
  -D NET=none|local|any -D MIC=0|1 -D CAM=0|1 -D SCREEN=0|1 \
  -D USER_TMP=<DARWIN_USER_TEMP_DIR 的 realpath，带结尾 /> -D HOME=<家目录> -D DATA_ROOT=<所有数据目录的父目录> \
  [-D WRITE_0=<额外可写路径> … -D WRITE_15=…] [-D LOCAL_PORT_0=<端口> … -D LOCAL_PORT_7=…] \
  <run 命令…>            # cwd = 引擎文件夹
```

必须同时给引擎设的环境变量（`gen_args.py` 已生成）：

| 变量 | 原因 |
|---|---|
| `TMPDIR=<TMP_DIR>/` | 否则 Python `tempfile` 找不到可写临时目录而失败（实测）。**Swift 的 `NSTemporaryDirectory()` 无视 TMPDIR**，返回壳的 `/var/folders/…/T/`，写会被拒，Swift 引擎得自己读 `ProcessInfo.environment["TMPDIR"]` |
| `PYTHONPYCACHEPREFIX=<DATA_DIR>/pycache` | Homebrew/python.org 的 Python 往模块旁边写 `__pycache__`，Apple 的 `/usr/bin/python3` 往 `~/Library/Caches/com.apple.python/` 写（各 Python 共用，**不能放行**：往里写恶意 .pyc = 在沙盒外的 Python 里执行代码）。不设就会产生写违规记录并每次重新编译标准库：重一点的 import 实测 187 ms（无缓存）→ 首次 206 ms → 之后 63 ms（无沙盒 51 ms） |
| `LUOKE_IME_DATA=<DATA_DIR>` | 协议里已有 |

所有路径参数必须是 **realpath**（Seatbelt 按解析后的真实路径匹配；`/var/folders/…` 传符号链接形式则写入失败，已测）。但 DATA_DIR、TMP_DIR、WRITE_n 这些引擎自己能改动的目录**只解析上级目录、不跟随最后一级**：引擎能把它们本身换成指向家目录的链接，壳若跟随，下次启动就把家目录整个放开了（review 时实测过这条逃逸）；不跟随时经链接写到的地方不在放行范围内，照样被拦（已测）。路径里的空格、中文、`()[]+.` 都没问题（已测，模板里没有把路径拼进正则）。缺必需参数时 `sandbox-exec` 以 rc=65 失败（fail closed）。

## 2. 规则 × 结果

| # | 规则 | 能否实现 | 证据 | 注意 |
|---|---|---|---|---|
| 1 | 读不限 | **能** | Python 27 步标准库工作负载（subprocess/asyncio/multiprocessing/sqlite/ctypes/mmap/dlopen 引擎自带 .dylib…）、Swift Foundation CLI、node(V8 JIT)、bun、ruby、perl 全部正常，且**零 hard 违规报告**（只有 `getaddrinfo("localhost")` 产生 2 条 soft 的 `dns` 记录） | 读不限 ⇒ `network:any` 的引擎能外传任何自己读得到的东西（`~/.ssh`、浏览器数据、其它引擎的学习数据）。可选 `DATA_ROOT`：禁读其它引擎的数据目录内容（保留 stat，否则 SQLite 会误报） |
| 2 | 写限制 | **能** | 写 DATA_DIR/TMP_DIR/声明路径成功；写 `~`、`/tmp`、壳的 `T/` 目录、普通目录、引擎文件夹、兄弟引擎目录全部 EPERM；硬链接、符号链接穿写、rename 进来、chmod、truncate、append、unlink、xattr 全被拦且原文件完好；即使声明 `~` 可写，`~/Library/LaunchAgents`、`Input Methods`、`.ssh`、shell 的启动文件（`.zshrc`、`.zlogin`、`.profile`、`.bash_login`、`~/.config/fish`、`~/.oh-my-zsh` 等）仍不可写（收尾 deny）；数据目录被换成指向别处的链接后经链接写入被拒；引擎文件夹即使被声明也保持只读 | `__pycache__` 写入被拒但 Python 优雅继续（import 成功、不崩、不留目录），模板对引擎文件夹内的 `__pycache__` 静默拒绝。Swift 的原子写 `write(atomically:true)` 会先在 `$DARWIN_USER_TEMP_DIR/TemporaryItems/` 建临时目录，必须传 `USER_TMP` 放行这一个子目录（共享目录，有微小风险）；不传则失败 |
| 3 | 网络三档 | **能** | 三档 × {TCP4/TCP6/localhost/UDP/unix socket/bind+listen/mDNSResponder/Swift URLSession} 矩阵与预期完全一致（`run_tests.py` 的 `t_network`）。外部 `1.1.1.1:443`：none/local 在 `connect` 前就 EPERM（没发包）；any 放行（真实握手一次） | **`local` ≠ 没有外泄通道**：本机上的任何服务都能连——Clash/Surge 的 `127.0.0.1:7890` 代理等于上外网；还包括本机自己的局域网 IP、`0.0.0.0`。已实现可选端口白名单 `LOCAL_PORT_n`（已测）。unix socket 在 none/local 一律不放（它能连 docker.sock、ssh-agent 等；决定见 2.1）。`any` 含任意 unix socket。`local` 下 URLSession 解析 `localhost` 主机名失败（CFNetwork 走 mDNSResponder，见 2.1），Python/curl/nc 的 `localhost` 正常，Swift 引擎请用 `127.0.0.1` |
| 3b | DNS（none） | **能** | `getaddrinfo("example.com")` 立刻 `gaierror`（0.04 s，含进程启动，不会卡住）；mDNSResponder socket 与 `com.apple.dnssd.service` 均不可达，无 DNS 外泄；`localhost` 靠 `/etc/hosts` 照常解析 | any 档只验证了到解析器的可达性（socket + Mach），没有真发外部查询 |
| 4 | 子进程继承 | **能** | `curl`、`nc`、python 子进程、`sh -c`、双 fork+`setsid` 的孙进程：none 下全被拦，local 下全放行；子进程写 `~` 同样被拒 | 已打开的 fd 不受限（实测壳多传一个可写 fd，引擎照写）：壳 spawn 时只传 stdio，其余 CLOEXEC。setuid 程序（`ps`/`top`/`ping`/`sudo`）在任何沙盒进程里都无法 exec（内核行为，`allow default` 也一样），引擎里用不了 `ps` |
| 5 | 麦克风/摄像头 | **部分**：默认拒已验证；麦克风放行档已用真实录音验证（见下方「真实录音」），摄像头放行档只验证到策略与服务可达 | `device-microphone`/`device-camera` 都能编译；`sandbox_check` 默认拒、`MIC=1` 只放麦克风、`CAM=1` 只放摄像头，互不连带；音频守护进程（`audiohald`/`coreaudiod`/`AudioComponentRegistrar`）与相机服务（`cmio.registerassistantservice`/`appleh13camerad`/`appleh16camerad`）的 `bootstrap_look_up` 默认 1100(被沙盒拒)，声明后 0；被拒 lookup 在日志里带 `microphone`/`camera` 标签 | 放行清单取自 Apple 的 `appsandbox-common.sb`（`audio-input`、`coreaudio-services`、`camera`），**没有用真实录音引擎验证**，可能还缺服务——缺哪个会在日志里以 `mach-lookup <名字>` 暴露，照着补。`device-*` 由系统守护进程代查，是否进 Sandbox 日志未知 |
| 6 | 屏幕录制 | **能（间接）**，真实抓屏未测 | Seatbelt 没有"屏幕"操作；做法是不放行抓屏所需 Mach 服务：`windowserver.active`、`replayd`、`CARenderServer`、`tccd`。实测 `CGPreflightScreenCaptureAccess`：沙盒外 true → 默认沙盒内 false → `SCREEN=1` true；`CGWindowListCopyWindowInfo`（只数窗口数）：沙盒外 199 → 默认沙盒内 nil（WindowServer 连接都建不起来）→ `SCREEN=1` 199；拒绝在日志里带 `screen` 标签 | 沙盒外预检为 true 说明**子进程继承了父进程链的屏幕录制授权**，正是 ADR 0005 担心的情形，此时只有 Seatbelt 能拦。Apple 自己的 App Sandbox profile（`application.sb`）对所有（非插件）App 都放行 `replayd`/`windowserver.active`，把屏幕录制完全交给 TCC——所以这条靠的是"我们是 deny default"，不是 Seatbelt 的专门能力。`SCREEN=1` 下 CoreGraphics 初始化还会碰 `launchservicesd`（本模板归 exfil、不放行），ScreenCaptureKit 是否需要它未知 |
| 7 | 间接外发 | **能** | `exec /usr/bin/open`、`osascript` EPERM；LaunchServices 只读查询 `LSCopyDefaultApplicationURLForURL`/`NSWorkspace.urlForApplication(toOpen:)`：沙盒外得 Chrome，沙盒内失败/nil；`launchservicesd`、`lsd.open`、`coreservices.appleevents`、`pasteboard.1`、`distributed_notifications`、`quarantine-resolver` 沙盒内全 1100；`sandbox_check` 对 `lsopen`、`appleevent-send`（含 `appleevent-destination com.apple.finder`）、`job-creation`、`hid-control` 全拒；真试 `launchctl submit`（逃出沙盒的经典手法）被拒并记 `job-creation` | **没有真去 open / 发 AppleEvent**，上面是推断+只读证据。launchd 的只读查询仍可用（`launchctl print gui/UID` 沙盒内能跑，泄露已装 LaunchAgents 列表）；`kickstart`/`bootout` 等动词未试。封 LaunchServices 的代价：Foundation 里依赖 LS 数据库的功能退化——`UTType("txt")` 变成 `dyn.…`，`typeIdentifierKey`/`contentTypeKey`/`localizedNameKey`/`preferredMIMEType` 为 nil；`Bundle(path:)`、`UserDefaults`、`Process`、URLSession(any) 不受影响 |
| 8 | 剪贴板（只报告） | 本模板下**不可读** | `NSPasteboard.general.changeCount`：沙盒外 200，沙盒内 0；`com.apple.pasteboard.1` 沙盒内 1100 | `allow default` 型 profile 下可读（该服务可达）。没有读内容（新系统可能弹"粘贴"提示） |
| 9 | 违规上报 | **能**，见第 4 节 | 普通用户 `log stream`；动作发起→收到事件**中位 0.37 ms、最大 0.5 ms**；字段齐全 | 网络事件里目标主机被脱敏成 `*`，只剩端口；非管理员用户未验证 |
| 10 | 开销 | 小 | 见第 5 节 | |

### 2.1 取舍说明

- **unix domain socket**：none/local 不放。理由：它能连 docker.sock（等于 root）、ssh-agent、各种用户态守护进程，不属于"只连本机"；本地模型服务（oMLX/Ollama）都是 TCP，走 `127.0.0.1` 即可。
- **local 下的 DNS**：不放 `mDNSResponder` / `com.apple.dnssd.service`，否则"local"就带上了 DNS 外泄通道（域名标签可以夹带数据）。代价：只有 `getaddrinfo`（走 `/etc/hosts`）能解析 `localhost`；CFNetwork（Swift `URLSession`）会报 `-1003 hostname could not be found`，要用 `127.0.0.1`。`getaddrinfo("localhost")` 本身会先敲一下 mDNSResponder socket 被拒再回退，所以这类拒绝单独打 `dns` 标签、定为 soft。
- **ENGINE_DIR 只读**：除了 profile 里没放行，收尾还有一条 `deny file-write* (subpath ENGINE_DIR)` 压过任何声明。

## 3. 声明 → 参数（`gen_args.py`；`python3 gen_args.py --demo` 可看全部示例）

模板是同一个 `profile.sb`，"每条声明一个片段"就是几个 `-D`：

```
permissions                                     追加的参数（固定参数 ENGINE_ID/ENGINE_DIR/DATA_DIR/TMP_DIR/USER_TMP/HOME/DATA_ROOT 每个引擎都给）
{}                                              -D NET=none -D MIC=0 -D CAM=0 -D SCREEN=0
{"network":"none"}                              -D NET=none
{"network":"local"}                             -D NET=local
{"network":"local","network_ports":[11434]}     -D NET=local -D LOCAL_PORT_0=11434          （扩展：建议加进引擎说明）
{"network":"any"}                               -D NET=any
{"write":["~/Documents/luoke-demo"]}            -D WRITE_0=/Users/me/Documents/luoke-demo   （~ 展开、realpath、至多 16 条）
{"microphone":true}                             -D MIC=1                                    （camera → CAM=1，screen → SCREEN=1）
```

**能不能只用一个模板？能。** 唯一需要"变长"的是额外可写路径与本机端口白名单，用编号槽位（`WRITE_0..15`、`LOCAL_PORT_0..7`，槽位数改模板里一行列表即可）。未给的参数 `(param "X")` 返回 `#f`，模板里一律按"不声明"处理。备选：`(import (param "EXTRA"))` 可按路径导入壳生成的片段文件（已验证可用），但没有必要。

## 4. 违规上报配方

```sh
/usr/bin/log stream --style ndjson --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "LUOKE["'
```

- profile 里**每条 deny 都带 `(with message "LUOKE[<engine-id>] <类别>")`**（含 `deny default`，参数化标签实测可用），于是日志第二行就是标签：
  ```
  Sandbox: Python(57698) deny(1) file-write-create /Users/me/x/y
  LUOKE[pinyin] write
  ```
  壳直接按标签认领，**不需要追踪子进程树**（引擎的 `curl` 子进程、孙进程的拒绝同样带标签；已测）。类别：`write` `write-protected` `network` `dns`(soft) `microphone` `camera` `screen` `tcc`(soft) `exfil` `read-other-engine-data` `other`。
- 字段：日志时间戳、进程名、**pid**（与被拦进程一致，已测）、操作（`file-write-create`、`network-outbound`、`mach-lookup`、`process-exec*`、`job-creation`…）、路径/地址、标签。**拿不到**：网络目标主机（只有 `remote:*:443`，主机被脱敏）、调用栈。
- 内核对相同拒绝限流：60 次相同拒绝只出 1 条完整事件 + "59 duplicate reports" 折叠行（`denial_monitor.py` 已解析）——正好满足设计里"每种被拦的操作只在第一次通知"。
- 延迟：稳态下动作发起→壳收到事件**中位 0.37 ms、最大 0.51 ms**（10 次）；`log stream` 进程拉起后约 **0.04 s** 就已订阅完毕（拉起后立刻触发的第一只金丝雀就收到了）。常驻开销：空闲时约 3.7 MB 内存、CPU 约 2–5 %（6 s 采样，含启动）。仍建议壳启动时就常驻一个，不要按需拉起。不需要 `--level debug`。
- 谓词只收带标签的，系统里其它进程每秒上百条无关拒绝被过滤掉。
- `denial_monitor.py` 的 `hint_for()`：类别 → "该补哪条声明"，例如 `write` → "permissions.write 里加入 <目录>"，`network` → "提升为 local（如 127.0.0.1:端口）或 any"，`exfil` → "没有对应声明，一律不放行"。`severity: hard` 弹通知，`soft`（`dns`、`tcc`、`__pycache__` 写入、未归类）只记录到开发模式日志。
- `process-exec*` 被拒**会**写日志（`process-exec* /usr/bin/open`，已测）；引擎的 `run` 命令本身 exec 失败时 `sandbox-exec` 以 rc=71 退出并在 stderr 打印 `execvp() of … failed`，注意与引擎自己的退出码区分。`job-creation`（由 launchd 代查）验证过会写日志，进程名是发起方 `launchctl`；而 `lsopen`/`appleevent-send`/`device-microphone`/`device-camera` 这类由系统守护进程代查的操作是否写 Sandbox 日志**未验证**。运行时还可能把 EPERM 翻译成别的错误码（临时手测：bun 把被拒的 connect 报成 ECONNREFUSED），所以不能只看引擎自己的报错。
- **必须是 admin 用户吗**：本机是 admin 用户，免 sudo 即可。`/usr/bin/log` 字符串里有 "Must be admin to run '%s' command"，标准用户能否 `log stream` **未验证**；失败时沙盒照样生效，只是上报退化为引擎的 stderr。壳自己若是 App Sandbox 进程则 `log`/`sandbox-exec` 都跑不了（设计里壳不在沙盒内，没问题）。

## 5. 开销（`python3 -c pass` 等，中位数，15 次交替）

| 命令 | 无沙盒 | `sandbox-exec` | 增量 |
|---|---|---|---|
| `/usr/bin/true` | 2.1 ms | 13.4 ms | +11.3 ms |
| `python3 -c pass` | 16.2 ms | 28.1 ms | **+11.9 ms** |
| Swift Foundation CLI | 78.7 ms | 96.3 ms | +17.6 ms |

增量基本是每次启动编译 profile（含 `system.sb`）的固定成本，约 12 ms。引擎是常驻进程，只在启动/重启时付一次。

## 6. 与设计假设的出入（需要改设计/文档的地方）

1. **"规则以允许为底，定向禁止"（设计.md）不成立。** 对照实验（`t_naive`）：`(allow default)` + `(deny network*)` + `(deny file-write*)` + `(deny device-microphone/camera)` + `(deny appleevent-send)` + `(deny lsopen)` + 拒 exec open/osascript 之后，剪贴板、LaunchServices、AppleEvent 服务、`dnssd`、`configd`、`windowserver`、`replayd`、`coreaudiod`、`audiohald`、相机服务、`tccd` **12/12 全部仍可达**，LaunchServices 查询照样返回 Chrome、剪贴板照样读到 `changeCount`。必须 `(deny default)`，本模板下 12/12 全部不可达。
2. **屏幕录制不是 Seatbelt 能力，是"服务连不上"的副作用**，且 Apple 自己的 App Sandbox 对此放行。ADR 0006 里"实现时要验证"的结论：可行，但只验证到服务不可达/预检失败/窗口枚举失败，没抓过屏。
3. **`network: local` 不是"无外泄"**：本机所有服务（含本地代理）都能连。建议在引擎说明加可选的端口列表，安装确认时展示"可连本机任意端口"。
4. **"读文件不受限"+ `network: any` = 引擎可以带走用户一切可读数据**，Seatbelt 没有办法在不限制读的情况下堵住；`DATA_ROOT` 只能隔离引擎之间。
5. **`write` 声明需要壳端把关**：`write: ["~"]` 会把写限制掏空（模板的收尾 deny 只保护引擎文件夹、LaunchAgents、Input Methods、`.ssh`、shell 的启动文件）。`gen_args.py` 对"整个家目录可写"返回警告，安装确认界面应醒目标红。壳读取引擎数据目录里的文件时要防符号链接（引擎可以在自己的目录里放符号链接指向 `~/.zshrc`，诱使不在沙盒内的壳去写，或指向壳的设置诱使壳替它读）——壳读 `options.json` 用 `O_NOFOLLOW` 并要求是普通文件（见 HostTests 的「沙盒的漏洞」）。
6. **对 Python/Swift 作者的约束**（写进《写引擎》）：用 `TMPDIR` 或数据目录放临时文件，不要写 `/tmp`；Swift 不要用 `NSTemporaryDirectory()`；URLSession 在 `local` 档用 `127.0.0.1`；不要依赖 `ps`/`ping`（setuid 程序在沙盒里无法执行）。
7. **"后写的赢"只在操作名写得一样具体时成立**（2026-10-10，给个人化组件放行记忆时实测）：先 `(deny file-read-data … (subpath ~/.luoke))`，后面再 `(allow file-read* (literal ~/.luoke/mem.db))`，读 mem.db 照样被拒；哪怕把放行写在整份规则的最后、改成 `(subpath ~/.luoke)` 也一样。改成 `(allow file-read-data file-read-xattr …)` 才生效。所以要在一条具体操作的禁止上开口子，放行也要写同样具体的操作名（模板第 10 节就是这样写的）。这个坑在新建的空库上看不出来：SQLite 第一次只写不读，第二次打开读文件头才失败，报 `authorization denied`。
8. **`sandbox-exec` 已被 Apple 标为 deprecated**（man 页），`system.sb` 是 Apple 的私有接口。当前可用且是 fail closed（profile 编译失败 rc=65，引擎不会起来），但建议壳在启用引擎时预编译一次 profile 做自检，并关注新系统版本。替代方案是壳自带一个小启动器直接调 `sandbox_init_with_parameters` 再 `exec`（同一份 SBPL；**未试**）。

## 7. 壳实现清单

1. 启动时常驻一个 `log stream`（谓词见第 4 节），按标签认领；`hard` 弹通知（每种操作首次），`soft` 只记录。
2. 每个引擎：`gen_args.py` 的参数 + 环境变量；路径全部 realpath；ENGINE_ID 只含 `[A-Za-z0-9._-]`；至多 16 个额外写路径、8 个端口。
3. `fork`/`posix_spawn` 时只传 stdio，其余 fd 一律 CLOEXEC；用新进程组启动，终止时 `killpg`（已测可连孙进程清掉；`sandbox-exec` 会 `exec` 成引擎本身，pid 不变）。
4. 启用引擎时用同一份参数跑一次 `sandbox-exec … /usr/bin/true` 做编译自检。
5. 把 `dns`/`tcc`/`__pycache__` 类记录归为 soft，避免 `getaddrinfo("localhost")` 之类的误报。

## 8. 未验证清单

| 项 | 原因 / 现有证据 |
|---|---|
| 真实拍摄时，deny 在相机守护进程侧是否生效；`CAM=1` 的放行清单是否足够（麦克风已验证，见下方「真实录音」） | 会触发 TCC 弹窗，按约束未做。证据：`sandbox_check` 求值 + Mach 服务可达性差分 + Apple 自己 profile 的服务清单 |
| 真实抓屏（`CGWindowListCreateImage`/`CGDisplayStream`/ScreenCaptureKit/`screencapture`）被拦；`SCREEN=1` 是否足够 | 会截到用户屏幕且可能弹窗。证据：WindowServer/replayd/tccd 不可达、预检 false、窗口枚举 nil |
| 真正 `open` URL / 发 AppleEvent 被拒的日志长什么样（`lsopen`、`appleevent-send` 是否进 Sandbox 日志） | 按约束不触发。证据：`sandbox_check` 对这些操作返回拒、相关 Mach 服务 1100、LaunchServices 只读查询失败 |
| 非管理员用户能否 `log stream` 读到 Sandbox 拒绝 | 本机只有 admin 用户可用 |
| `launchctl kickstart/bootout/enable/disable/setenv` 等动词能否在沙盒内影响已有 launchd 作业 | 有破坏性，未试；只验证了 `submit`（被拒）与只读 `print`（可用） |
| `network: any` 下真实的外部 DNS 解析与完整 HTTPS 成功路径 | 外部流量限制；只验证了解析器 socket/Mach 可达，以及本机自签 HTTPS 上 URLSession 走到证书评估（-1202，沙盒内外一致） |
| macOS"本地网络"隐私提示（`any` 档的引擎访问局域网别的机器时是否以壳的名义弹窗） | 未测 |
| `sandbox_init_with_parameters` 启动器替代 `sandbox-exec`；其它 macOS 版本；Go/Rust 编译产物、Rosetta 下的 x86 引擎 | 只测了 27.0.1，语言覆盖 Python/Swift/Node/Bun/Ruby/Perl |

## 真实录音（麦克风放行档）

`research/mic_probe` 是一个最小的快捷键引擎（按住右 ⌥ 录音，松开把时长、采样率、音量作为文字上屏；不存音频、只算音量），声明 `"permissions": {"microphone": true}`。装成第三方引擎、确认启用后，在测试机（M4）的螺壳里实测：

- 壳启动时按 ADR 0005 向系统申请麦克风，弹窗以螺壳的名义出现（TCC 记在 `ai.luoke.inputmethod.Luoke` 名下）；允许后，沙盒里的引擎用 `AVAudioEngine` 录到了真实的声音（RMS 不为零），日志里没有沙盒拦截。现在模板里的放行清单够用。
- 按住 2 秒只录到约 1.2 秒：壳要等按住 150 ms 才发 `start`，引擎收到后启动录音又要几百毫秒。加了 `hotkey.arm`（按下就发 `arm`，引擎随壳启动）以后约 1.7–1.8 秒，引擎空着时再先 `prepare()` 好录音组件，约 1.9 秒（ADR 0016）。
- 录音组件（AVAudioEngine）还会顺手连分布式通知 `com.apple.distributed_notifications@Uv3`（大概是监听音频设备变化），模板照旧拒绝（能拿来外发），录音不受影响；壳把这一条拒绝算轻的，只记日志、不提示用户。
- 跑法：`swiftc -O -o mic_probe main.swift`，把 `engine.json` 和 `mic_probe` 放进 `~/.luoke/ime/engines/mic_probe/`，在菜单里确认启用；真机核对用 `Tests/e2e/mic.tsv`（`{hold:2000}` 按住右 ⌥ 2 秒）。`luoke-ime check research/mic_probe` 也会真的打开麦克风一下（不存音频），在自己的机器上跑之前要知道这一点。

