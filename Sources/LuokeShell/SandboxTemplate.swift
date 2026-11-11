// 由 research/seatbelt/profile.sb 加上第 10 节（壳自己的目录，插在第 8 节之前）而来。改规则时两处一起改，并重跑 research/seatbelt/run_tests.sh。

let sandboxTemplate = #"""
;;; 螺壳输入法 — 引擎沙盒模板 (SBPL, Seatbelt)。来源：research/seatbelt/profile.sb（实测结论见那里的 README），加上第 10 节（在第 8 节之前）。
;;;
;;; 启动方式（cwd = 引擎文件夹）:
;;;   /usr/bin/sandbox-exec -f profile.sb \
;;;       -D ENGINE_ID=<id> -D ENGINE_DIR=<引擎文件夹> -D DATA_DIR=<引擎数据目录> -D TMP_DIR=<临时目录> \
;;;       -D NET=none|local|any  -D MIC=0|1  -D CAM=0|1  -D SCREEN=0|1  -D GPU=0|1 [-D USER_CACHE=<DARWIN_USER_CACHE_DIR 的 realpath，带结尾 />] \
;;;       [-D WRITE_0=<额外可写路径> ... -D WRITE_15=...] \
;;;       [-D USER_TMP=<DARWIN_USER_TEMP_DIR 的 realpath，带结尾 />] \
;;;       [-D LOCAL_PORT_0=<端口> ... -D LOCAL_PORT_7=...]      仅 NET=local：限定只能连这些本机端口（缺省 = 本机所有端口） \
;;;       [-D HOME=<家目录>] [-D DATA_ROOT=<所有引擎数据目录的父目录>] [-D SHELL_ROOT=<~/.luoke/ime>] \
;;;       [-D MEM_DB=<记忆文件 ~/.luoke/mem.db>]                仅个人化组件声明了 memory 时 \
;;;       <command...>
;;;
;;; 注意:
;;;  * 所有路径参数必须是 realpath（Seatbelt 按解析后的真实路径匹配：/tmp、/var 是符号链接，
;;;    要写 /private/tmp、/private/var/folders/...），路径不要带结尾 /（USER_TMP 除外）。
;;;  * ENGINE_ID 只能含 [A-Za-z0-9._-]，它会进入日志标签。
;;;  * 缺省参数一律按"不声明"处理；NET 缺省 = none。
;;;
;;; 规则求值顺序（实测）：带过滤器的规则之间"后写的赢"；不带过滤器的规则（整个操作的缺省）
;;; 一律输给任何带过滤器的匹配规则，不论先后。下面据此排布：先 deny default，再放行，
;;; 最后写"即使声明了也不放行"的收尾 deny。

(version 1)

(define (param=? k v) (and (param k) (string=? (param k) v)))
;; 每条 deny 都带标签 LUOKE[<engine id>] <类别>，壳靠它从统一日志里认领违规，不必追踪子进程树。
(define (tag cls) (string-append "LUOKE[" (param "ENGINE_ID") "] " cls))

;;; ---------------------------------------------------------------------------
;;; 0. 底线：默认全拒 + Apple 的 system.sb（dyld、libc、cfprefsd、logd、trustd… 进程起得来所需的最小集）
;;;    system.sb 不含：网络 / DNS / 剪贴板 / LaunchServices / AppleEvent / 窗口服务 / 音视频。
;;; ---------------------------------------------------------------------------
(deny default (with message (tag "other")))
(import "system.sb")

;;; ---------------------------------------------------------------------------
;;; 1. 已知无害的探测：照样拒绝，但不写日志（否则每个 Python/Swift 引擎启动就刷一屏假违规）
;;; ---------------------------------------------------------------------------
(deny system-info (with no-report))                 ; vfs.disk-space / net.link.addr，运行时探测，失败有回退
(deny mach-lookup (with no-report)
  (global-name "com.apple.lsd.mapdb"                ; Foundation 创建文件时顺带查 LaunchServices 数据库
               "com.apple.lsd.modifydb"             ;   （Swift 的 write 会重试上百次）
               "com.apple.CoreServices.coreservicesd"
               "com.apple.DiskArbitration.diskarbitrationd"))
(deny system-fsctl (with no-report))
(deny system-socket (with no-report))               ; getaddrinfo 顺带试 AF_SYSTEM 套接字

;;; ---------------------------------------------------------------------------
;;; 2. 规则 1：读不限；能执行、能 fork；子进程自动继承本沙盒
;;; ---------------------------------------------------------------------------
(allow file-read*)
(allow file-map-executable)                         ; 加载 venv / homebrew / 引擎自带的 .so .dylib
(allow process-exec*)
(allow process-fork)
(allow signal (target same-sandbox))                ; 只能给自己和自己的子孙发信号
;; Python multiprocessing / shared_memory 用的 POSIX 信号量与共享内存（限定名字前缀）
(allow ipc-posix-sem* (ipc-posix-name-prefix "/mp-"))
(allow ipc-posix-shm* (ipc-posix-name-prefix "/mp-") (ipc-posix-name-prefix "/psm_"))

;; 可选：引擎之间互相隔离读。壳传入 DATA_ROOT（所有引擎数据目录的父目录）时，只能读自己的 DATA_DIR
(when (param "DATA_ROOT")
  ;; 只拒"读内容 / 列目录"，保留 stat：SQLite、Python realpath 会 lstat 每一级父目录，全拒会产生假违规
  (deny file-read-data file-read-xattr (subpath (param "DATA_ROOT")) (with message (tag "read-other-engine-data")))
  (allow file-read-data file-read-xattr (subpath (param "DATA_DIR"))))

;; 钥匙、凭据、浏览器和邮件数据、shell 历史：读不限也不给读（luokelabs/luoke-ime#6）。只拒"读内容"，保留 stat。
(when (param "HOME")
  (deny file-read-data file-read-xattr (with message (tag "read-secret"))
    (subpath (string-append (param "HOME") "/.ssh"))
    (subpath (string-append (param "HOME") "/.gnupg"))
    (subpath (string-append (param "HOME") "/.aws"))
    (subpath (string-append (param "HOME") "/.azure"))
    (subpath (string-append (param "HOME") "/.kube"))
    (subpath (string-append (param "HOME") "/.docker"))
    (subpath (string-append (param "HOME") "/.config/gcloud"))
    (subpath (string-append (param "HOME") "/.config/gh"))
    (literal (string-append (param "HOME") "/.netrc"))
    (literal (string-append (param "HOME") "/.npmrc"))
    (literal (string-append (param "HOME") "/.pypirc"))
    (literal (string-append (param "HOME") "/.git-credentials"))
    (literal (string-append (param "HOME") "/.zsh_history"))
    (literal (string-append (param "HOME") "/.bash_history"))
    (subpath (string-append (param "HOME") "/Library/Keychains"))
    (subpath (string-append (param "HOME") "/Library/Cookies"))
    (subpath (string-append (param "HOME") "/Library/Mail"))
    (subpath (string-append (param "HOME") "/Library/Messages"))
    (subpath (string-append (param "HOME") "/Library/Safari"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Google/Chrome"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Firefox"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Microsoft Edge"))
    (subpath (string-append (param "HOME") "/Library/Application Support/BraveSoftware"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Arc"))
    (subpath (string-append (param "HOME") "/Library/Application Support/1Password"))
    (subpath (string-append (param "HOME") "/Library/Application Support/com.apple.TCC"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Google/Chrome Beta"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Google/Chrome Canary"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Chromium"))
    (subpath (string-append (param "HOME") "/Library/Application Support/Vivaldi"))
    (subpath (string-append (param "HOME") "/Library/Application Support/com.operasoftware.Opera"))
    (subpath (string-append (param "HOME") "/Library/Group Containers"))
    (subpath (string-append (param "HOME") "/Library/Containers"))
    (subpath (string-append (param "HOME") "/.zsh_sessions"))
    (subpath (string-append (param "HOME") "/.local/share/fish"))
    (subpath (string-append (param "HOME") "/.cargo/credentials"))
    (subpath (string-append (param "HOME") "/.cargo/credentials.toml"))
    (subpath (string-append (param "HOME") "/.cache/huggingface"))
    (subpath (string-append (param "HOME") "/.huggingface"))
    (subpath (string-append (param "HOME") "/.config/op"))
    (subpath (string-append (param "HOME") "/.claude"))
    (subpath (string-append (param "HOME") "/.codex"))
    (literal (string-append (param "HOME") "/.python_history"))
    (literal (string-append (param "HOME") "/.node_repl_history"))
    (literal (string-append (param "HOME") "/.psql_history"))
    (literal (string-append (param "HOME") "/.mysql_history"))
    (literal (string-append (param "HOME") "/.sqlite_history"))))
;; 别的引擎的临时目录也不让读（和数据目录一样，只拒读内容、保留 stat）
(when (param "TMP_ROOT")
  (deny file-read-data file-read-xattr (subpath (param "TMP_ROOT")) (with message (tag "read-other-engine-data")))
  (allow file-read-data file-read-xattr (subpath (param "TMP_DIR"))))

;;; ---------------------------------------------------------------------------
;;; 3. 规则 2：写。只放 DATA_DIR、TMP_DIR、/dev/null 类设备 + 声明的额外路径
;;; ---------------------------------------------------------------------------
(deny file-write* (with message (tag "write")))     ; 整个操作的缺省，仅为了带上"write"标签
(allow file-write*
  (subpath (param "DATA_DIR"))
  (subpath (param "TMP_DIR")))
(allow file-write-data (literal "/dev/tty"))        ; /dev/null /dev/zero /dev/fd/* 已由 system.sb 放行
;; Swift/Foundation 的"原子写"(Data.write(.atomic)) 会先在 <DARWIN_USER_TEMP_DIR>/TemporaryItems 下建临时目录，
;; 且不理会 TMPDIR 环境变量。壳传 USER_TMP 才放行这一个子目录。
(when (param "USER_TMP")
  (allow file-write* (subpath (string-append (param "USER_TMP") "TemporaryItems"))))
;; 声明的额外可写路径（引擎说明 permissions.write，壳 realpath 之后依次填 WRITE_0..WRITE_15）
(for-each
  (lambda (k) (if (param k) (allow file-write* (subpath (param k)))))
  '("WRITE_0" "WRITE_1" "WRITE_2" "WRITE_3" "WRITE_4" "WRITE_5" "WRITE_6" "WRITE_7"
    "WRITE_8" "WRITE_9" "WRITE_10" "WRITE_11" "WRITE_12" "WRITE_13" "WRITE_14" "WRITE_15"))

;;; ---------------------------------------------------------------------------
;;; 4. 规则 3：网络三档（system.sb 里只有 /private/var/run/syslog 这一个 unix socket 例外）
;;; ---------------------------------------------------------------------------
(deny network* (with message (tag "network")))
;; 名称解析 / 网络配置探测单独打 dns 标签（"软"违规）：getaddrinfo("localhost") 也会先敲一下 mDNSResponder，
;; 引擎照样拿到 /etc/hosts 的结果，所以壳不应把它当成"引擎想联网"去弹窗，只记录即可。
;; 这几条是带过滤器的 deny，会压过后面不带过滤器的 (allow network*)，所以对 any 档要排除。
(unless (param=? "NET" "any")
  (deny network-outbound (literal "/private/var/run/mDNSResponder") (with message (tag "dns")))
  (deny mach-lookup (with message (tag "dns"))
    (global-name "com.apple.dnssd.service" "com.apple.SystemConfiguration.DNSConfiguration"
                 "com.apple.SystemConfiguration.configd" "com.apple.SystemConfiguration.SCNetworkReachability"
                 "com.apple.networkd" "com.apple.nesessionmanager" "com.apple.nesessionmanager.content-filter"
                 "com.apple.nehelper" "com.apple.symptomsd" "com.apple.usymptomsd"
                 "com.apple.cfnetwork.cfnetworkagent" "com.apple.AppSSO.service-xpc")))
(when (param=? "NET" "local")
  ;; 只放回环地址的 TCP/UDP（127.0.0.1、::1）。unix domain socket 一律不放（见 README）。
  ;; 不放 mDNSResponder / dnssd：所以只有 getaddrinfo("localhost")（读 /etc/hosts）能解析，
  ;; CFNetwork/URLSession 的主机名解析走 mDNSResponder，要用 127.0.0.1 字面量。
  ;; 注意 "local" = 本机上的任何服务：本地代理 (Clash/Surge 的 127.0.0.1:7890)、docker、数据库……都能连，
  ;; 经本地代理就等于能上外网。所以提供可选的端口白名单 LOCAL_PORT_0..7：给了就只放这些端口。
  (if (param "LOCAL_PORT_0")
      (for-each
        (lambda (k) (when (param k) (allow network-outbound (remote ip (string-append "localhost:" (param k))))))
        '("LOCAL_PORT_0" "LOCAL_PORT_1" "LOCAL_PORT_2" "LOCAL_PORT_3" "LOCAL_PORT_4" "LOCAL_PORT_5" "LOCAL_PORT_6" "LOCAL_PORT_7"))
      (allow network-outbound (remote ip "localhost:*")))
  (allow network-bind     (local ip "localhost:*"))
  (allow network-inbound  (local ip "localhost:*")))
(when (param=? "NET" "any")
  (allow network*)                                  ; 含 mDNSResponder socket、任意 unix socket
  (system-network)                                  ; system.sb 提供：dnssd / configd / networkd / nehelper …
  (allow mach-lookup (global-name "com.apple.nesessionmanager.content-filter")))

;;; ---------------------------------------------------------------------------
;;; 5. 规则 5：麦克风 / 摄像头（默认拒；声明后放行，服务清单取自 Apple 的 appsandbox-common.sb 里
;;;    audio-input / coreaudio-services / camera 三段。麦克风放行后真录音已实测够用，摄像头未实测，见 research/seatbelt/README.md）
;;; ---------------------------------------------------------------------------
(deny device-microphone (with message (tag "microphone")))
(deny device-camera (with message (tag "camera")))
(deny mach-lookup (with message (tag "microphone"))
  (global-name "com.apple.audio.audiohald" "com.apple.audio.coreaudiod"
               "com.apple.audio.AudioComponentRegistrar" "com.apple.audio.AudioComponentPrefs"
               "com.apple.audio.AudioSession" "com.apple.audioanalyticsd"
               "com.apple.mediaexperience.endpoint.xpc"))
(deny mach-lookup (with message (tag "camera"))
  (global-name "com.apple.applecamerad" "com.apple.appleh13camerad" "com.apple.appleh16camerad"
               "com.apple.cmio.registerassistantservice"
               "com.apple.cmio.registerassistantservice.system-extensions"))
(when (param=? "MIC" "1")
  (allow device-microphone)
  (allow mach-lookup
    (global-name "com.apple.audio.audiohald" "com.apple.audio.coreaudiod"
                 "com.apple.audio.AudioComponentRegistrar" "com.apple.audio.AudioComponentPrefs"
                 "com.apple.audio.AudioSession" "com.apple.audioanalyticsd"
                 "com.apple.mediaexperience.endpoint.xpc"
                 "com.apple.cmio.registerassistantservice.system-extensions"))
  (allow user-preference-read (preference-domain "com.apple.avfoundation" "com.apple.coremedia"))
  (allow iokit-open-user-client
    (require-all (iokit-connection "AppleHDAEngineInput")
                 (iokit-user-client-class "IOAudioControlUserClient" "IOAudioEngineUserClient"))))
(when (param=? "CAM" "1")
  (allow device-camera)
  (allow mach-lookup
    (global-name "com.apple.applecamerad" "com.apple.appleh13camerad" "com.apple.appleh16camerad"
                 "com.apple.cmio.registerassistantservice"
                 "com.apple.cmio.registerassistantservice.system-extensions"))
  (allow user-preference-read (preference-domain "com.apple.avfoundation" "com.apple.cmio" "com.apple.coremedia" "com.apple.coremediaio.support")))
;; 麦克风 / 摄像头 / 屏幕录制的系统授权 (TCC) 查询服务：三者任一被声明才放行
(deny mach-lookup (with message (tag "tcc"))
  (global-name "com.apple.tccd" "com.apple.tccd.system"))
(when (or (param=? "MIC" "1") (param=? "CAM" "1") (param=? "SCREEN" "1"))
  (allow mach-lookup (global-name "com.apple.tccd" "com.apple.tccd.system")))

;;; ---------------------------------------------------------------------------
;;; GPU（Metal，引擎里跑本地模型用）：声明 gpu 才放行。放在屏幕录制一节之前，让那一节的禁止规则仍然优先。
;;; system-graphics 来自 system.sb；Metal 着色器编译器把缓存写在用户缓存目录（USER_CACHE）下，
;;; 并给系统的编译服务签发读这些路径的凭证。可读写的凭证只许签给这几个缓存目录。
;;; ---------------------------------------------------------------------------
(when (param=? "GPU" "1")
  (system-graphics)
  (allow mach-lookup (global-name "com.apple.MTLCompilerService"))
  (allow iokit-open-user-client (iokit-user-client-class "AGXDeviceUserClient" "AGXSharedUserClient" "IOGPUDeviceUserClient"))
  (allow file-issue-extension (extension-class "com.apple.app-sandbox.read"))
  ;; 这几个缓存目录可能直接在用户缓存目录下，也可能在 <应用标识>/ 下一层（macOS 26 上 Python 的是 org.python.python/com.apple.metal）
  (when (param "USER_CACHE")
    (allow file-write* file-issue-extension
      (require-all (subpath (param "USER_CACHE")) (regex #"/com\.apple\.(metal|metalfe|gpuarchiver)(/|$)")))))

;;; ---------------------------------------------------------------------------
;;; 6. 规则 6：屏幕录制。Seatbelt 没有"屏幕"这个操作；能拦，靠的是不放行抓屏所需的 Mach 服务
;;;    （WindowServer 连接、replayd；TCC 查询服务见上一节）。声明后放行这几个服务（真实抓屏未实测，见 README）。
;;; ---------------------------------------------------------------------------
(deny mach-lookup (with message (tag "screen"))
  (global-name "com.apple.replayd" "com.apple.windowserver.active" "com.apple.windowserver.session"
               "com.apple.CARenderServer" "com.apple.screencapture.interactive"))
(when (param=? "SCREEN" "1")
  (allow mach-lookup
    (global-name "com.apple.replayd" "com.apple.windowserver.active" "com.apple.CARenderServer")))

;;; ---------------------------------------------------------------------------
;;; 7. 规则 7：借别的程序间接外发（打开网址/应用、AppleEvent、剪贴板）。无对应声明，永远拒绝。
;;;    这些本来就被 deny default 拒了；单独写出来是为了 (a) 日志里带 exfil 标签、
;;;    (b) 即使有人把底线改成 allow default，这几道仍在。
;;; ---------------------------------------------------------------------------
(deny lsopen (with message (tag "exfil")))
(deny appleevent-send (with message (tag "exfil")))
(deny job-creation (with message (tag "exfil")))
(deny hid-control (with message (tag "exfil")))
(deny mach-lookup (with message (tag "exfil"))
  (global-name "com.apple.coreservices.launchservicesd" "com.apple.lsd.open" "com.apple.lsd.openurl"
               "com.apple.coreservices.appleevents" "com.apple.coreservices.quarantine-resolver"
               "com.apple.pasteboard.1" "com.apple.distributed_notifications@1v3"
               "com.apple.distributed_notifications@Uv3" "com.apple.Pasteboard"))
(deny process-exec* (with message (tag "exfil"))
  (literal "/usr/bin/open") (literal "/usr/bin/osascript") (literal "/usr/bin/shortcuts")
  (literal "/usr/bin/automator") (literal "/usr/bin/pbcopy") (literal "/usr/bin/pbpaste")
  (literal "/usr/sbin/screencapture") (literal "/bin/launchctl"))

;;; ---------------------------------------------------------------------------
;;; 10. 壳自己的目录（SHELL_ROOT = ~/.luoke/ime）：输入记录（原始按键）和壳的设置不可读；
;;;     除自己的数据目录外一律不可写（别的引擎的数据、引擎目录、设置、记录）。即使 write 声明覆盖了这里也一样。
;;;     LUOKE_HOME（~/.luoke）下螺壳其他工具的数据（比如记忆 mem.db）一律不可读，只放回自己的引擎文件夹和数据目录。
;;;     壳总是传真的 ~/.luoke（只有测试换成自己的临时目录，免得在用户的目录里建测试文件）。
;;;     放在第 8 节之前：第 8 节的禁止写最后生效，这里重新放行数据目录也压不过它。
;;; ---------------------------------------------------------------------------
(when (param "LUOKE_HOME")
  (deny file-read-data file-read-xattr (with message (tag "read-protected"))
    (subpath (param "LUOKE_HOME")))
  (allow file-read-data file-read-xattr (subpath (param "ENGINE_DIR")) (subpath (param "DATA_DIR"))))
;; 个人化组件（声明了 permissions.memory）：放行记忆文件和 SQLite 的 WAL、共享内存、日志文件，别的照样读不到。
;; 读要写成 file-read-data file-read-xattr：上面拒的是这两个具体操作，写成 file-read* 的放行压不过它（实测，不论先后）。
(when (param "MEM_DB")
  (allow file-read-data file-read-xattr file-write*
    (literal (param "MEM_DB"))
    (literal (string-append (param "MEM_DB") "-wal"))
    (literal (string-append (param "MEM_DB") "-shm"))
    (literal (string-append (param "MEM_DB") "-journal"))))
;; SQLite 新建 -wal、-journal 以后会打开所在目录同步一下：那个目录（~/.luoke）照样不让读（读了就能列出螺壳别的工具的文件），
;; 但不报告——失败了 SQLite 会忽略，报出来菜单里就多一条"被沙盒拦下"。只针对这一个目录本身，里面的文件照旧会报。
(when (param "MEM_DIR")
  (deny file-read-data (with no-report) (literal (param "MEM_DIR"))))
(when (param "SHELL_ROOT")
  (deny file-read-data file-read-xattr (with message (tag "read-protected"))
    (subpath (string-append (param "SHELL_ROOT") "/records"))
    (literal (string-append (param "SHELL_ROOT") "/settings.json")))
  (deny file-write* (with message (tag "write-protected"))
    (subpath (param "SHELL_ROOT")))
  (allow file-write* (subpath (param "DATA_DIR"))))

;;; ---------------------------------------------------------------------------
;;; 8. 收尾：即使 write 声明里列了也不给写的位置（避免声明 "~" 之类把整个沙盒掏空）
;;; ---------------------------------------------------------------------------
(deny file-write* (with message (tag "write-protected"))
  (subpath (param "ENGINE_DIR")))                   ; 引擎文件夹永远只读：改不了自己的引擎说明
(when (param "HOME")
  (deny file-write* (with message (tag "write-protected"))
    (subpath (string-append (param "HOME") "/Library/LaunchAgents"))
    (subpath (string-append (param "HOME") "/Library/Input Methods"))
    (subpath (string-append (param "HOME") "/.ssh"))
    ;; shell 的启动文件（登录、开终端时自动执行）
    (literal (string-append (param "HOME") "/.zshrc"))
    (literal (string-append (param "HOME") "/.zprofile"))
    (literal (string-append (param "HOME") "/.zshenv"))
    (literal (string-append (param "HOME") "/.zlogin"))
    (literal (string-append (param "HOME") "/.zlogout"))
    (literal (string-append (param "HOME") "/.bashrc"))
    (literal (string-append (param "HOME") "/.bash_profile"))
    (literal (string-append (param "HOME") "/.bash_login"))
    (literal (string-append (param "HOME") "/.bash_logout"))
    (literal (string-append (param "HOME") "/.profile"))
    (subpath (string-append (param "HOME") "/.config/fish"))
    (subpath (string-append (param "HOME") "/.oh-my-zsh"))))

;; 不许建符号链接：个人化组件能把 mem.db 的 -wal / -shm / -journal 换成指向 ~/.zshenv 之类的链接，沙盒外的螺壳记忆打开时
;; SQLite 会跟着写过去（luoke-mem 0.15.8 打开前也核对）。别的引擎也用不着建链接。
(deny file-write-create (vnode-type SYMLINK) (with message (tag "write-protected")))

;;; ---------------------------------------------------------------------------
;;; 9. 静默的拒绝：Python 的字节码缓存写入（必须放在收尾 deny 之后，才能压过上面的 write-protected 标签）
;;; ---------------------------------------------------------------------------
;; 引擎文件夹里的 __pycache__（只读，Python 会优雅忽略）。用 require-all(subpath, 固定正则) 而不是把 ENGINE_DIR 拼进正则：
;; 路径里的 ( [ + . 等字符不会被当成正则元字符。
(deny file-write* (with no-report)
  (require-all (subpath (param "ENGINE_DIR")) (regex #"/__pycache__(/|$)")))
;; Apple 自带的 /usr/bin/python3 (Xcode CLT) 把【所有】模块的字节码缓存重定向到 ~/Library/Caches/com.apple.python/<模块完整路径>/。
;; 不能放行：它是用户所有 Apple Python 共用的缓存，往里写恶意 .pyc = 在沙盒外的 Python 里执行代码。
;; 静默拒绝即可（Python 照常运行，只是每次重新编译）；壳应给引擎设 PYTHONPYCACHEPREFIX=<DATA_DIR>/pycache，缓存落在自己的数据目录。
(when (param "HOME")
  (deny file-write* (with no-report)
    (subpath (string-append (param "HOME") "/Library/Caches/com.apple.python"))))
"""#
