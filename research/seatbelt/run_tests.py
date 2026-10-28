#!/usr/bin/python3
"""螺壳输入法 · Seatbelt 沙盒实验：非交互地重跑全部检查，逐条规则打印 PASS/FAIL。

  ./run_tests.sh                   # 全部（含 1 次到 1.1.1.1:443 的真实 TCP 连接，用来证明 "any" 放行）
  LUOKE_SBX_NO_EXTERNAL=1 ./run_tests.sh   # 不做任何外部连接（"any" 档只验证到本机的连接）

安全约束（本脚本不会做的事）：不 open 任何 URL/应用、不发 AppleEvent、不请求任何系统权限、
不打开麦克风/摄像头、不调用 screencapture、不 sudo、不改系统设置。麦克风/摄像头/屏幕/AppleEvent/
LaunchServices 这几条一律用"只读预检 API + sandbox_check + bootstrap_look_up + 沙盒拒绝日志"取证。
外部网络只有一次 1.1.1.1:443 的 TCP connect（"any" 档）；其余外部目标的连接都在沙盒里被拦在 connect 之前，
不会有数据包发出。仅标准库 python3。
"""
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from denial_monitor import DenialMonitor  # noqa: E402

PROFILE = os.path.join(HERE, "profile.sb")
PROBES = os.path.join(HERE, "probes")
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
PY = "/usr/bin/python3"
HOME = os.path.realpath(os.path.expanduser("~"))
TMPROOT = os.path.realpath(os.environ.get("TMPDIR") or "/tmp")
BUILD = os.path.join(TMPROOT, "luoke-seatbelt-build")
NO_EXTERNAL = os.environ.get("LUOKE_SBX_NO_EXTERNAL") == "1"
EXAMPLE_ENGINE = os.path.join(HERE, "..", "..", "examples", "minimal")

# ----------------------------------------------------------------------------- 结果记录
RESULTS = []
RULE_TITLE = {
    1: "读：不限", 2: "写：只 DATA_DIR / TMP_DIR / 设备 / 声明路径；引擎文件夹只读", 3: "网络：none / local / any",
    4: "子进程继承沙盒", 5: "麦克风 / 摄像头", 6: "屏幕录制", 7: "间接外发（LaunchServices / AppleEvent / exec）",
    8: "剪贴板（只报告）", 9: "违规上报", 10: "启动开销", 11: "工程细节",
}


def rec(rule, status, name, detail=""):
    RESULTS.append((rule, status, name, detail))
    d = (" — " + str(detail)) if detail else ""
    print("  [%-10s] R%-2d %s%s" % (status, rule, name, d[:400]), flush=True)


def check(rule, name, cond, detail=""):
    rec(rule, "PASS" if cond else "FAIL", name, detail)
    return bool(cond)


def info(rule, name, detail=""):
    rec(rule, "INFO", name, detail)


def unverified(rule, name, detail=""):
    rec(rule, "UNVERIFIED", name, detail)


def section(title):
    print("\n== %s" % title, flush=True)


# ----------------------------------------------------------------------------- 构建探针
def build():
    os.makedirs(BUILD, exist_ok=True)
    jobs = [
        (["swiftc", "-O", "-o", BUILD + "/fprobe", PROBES + "/fprobe.swift"], PROBES + "/fprobe.swift", BUILD + "/fprobe"),
        (["swiftc", "-O", "-o", BUILD + "/sysprobe", PROBES + "/sysprobe.swift"], PROBES + "/sysprobe.swift", BUILD + "/sysprobe"),
        (["clang", "-O2", "-o", BUILD + "/sbprobe", PROBES + "/sbprobe.c"], PROBES + "/sbprobe.c", BUILD + "/sbprobe"),
        (["clang", "-dynamiclib", "-o", BUILD + "/libtiny.dylib", PROBES + "/tiny.c"], PROBES + "/tiny.c", BUILD + "/libtiny.dylib"),
    ]
    for cmd, src, out in jobs:
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            continue
        print("  building", os.path.basename(out), flush=True)
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr)
            sys.exit("build failed: " + os.path.basename(out))


# ----------------------------------------------------------------------------- 测试世界
class World:
    def __init__(self):
        self.W = tempfile.mkdtemp(prefix="luoke-sbx-", dir=TMPROOT)
        self.W = os.path.realpath(self.W)
        self.engine_dir = self.W + "/engine"
        self.data_root = self.W + "/data"
        self.data_dir = self.data_root + "/eng-a"
        self.other_data = self.data_root + "/eng-b"
        self.tmp_dir = self.W + "/tmp"
        self.extra = self.W + "/extra"
        self.outside = self.W + "/outside"
        self.sock = self.W + "/s"
        for d in (self.engine_dir, self.data_dir, self.other_data, self.tmp_dir, self.extra, self.outside):
            os.makedirs(d)
        shutil.copy(PROBES + "/sample_mod.py", self.engine_dir)
        shutil.copy(BUILD + "/libtiny.dylib", self.engine_dir)
        open(self.other_data + "/secret.txt", "w").write("other engine's learned data")
        open(self.outside + "/secret.txt", "w").write("outside secret")
        open(self.outside + "/victim.txt", "w").write("ORIGINAL")
        self.user_tmp = os.path.realpath(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()) + "/"
        self.listener = None
        self.ports = {}

    def start_listener(self):
        self.listener = subprocess.Popen([PY, PROBES + "/listener.py", self.sock, "--lan"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.ports = json.loads(self.listener.stdout.readline())

    def close(self):
        if self.listener:
            self.listener.terminate()
        shutil.rmtree(self.W, ignore_errors=True)


def lan_ip():
    for itf in ("en0", "en1", "en2"):
        r = subprocess.run(["/usr/sbin/ipconfig", "getifaddr", itf], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    return None


def sb_args(w, net="none", mic=False, cam=False, screen=False, writes=(), user_tmp=True, home=True, data_root=True,
            engine="t", data_dir=None, tmp_dir=None, profile=PROFILE, local_ports=(), engine_dir=None):
    a = [SANDBOX_EXEC, "-f", profile,
         "-D", "ENGINE_ID=" + engine, "-D", "ENGINE_DIR=" + (engine_dir or w.engine_dir),
         "-D", "DATA_DIR=" + (data_dir or w.data_dir), "-D", "TMP_DIR=" + (tmp_dir or w.tmp_dir),
         "-D", "NET=" + net, "-D", "MIC=%d" % mic, "-D", "CAM=%d" % cam, "-D", "SCREEN=%d" % screen]
    for i, p in enumerate(writes):
        a += ["-D", "WRITE_%d=%s" % (i, p)]
    for i, p in enumerate(local_ports):
        a += ["-D", "LOCAL_PORT_%d=%s" % (i, p)]
    if user_tmp:
        a += ["-D", "USER_TMP=" + w.user_tmp]
    if home:
        a += ["-D", "HOME=" + (home if isinstance(home, str) else HOME)]
    if data_root:
        a += ["-D", "DATA_ROOT=" + w.data_root]
    return a


def engine_env(w, extra=None):
    e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": HOME, "LANG": "en_US.UTF-8",
         "TMPDIR": w.tmp_dir + "/", "LUOKE_IME_DATA": w.data_dir, "LUOKE_ENGINE_DIR": w.engine_dir, "LUOKE_IME_PROTOCOL": "1"}
    if extra:
        e.update(extra)
    return e


def run_sb(w, cmd, timeout=40, env=None, **opts):
    """在沙盒里跑 cmd（cwd = 引擎文件夹），返回 CompletedProcess。"""
    full = sb_args(w, **opts) + list(cmd)
    t0 = time.time()
    try:
        cp = subprocess.run(full, capture_output=True, text=True, cwd=w.engine_dir, env=env or engine_env(w), timeout=timeout)
    except subprocess.TimeoutExpired as e:
        cp = subprocess.CompletedProcess(full, 124, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "TIMEOUT")
    cp.t0 = t0
    return cp


def pj(cp):
    """取 stdout 最后一行 JSON；没有就合成一个失败结果。"""
    for line in reversed((cp.stdout or "").strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                pass
    return {"probe": "?", "ok": False, "detail": "no json; rc=%s stderr=%s" % (cp.returncode, (cp.stderr or "").strip()[-200:])}


def probe(w, *args, **opts):
    return pj(run_sb(w, [PY, PROBES + "/engine_probe.py"] + [str(a) for a in args], **opts))


def eperm(r):
    return (not r.get("ok")) and ("Operation not permitted" in r.get("detail", "") or "Errno 1" in r.get("detail", ""))


def unsandboxed(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ----------------------------------------------------------------------------- 违规监听
EVENTS = []
EV_LOCK = threading.Lock()


def on_event(d):
    with EV_LOCK:
        EVENTS.append(d)


def events(engine, since=0.0, op=None, sub=None, cls=None):
    with EV_LOCK:
        out = [e for e in EVENTS if e["engine"] == engine and e["recv_ts"] >= since]
    if op:
        out = [e for e in out if e["op"].startswith(op)]
    if sub:
        out = [e for e in out if sub in e["detail"]]
    if cls:
        out = [e for e in out if e["tag_text"] == cls]
    return out


def wait_events(engine, since, timeout=6.0, **flt):
    end = time.time() + timeout
    while time.time() < end:
        got = events(engine, since, **flt)
        if got:
            return got
        time.sleep(0.1)
    return []


def parse_log_ts(s):
    # "2026-10-08 22:15:00.809601+0900"
    m = re.match(r"(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)\.(\d+)([+-])(\d\d)(\d\d)", s or "")
    if not m:
        return None
    y, mo, d, h, mi, se, us, sg, oh, om = m.groups()
    import calendar
    t = calendar.timegm((int(y), int(mo), int(d), int(h), int(mi), int(se)))
    off = (int(oh) * 3600 + int(om) * 60) * (1 if sg == "+" else -1)
    return t - off + int(us) / 1e6


# ----------------------------------------------------------------------------- 规则 1：读
def t_reads(w):
    section("规则 1  读：不限（Python 标准库 / ~ 下的文件 / Swift Foundation 都能正常工作）")
    eid = "t-reads"
    t0 = time.time()
    cp = run_sb(w, [PY, PROBES + "/py_workload.py"], engine=eid)
    r = pj(cp)
    check(1, "Python 标准库工作负载（subprocess/asyncio/multiprocessing/sqlite/ctypes/mmap/…）全部成功", r.get("ok"), r.get("detail"))
    r = probe(w, "read", w.outside + "/secret.txt", engine=eid)
    check(1, "读沙盒外任意文件（~ 之外也行）", r["ok"], r["detail"])
    r = probe(w, "listdir", HOME, engine=eid)
    check(1, "列 ~ 目录", r["ok"], r["detail"])
    r = probe(w, "read", "/etc/hosts", engine=eid)
    check(1, "读 /etc/hosts", r["ok"], r["detail"])
    r = pj(run_sb(w, [BUILD + "/fprobe", "basic"], engine=eid))
    check(1, "Swift Foundation 命令行（ProcessInfo/Locale/JSON/FileManager/UserDefaults/Process）", r["ok"], r["detail"][:160])
    time.sleep(1.5)
    ev = events(eid, t0)
    hard = [e for e in ev if e["severity"] == "hard"]
    soft = [e for e in ev if e["severity"] != "hard"]
    check(7, "上面这些正常工作负载（Python+Swift）不产生任何 hard 违规报告（无误报）", not hard,
          "; ".join("[%s] %s %s" % (e["tag_text"], e["op"], e["detail"][:70]) for e in hard[:6]))
    info(7, "同一负载产生的 soft（dns 类）记录 %d 条" % len(soft), "; ".join(sorted({"[%s] %s %s" % (e["tag_text"], e["op"], e["detail"][:50]) for e in soft}))[:200] + "  ← getaddrinfo('localhost') 会先敲 mDNSResponder，引擎照样拿到结果")


# ----------------------------------------------------------------------------- 规则 2：写
def t_writes(w):
    section("规则 2  写：DATA_DIR / TMP_DIR / 设备 / 声明路径；引擎文件夹只读")
    eid = "t-write"
    # --- 允许的位置
    r = probe(w, "write", w.data_dir + "/a.txt", engine=eid); check(2, "写 DATA_DIR", r["ok"], r["detail"])
    r = probe(w, "mkdir", w.data_dir + "/sub/deep", engine=eid); check(2, "DATA_DIR 下建多级目录", r["ok"])
    r = probe(w, "rename", w.data_dir + "/a.txt", w.data_dir + "/b.txt", engine=eid); check(2, "DATA_DIR 内 rename", r["ok"])
    r = probe(w, "unlink", w.data_dir + "/b.txt", engine=eid); check(2, "DATA_DIR 内 unlink", r["ok"])
    r = probe(w, "write", w.tmp_dir + "/t.txt", engine=eid); check(2, "写 TMP_DIR", r["ok"], r["detail"])
    r = probe(w, "tempfile", engine=eid); check(2, "Python tempfile（TMPDIR=TMP_DIR）可用", r["ok"] and r["detail"].startswith(w.tmp_dir), r["detail"])
    r = probe(w, "devnull", engine=eid); check(2, "写 /dev/null", r["ok"])
    # --- 不允许的位置
    marker = "luoke-sbx-probe-%d" % os.getpid()
    targets = [
        ("~ 根目录", HOME + "/." + marker),
        ("/tmp", "/tmp/" + marker),
        ("壳自己的临时目录 (DARWIN_USER_TEMP_DIR)", w.user_tmp + marker),
        ("沙盒外的普通目录", w.outside + "/x"),
        ("引擎文件夹", w.engine_dir + "/x"),
        ("另一个引擎的数据目录", w.other_data + "/x"),
    ]
    t0 = time.time()
    for label, path in targets:
        r = probe(w, "write", path, engine=eid)
        ok = eperm(r) and not os.path.exists(path)
        check(2, "写 %s 被拒" % label, ok, r["detail"])
        if os.path.exists(path):
            os.unlink(path)
    time.sleep(1.5)
    ev = events(eid, t0, op="file-write")
    check(2, "上述每次被拒都在日志里有 file-write-* 记录且带路径", len(ev) >= len(targets) and all(e["detail"].startswith("/") for e in ev),
          "%d 条; 例: %s" % (len(ev), ev[0]["detail"] if ev else "-"))
    # --- 额外声明
    r = probe(w, "write", w.extra + "/x", engine=eid); check(2, "未声明的额外路径被拒", eperm(r), r["detail"])
    r = probe(w, "write", w.extra + "/x", engine=eid, writes=[w.extra]); check(2, "声明 WRITE_0 后额外路径可写", r["ok"], r["detail"])
    r = probe(w, "write", w.outside + "/x", engine=eid, writes=[w.extra]); check(2, "声明了别的路径，不影响其它位置仍被拒", eperm(r))
    r = probe(w, "write", w.engine_dir + "/x", engine=eid, writes=[w.engine_dir]); check(2, "即使声明引擎文件夹可写，收尾 deny 仍保持只读", eperm(r), r["detail"])
    fake = w.W + "/fakehome"          # 用假 HOME 验证"声明了整个家目录可写，持久化位置仍被收尾 deny 保护"，不碰真实 ~
    for d in ("Library/LaunchAgents", "Library/Input Methods", ".ssh", ".config/fish", ".oh-my-zsh/custom"):
        os.makedirs(fake + "/" + d)
    r = probe(w, "write", fake + "/ctl.txt", engine=eid, writes=[fake], home=fake); check(2, "声明（假）家目录可写后，普通位置可写", r["ok"], r["detail"])
    for rel in ("Library/LaunchAgents/x.plist", "Library/Input Methods/x", ".ssh/authorized_keys", ".zshrc", ".bash_profile",
                ".zlogin", ".profile", ".bash_login", ".config/fish/config.fish", ".oh-my-zsh/custom/x.zsh"):
        r = probe(w, "write", fake + "/" + rel, engine=eid, writes=[fake], home=fake)
        check(2, "即使声明家目录可写，%s 仍不可写（收尾 deny）" % rel, eperm(r), r["detail"][:90])
    # 引擎把自己的数据目录换成指向别处的符号链接：壳不跟随最后一级（传链接本身的路径），经链接写到的地方不在放行范围内
    link = w.W + "/data-link"
    os.symlink(fake, link)
    r = probe(w, "write", link + "/escaped.txt", engine=eid, data_dir=link, home=fake)
    check(2, "数据目录被换成指向（假）家目录的链接：经链接写入被拒", eperm(r) and not os.path.exists(fake + "/escaped.txt"), r["detail"][:90])
    r = probe(w, "write", link + "/Library/LaunchAgents/x.plist", engine=eid, data_dir=link, home=fake)
    check(2, "……经链接写 LaunchAgents 也被拒", eperm(r), r["detail"][:90])
    r = probe(w, "write", w.outside + "/y", engine=eid, writes=[w.outside]); check(2, "声明路径可写（outside 作为额外路径）", r["ok"])
    # --- Python __pycache__：优雅失败 + 静默
    t0 = time.time()
    r = probe(w, "pycache", w.engine_dir, engine=eid + "-pyc")
    check(2, "Python import 引擎文件夹里的模块：写 __pycache__ 被拒但不崩", r["ok"] and "exists=False" in r["detail"], r["detail"])
    time.sleep(1.5)
    check(2, "__pycache__ 的拒绝是静默的（不会给用户报假违规）", not events(eid + "-pyc", t0), "")
    r = pj(run_sb(w, [PY, "-c", "import sys,json; sys.path.insert(0,%r); import sample_mod; import os; print(json.dumps({'ok': os.path.isdir(%r), 'detail': os.listdir(%r)}))" % (w.engine_dir, w.data_dir + "/pyc/" + w.engine_dir.lstrip("/"), w.data_dir + "/pyc/" + w.engine_dir.lstrip("/"))],
                    engine=eid, env=engine_env(w, {"PYTHONPYCACHEPREFIX": w.data_dir + "/pyc"})))
    check(2, "壳设 PYTHONPYCACHEPREFIX=DATA_DIR/pyc 后，字节码缓存写进数据目录（建议做法）", r["ok"], r["detail"])
    # --- 逃逸手法
    attack = (
        "import os,shutil,subprocess,json\n"
        "D=%r; V=%r; res={}\n"
        "def t(n,f):\n"
        "    try: f(); res[n]='OK'\n"
        "    except BaseException as e: res[n]='blocked'\n"
        "t('hardlink victim into data', lambda: os.link(V, D+'/hl'))\n"
        "t('symlink+write-through', lambda: (os.path.lexists(D+'/sl') or os.symlink(V, D+'/sl'), open(D+'/sl','w').write('PWNED')))\n"
        "t('rename victim into data', lambda: os.rename(V, D+'/mv'))\n"
        "t('chmod victim', lambda: os.chmod(V, 0o600))\n"
        "t('truncate victim', lambda: open(V,'r+').truncate(0))\n"
        "t('append victim', lambda: open(V,'a').write('x'))\n"
        "t('unlink victim', lambda: os.unlink(V))\n"
        "t('xattr victim', lambda: subprocess.run(['/usr/bin/xattr','-w','a','b',V],check=True,capture_output=True))\n"
        "print(json.dumps({'probe':'attacks','ok':True,'detail':res}))\n" % (w.data_dir, w.outside + "/victim.txt"))
    r = pj(run_sb(w, [PY, "-c", attack], engine=eid + "-atk"))
    d = r.get("detail", {})
    bad = {k: v for k, v in d.items() if v != "blocked"}
    victim_ok = open(w.outside + "/victim.txt").read() == "ORIGINAL"
    check(2, "逃逸手法（硬链接/符号链接穿写/rename 进来/chmod/截断/追加/删除/xattr）全部被拦且原文件完好", not bad and victim_ok, "未拦住: %s; victim=%s" % (bad, victim_ok))
    # 复制进来（读外面、写里面）应该可以
    r = pj(run_sb(w, [PY, "-c", "import shutil,json; shutil.copy(%r,%r); print(json.dumps({'ok':True,'detail':'copied'}))" % (w.outside + "/secret.txt", w.data_dir + "/copied.txt")], engine=eid))
    check(2, "把沙盒外的文件复制进 DATA_DIR（读外写内）可以", r["ok"], r["detail"])
    # --- Swift
    r = pj(run_sb(w, [BUILD + "/fprobe", "write", w.data_dir + "/swift.txt"], engine=eid)); check(2, "Swift 写 DATA_DIR", r["ok"])
    r = pj(run_sb(w, [BUILD + "/fprobe", "write", w.outside + "/swift.txt"], engine=eid)); check(2, "Swift 写沙盒外被拒", not r["ok"], r["detail"][:100])
    r = pj(run_sb(w, [BUILD + "/fprobe", "write-atomic", w.data_dir + "/swift-atomic.txt"], engine=eid)); check(2, "Swift 原子写 (write(atomically:true)) DATA_DIR：传 USER_TMP 时可用", r["ok"], r["detail"][:100])
    r = pj(run_sb(w, [BUILD + "/fprobe", "write-atomic", w.data_dir + "/swift-atomic2.txt"], engine=eid, user_tmp=False))
    info(2, "Swift 原子写在【不传 USER_TMP】时失败=%s（Foundation 无视 TMPDIR，要在 DARWIN_USER_TEMP_DIR/TemporaryItems 下建临时目录）" % (not r["ok"]), r["detail"][:90])
    r = pj(run_sb(w, [BUILD + "/fprobe", "tmpdir"], engine=eid))
    info(2, "Swift NSTemporaryDirectory() 写文件 ok=%s：它忽略 TMPDIR 环境变量，返回壳的 DARWIN_USER_TEMP_DIR，被拒；Swift 引擎须自己读 ProcessInfo.environment[\"TMPDIR\"]" % r["ok"], r["detail"][:100])
    # --- 路径必须是 realpath
    sym = w.tmp_dir.replace("/private/var/", "/var/", 1)
    r = probe(w, "write", sym + "/sym.txt", engine=eid, tmp_dir=sym)
    info(2, "TMP_DIR 传符号链接形式 (%s)：写入 ok=%s（Seatbelt 按真实路径匹配，参数必须是 realpath）" % (sym[:30] + "…", r["ok"]), r["detail"][:90])
    # --- 没设 TMPDIR 的 Python
    r = pj(run_sb(w, [PY, PROBES + "/engine_probe.py", "tempfile"], engine=eid + "-notmp", env=engine_env(w, {"TMPDIR": os.environ.get("TMPDIR", "/var/folders/xx/T/")})))
    info(2, "引擎没拿到 TMPDIR=TMP_DIR 时 tempfile 失败=%s：壳必须在引擎环境里设 TMPDIR" % (not r["ok"]), r["detail"][:90])


def t_paths(w):
    section("规则 2 补充  路径里有空格 / 中文 / 括号 / 正则元字符（引擎文件夹叫 “小鹤双拼 (v2)+[x].y”）")
    base = w.W + "/路径 测试 (v2)+[x].y"
    eng, dat, tmp = base + "/引擎 (a+b)", base + "/数据 目录", base + "/临时 [t]"
    for d in (eng, dat, tmp):
        os.makedirs(d)
    shutil.copy(PROBES + "/sample_mod.py", eng)
    kw = dict(engine="t-paths", engine_dir=eng, data_dir=dat, tmp_dir=tmp, data_root=None)
    def pr(*a, **extra):
        k = dict(kw); k.update(extra)
        cp = run_sb(w, [PY, PROBES + "/engine_probe.py"] + [str(x) for x in a], **k)
        return pj(cp)
    r = pr("write", dat + "/数据 x.txt"); check(2, "写含空格/中文的 DATA_DIR", r["ok"], r["detail"][-60:])
    r = pr("write", tmp + "/t.txt"); check(2, "写含方括号的 TMP_DIR", r["ok"])
    r = pr("write", eng + "/x"); check(2, "引擎文件夹（含括号/加号）仍只读", eperm(r), r["detail"][-70:])
    t0 = time.time()
    r = pr("pycache", eng); check(2, "含正则元字符的引擎文件夹里 import：__pycache__ 写入被静默拒绝且不崩", r["ok"], r["detail"])
    time.sleep(1.2)
    check(2, "……且没有产生任何违规报告", not events("t-paths", t0, cls="write") and not events("t-paths", t0, cls="write-protected"),
          "; ".join(e["detail"][-50:] for e in events("t-paths", t0)[:3]))


def t_declarations(w):
    section("声明 -> 参数：用 gen_args.py 把 permissions 生成 sandbox-exec 参数后真实运行（README 里的示例）")
    import gen_args
    fake_home = w.W + "/fakehome-decl"
    os.makedirs(fake_home)
    P = w.ports
    def cmd(perm, extra):
        argv, env, warn = gen_args.sandbox_command("t-decl", w.engine_dir, w.data_dir, w.tmp_dir, perm, home=fake_home, data_root=w.data_root)
        e = engine_env(w); e.update(env)
        cp = subprocess.run(argv + extra, capture_output=True, text=True, cwd=w.engine_dir, env=e)
        return pj(cp), warn, argv
    tcp = [PY, PROBES + "/engine_probe.py", "tcp", "127.0.0.1", str(P["tcp4"])]
    r, _, _ = cmd({}, tcp); check(11, "permissions={} → 本机 TCP 被拦", eperm(r), r["detail"][:80])
    r, _, _ = cmd({"network": "none"}, tcp); check(11, 'network:"none" → 本机 TCP 被拦', eperm(r))
    r, _, _ = cmd({"network": "local"}, tcp); check(11, 'network:"local" → 本机 TCP 放行', r["ok"])
    r, _, _ = cmd({"network": "local", "network_ports": [P["tcp4"]]}, tcp); check(11, 'network:"local"+端口白名单 → 白名单内放行', r["ok"])
    r, _, _ = cmd({"network": "local", "network_ports": [1]}, tcp); check(11, 'network:"local"+端口白名单 → 白名单外被拦', eperm(r))
    r, _, _ = cmd({"network": "any"}, tcp); check(11, 'network:"any" → 本机 TCP 放行', r["ok"])
    declared = "~/Documents/luoke-demo"
    os.makedirs(fake_home + "/Documents")
    r, warn, argv = cmd({"write": [declared]}, [PY, PROBES + "/engine_probe.py", "write", fake_home + "/Documents/luoke-demo"])
    check(11, "write:[\"~/Documents/luoke-demo\"] → ~ 被展开并放行该路径（路径本身还不存在也行）", r["ok"] and ("WRITE_0=" + fake_home + "/Documents/luoke-demo") in argv, r["detail"][:80])
    r, _, _ = cmd({"write": [declared]}, [PY, PROBES + "/engine_probe.py", "write", fake_home + "/Documents/other"])
    check(11, "……同目录下别的路径仍被拦", eperm(r))
    r, _, _ = cmd({"microphone": True}, [BUILD + "/sbprobe", "check", "device-microphone"])
    check(11, "microphone:true → device-microphone 放行", r.get("allowed") is True, json.dumps(r))
    r, _, _ = cmd({}, [BUILD + "/sbprobe", "check", "device-microphone"])
    check(11, "不声明 → device-microphone 被拒", r.get("allowed") is False, json.dumps(r))
    _, warn, _ = cmd({"write": ["~"]}, ["/usr/bin/true"])
    check(11, 'write:["~"] → gen_args 给出"整个家目录可写"警告', any("家目录" in x for x in warn), "; ".join(warn)[:100])
    try:
        gen_args.sandbox_command("t-decl", w.engine_dir, w.data_dir, w.tmp_dir, {"network": "lan"})
        check(11, "非法 network 值被拒绝", False)
    except gen_args.PermissionError_ as e:
        check(11, "非法 network 值被拒绝", True, str(e))


# ----------------------------------------------------------------------------- 规则 3：网络
def net_matrix(w, level, eid):
    P = w.ports
    out = {}
    out["tcp 127.0.0.1"] = probe(w, "tcp", "127.0.0.1", P["tcp4"], net=level, engine=eid)
    out["tcp ::1"] = probe(w, "tcp", "::1", P["tcp6"], net=level, engine=eid) if "tcp6" in P else None
    out["tcp localhost"] = probe(w, "tcp", "localhost", P["tcp4"], net=level, engine=eid)
    out["udp 127.0.0.1"] = probe(w, "udp", "127.0.0.1", P["udp4"], net=level, engine=eid)
    out["unix socket"] = probe(w, "unix", w.sock, net=level, engine=eid)
    out["listen 127.0.0.1"] = probe(w, "listen", "127.0.0.1", net=level, engine=eid)
    out["listen ::1"] = probe(w, "listen", "::1", net=level, engine=eid)
    out["dns localhost"] = probe(w, "dns", "localhost", net=level, engine=eid)
    out["mDNSResponder socket"] = probe(w, "dns-socket", net=level, engine=eid)
    out["swift URLSession 127.0.0.1"] = pj(run_sb(w, [BUILD + "/fprobe", "fetch", "http://127.0.0.1:%d/" % P["tcp4"]], net=level, engine=eid))
    out["swift URLSession localhost"] = pj(run_sb(w, [BUILD + "/fprobe", "fetch", "http://localhost:%d/" % P["tcp4"]], net=level, engine=eid))
    return out


def t_network(w):
    section("规则 3  网络三档（none / local / any），本机监听器 + 外部目标 1.1.1.1:443")
    P = w.ports
    expect = {  # 档位 -> 各探测是否应成功
        "none":  {"tcp 127.0.0.1": 0, "tcp ::1": 0, "tcp localhost": 0, "udp 127.0.0.1": 0, "unix socket": 0, "listen 127.0.0.1": 0, "listen ::1": 0,
                  "dns localhost": 1, "mDNSResponder socket": 0, "swift URLSession 127.0.0.1": 0, "swift URLSession localhost": 0},
        "local": {"tcp 127.0.0.1": 1, "tcp ::1": 1, "tcp localhost": 1, "udp 127.0.0.1": 1, "unix socket": 0, "listen 127.0.0.1": 1, "listen ::1": 1,
                  "dns localhost": 1, "mDNSResponder socket": 0, "swift URLSession 127.0.0.1": 1, "swift URLSession localhost": 0},
        "any":   {"tcp 127.0.0.1": 1, "tcp ::1": 1, "tcp localhost": 1, "udp 127.0.0.1": 1, "unix socket": 1, "listen 127.0.0.1": 1, "listen ::1": 1,
                  "dns localhost": 1, "mDNSResponder socket": 1, "swift URLSession 127.0.0.1": 1, "swift URLSession localhost": 1},
    }
    for level in ("none", "local", "any"):
        eid = "t-net-" + level
        t0 = time.time()
        res = net_matrix(w, level, eid)
        for name, r in res.items():
            if r is None:
                continue
            want = expect[level][name]
            note = ""
            if level == "local" and name == "swift URLSession localhost":
                note = "（已知限制：CFNetwork 解析主机名走 mDNSResponder，'local' 档不放 → 请用 127.0.0.1 字面量）"
            if level == "none" and name == "dns localhost":
                note = "（getaddrinfo('localhost') 靠 /etc/hosts，不走网络，none 档也能解析）"
            if level == "local" and name == "unix socket":
                note = "（unix domain socket 在 local 档不放行：见 README 的取舍）"
            check(3, "[%s] %s → %s%s" % (level, name, "应成功" if want else "应被拦", note), bool(r["ok"]) == bool(want), r["detail"][:110])
        # 外部目标
        if level != "any":
            r = probe(w, "connect", "1.1.1.1", 443, net=level, engine=eid)
            check(3, "[%s] 外部 TCP 1.1.1.1:443 被拦（connect 之前就 EPERM，没有数据包发出）" % level, eperm(r), r["detail"][:100])
            t_dns = time.time()
            r = probe(w, "dns", "example.com", net=level, engine=eid)
            t_dns = time.time() - t_dns
            check(3, "[%s] DNS 解析外部域名立刻失败（无 DNS 外泄通道；用时 %.2f s 含进程启动，不会卡住引擎）" % (level, t_dns), not r["ok"] and t_dns < 3, r["detail"][:100])
        else:
            if NO_EXTERNAL:
                unverified(3, "[any] 外部 TCP 1.1.1.1:443 放行", "LUOKE_SBX_NO_EXTERNAL=1，跳过真实外部连接")
            else:
                r = probe(w, "connect", "1.1.1.1", 443, net=level, engine=eid)   # 全套件里唯一一次真实外部连接：只握手、不发载荷
                allowed = not eperm(r)
                check(3, "[any] 外部 TCP 1.1.1.1:443 不再被沙盒拦（真实 connect 一次，只握手不发数据）", allowed, r["detail"][:100])
        time.sleep(1.2)
        ev = events(eid, t0)
        if level == "none":
            check(3, "[none] 拒绝都被记录为 network-* 并带标签 network", len(ev) >= 5 and any(e["op"].startswith("network-outbound") for e in ev),
                  "%d 条; 例: %s" % (len(ev), ", ".join(sorted({e["op"] + " " + e["detail"][:28] for e in ev}))[:200]))
    # --- local 不放行非回环地址
    ip = lan_ip()
    if ip and "tcp4_any" in P:
        r = probe(w, "tcp", ip, P["tcp4_any"], net="local", engine="t-net-local")
        info(3, "[local] 连本机自己的局域网地址 %s ok=%s：Seatbelt 的 \"localhost\" 指'本机的任何地址'，不止回环；对别的机器的地址仍是 remote，被拦" % (ip, r["ok"]), r["detail"][:100])
        r = probe(w, "tcp", ip, P["tcp4_any"], net="none", engine="t-net-none")
        check(3, "[none] 连本机局域网地址被拦", eperm(r))
    else:
        unverified(3, "[local] 局域网地址被拦", "找不到 en0/en1 的 IP 或监听器未能绑 0.0.0.0")
    r = probe(w, "tcp", "0.0.0.0", P.get("tcp4_any", P["tcp4"]), net="local", engine="t-net-local")
    info(3, "[local] 连 0.0.0.0（内核会当成本机）ok=%s" % r["ok"], r["detail"][:100])
    # --- 本机端口白名单（可选，NET=local + LOCAL_PORT_n）
    eid = "t-net-ports"
    r = probe(w, "tcp", "127.0.0.1", P["tcp4"], net="local", local_ports=[P["tcp4"]], engine=eid)
    check(3, "[local+端口白名单] 白名单内的端口可连", r["ok"], r["detail"][:90])
    if "tcp6" in P:
        r = probe(w, "tcp", "::1", P["tcp6"], net="local", local_ports=[P["tcp4"]], engine=eid)
        check(3, "[local+端口白名单] 白名单外的本机端口被拦（防止借本地代理等服务外传）", eperm(r), r["detail"][:90])
    r = probe(w, "udp", "127.0.0.1", P["udp4"], net="local", local_ports=[P["tcp4"]], engine=eid)
    check(3, "[local+端口白名单] 白名单外的 UDP 端口被拦", eperm(r), r["detail"][:90])
    r = pj(run_sb(w, [BUILD + "/fprobe", "fetch", "http://127.0.0.1:%d/" % P["tcp4"]], net="local", local_ports=[P["tcp4"]], engine=eid))
    check(3, "[local+端口白名单] Swift URLSession 同样遵守", r["ok"], r["detail"][:90])
    # --- TLS 信任评估路径（本机自签 HTTPS，不产生外部流量）
    tls_check(w)


def tls_check(w):
    """any 档下 Swift URLSession 能走完 TLS 握手 + 系统信任评估（自签证书 → -1202，和沙盒外报同样的错）。"""
    key = w.W + "/tls.key"
    crt = w.W + "/tls.crt"
    r = subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt, "-days", "2", "-subj", "/CN=localhost"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        unverified(3, "[any] TLS 信任评估", "openssl 生成自签证书失败")
        return
    code = ("import http.server, ssl, sys\n"
            "class H(http.server.BaseHTTPRequestHandler):\n"
            "    def do_GET(self): self.send_response(200); self.send_header('Content-Length','2'); self.end_headers(); self.wfile.write(b'ok')\n"
            "    def log_message(self,*a): pass\n"
            "s=http.server.HTTPServer(('127.0.0.1',0),H); c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(%r,%r)\n"
            "s.socket=c.wrap_socket(s.socket,server_side=True); print(s.server_address[1],flush=True); s.serve_forever()\n" % (crt, key))
    srv = subprocess.Popen([PY, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        port = int(srv.stdout.readline())
        url = "https://127.0.0.1:%d/" % port
        base = unsandboxed([BUILD + "/fprobe", "fetch", url])
        rb = json.loads(base.stdout.strip().splitlines()[-1])
        r_any = pj(run_sb(w, [BUILD + "/fprobe", "fetch", url], net="any", engine="t-net-tls"))
        code_of = lambda d: (re.search(r"Code=(-?\d+)", d) or [None, "?"])[1]
        check(3, "[any] Swift URLSession 的 TLS 握手+信任评估路径可用（自签证书：沙盒内外同为 NSURLError %s）" % code_of(rb["detail"]),
              code_of(r_any["detail"]) == code_of(rb["detail"]), "沙盒外=%s 沙盒内=%s" % (code_of(rb["detail"]), code_of(r_any["detail"])))
    finally:
        srv.terminate()


# ----------------------------------------------------------------------------- 规则 4：子进程
def t_children(w):
    section("规则 4  子进程继承沙盒（curl / nc / python 子进程 / 双 fork 脱离的孙进程）")
    P = w.ports
    for level, want in (("none", False), ("local", True)):
        eid = "t-child-" + level
        for tool in ("curl", "nc", "python"):
            r = probe(w, "run-net", tool, "127.0.0.1", P["tcp4"], net=level, engine=eid)
            check(4, "[%s] 引擎的子进程 %s 连本机监听器 → %s" % (level, tool, "放行" if want else "被拦"), bool(r["ok"]) == want, r["detail"][:110])
        r = probe(w, "daemon-net", "127.0.0.1", P["tcp4"], w.data_dir + "/daemon-%s.out" % level, net=level, engine=eid)
        check(4, "[%s] 双 fork + setsid 的孙进程连本机 → %s" % (level, "放行" if want else "被拦"), bool(r["ok"]) == want, r["detail"][:110])
    # curl/nc 对外部目标（none 档）：被拦在 connect 前
    for tool, args in (("/usr/bin/curl", ["-sS", "-m", "3", "http://1.1.1.1:80/"]), ("/usr/bin/nc", ["-z", "-w", "2", "1.1.1.1", "443"])):
        cp = run_sb(w, [tool] + args, net="none", engine="t-child-none")
        check(4, "[none] 子进程 %s 连外部 1.1.1.1 失败 (rc=%d)" % (os.path.basename(tool), cp.returncode), cp.returncode != 0, (cp.stderr or "").strip()[:100])
    # 子进程写文件同样受限
    marker = HOME + "/.luoke-sbx-child-%d" % os.getpid()
    cp = run_sb(w, ["/bin/sh", "-c", "echo x > '%s'" % marker], engine="t-child-none")
    check(4, "子进程 sh 往 ~ 写文件被拒", cp.returncode != 0 and not os.path.exists(marker), (cp.stderr or "").strip()[:100])
    cp = run_sb(w, ["/bin/sh", "-c", "echo x > '%s/child.txt'" % w.data_dir], engine="t-child-none")
    check(4, "子进程 sh 往 DATA_DIR 写文件可以", cp.returncode == 0)
    if os.path.exists(marker):
        os.unlink(marker)


# ----------------------------------------------------------------------------- 规则 5：麦克风 / 摄像头
def lookup_unsandboxed(names):
    cp = unsandboxed([BUILD + "/sbprobe", "lookup"] + names)
    return {json.loads(l)["name"]: json.loads(l)["kr"] for l in cp.stdout.strip().splitlines()}


def lookup_sb(w, names, **opts):
    cp = run_sb(w, [BUILD + "/sbprobe", "lookup"] + names, **opts)
    return {json.loads(l)["name"]: json.loads(l)["kr"] for l in cp.stdout.strip().splitlines() if l.startswith("{")}


def sbcheck(w, *args, **opts):
    r = pj(run_sb(w, [BUILD + "/sbprobe", "check"] + list(args), **opts))
    return r.get("rc")


def t_devices(w):
    section("规则 5  麦克风 / 摄像头（只做策略求值 + Mach 服务可达性；不打开设备）")
    for mic, cam in ((1, 0), (0, 1), (1, 1)):
        cp = run_sb(w, [PY, "-c", "print(1)"], mic=mic, cam=cam)
        check(5, "profile 带 MIC=%d CAM=%d 能编译并运行" % (mic, cam), cp.returncode == 0 and cp.stdout.strip() == "1", (cp.stderr or "")[:100])
    d = sbcheck(w, "device-microphone"); check(5, "默认：sandbox_check(device-microphone) = 拒", d == 1, "rc=%s" % d)
    d = sbcheck(w, "device-camera"); check(5, "默认：sandbox_check(device-camera) = 拒", d == 1, "rc=%s" % d)
    d = sbcheck(w, "device-microphone", mic=1); check(5, "MIC=1：device-microphone = 放行", d == 0, "rc=%s" % d)
    d = sbcheck(w, "device-camera", mic=1); check(5, "MIC=1 不会连带放行 device-camera", d == 1, "rc=%s" % d)
    d = sbcheck(w, "device-camera", cam=1); check(5, "CAM=1：device-camera = 放行", d == 0, "rc=%s" % d)
    d = sbcheck(w, "device-microphone", cam=1); check(5, "CAM=1 不会连带放行 device-microphone", d == 1, "rc=%s" % d)
    audio = ["com.apple.audio.audiohald", "com.apple.audio.coreaudiod", "com.apple.audio.AudioComponentRegistrar"]
    cams = ["com.apple.cmio.registerassistantservice", "com.apple.appleh13camerad", "com.apple.appleh16camerad", "com.apple.applecamerad"]
    base = lookup_unsandboxed(audio + cams)
    exist = [n for n, kr in base.items() if kr == 0]
    info(5, "本机上存在的音/视频 Mach 服务（沙盒外 bootstrap_look_up 成功）", ", ".join(exist))
    t0 = time.time()
    got = lookup_sb(w, exist, engine="t-dev")
    check(5, "默认：音/视频服务 lookup 全部被沙盒拒绝 (kr=1100)", all(got.get(n) == 1100 for n in exist), json.dumps(got)[:200])
    got_m = lookup_sb(w, [n for n in exist if n in audio], mic=1, engine="t-dev-mic")
    check(5, "MIC=1：音频服务可达 (kr=0)", all(v == 0 for v in got_m.values()) and bool(got_m), json.dumps(got_m)[:200])
    got_c = lookup_sb(w, [n for n in exist if n in cams], cam=1, engine="t-dev-cam")
    check(5, "CAM=1：相机服务可达 (kr=0)", all(v == 0 for v in got_c.values()) and bool(got_c), json.dumps(got_c)[:200])
    got_x = lookup_sb(w, [n for n in exist if n in audio], cam=1, engine="t-dev-x")
    check(5, "CAM=1 不连带放行音频服务", all(v == 1100 for v in got_x.values()) and bool(got_x), json.dumps(got_x)[:200])
    ev = wait_events("t-dev", t0, timeout=5, cls="microphone")
    ev2 = events("t-dev", t0, cls="camera")
    check(5, "被拒的音/视频 lookup 在日志里带 microphone / camera 标签", bool(ev) and bool(ev2),
          "mic: %s | cam: %s" % (ev[0]["detail"] if ev else "-", ev2[0]["detail"] if ev2 else "-"))
    unverified(5, "真正打开麦克风/摄像头（AudioUnit / AVCaptureSession）", "会触发 TCC 弹窗，按安全约束没做。deny 生效只有'策略求值 + Mach 服务不可达'两层证据；放行档的服务清单取自 Apple 的 appsandbox-common.sb，未用真实录音引擎验证")


# ----------------------------------------------------------------------------- 规则 6：屏幕录制
def t_screen(w):
    section("规则 6  屏幕录制（只读预检 + Mach 服务可达性；不抓屏）")
    names = ["com.apple.replayd", "com.apple.windowserver.active", "com.apple.CARenderServer", "com.apple.tccd", "com.apple.tccd.system", "com.apple.screencapture.interactive"]
    base = lookup_unsandboxed(names)
    exist = [n for n, kr in base.items() if kr == 0]
    info(6, "沙盒外可达的抓屏相关 Mach 服务", ", ".join(exist))
    t0 = time.time()
    got = lookup_sb(w, exist, engine="t-scr")
    check(6, "默认：这些服务 lookup 全被沙盒拒 (kr=1100)", all(got.get(n) == 1100 for n in exist), json.dumps(got)[:240])
    got2 = lookup_sb(w, exist, screen=1, engine="t-scr2")
    check(6, "SCREEN=1：服务可达", all(got2.get(n) == 0 for n in exist if n != "com.apple.screencapture.interactive"), json.dumps(got2)[:240])
    ev = wait_events("t-scr", t0, timeout=5, cls="screen")
    check(6, "被拒的 lookup 在日志里带 screen 标签", bool(ev), ev[0]["detail"] if ev else "-")
    pf0 = pj(unsandboxed([BUILD + "/sysprobe", "screen-preflight"]))
    pf1 = pj(run_sb(w, [BUILD + "/sysprobe", "screen-preflight"], engine="t-scr"))
    pf2 = pj(run_sb(w, [BUILD + "/sysprobe", "screen-preflight"], screen=1, engine="t-scr2"))
    info(6, "CGPreflightScreenCaptureAccess：沙盒外=%s  默认沙盒内=%s  SCREEN=1 沙盒内=%s" % (pf0["detail"], pf1["detail"], pf2["detail"]),
         "沙盒外为 true 说明本机这条进程链(Claude/终端)已有屏幕录制授权：正是 ADR 0005 担心的'子进程继承壳的 TCC'，此时只有 Seatbelt 能拦")
    check(6, "默认沙盒内预检读不到授权（tccd 不可达 → false）", pf1["detail"] == "false")
    if pf0["detail"] == "true":   # 沙盒外已有授权 → 窗口列表 API 不会弹窗，可做三方对照
        w0 = pj(unsandboxed([BUILD + "/sysprobe", "window-count"]))
        w1 = pj(run_sb(w, [BUILD + "/sysprobe", "window-count", "force"], engine="t-scr"))
        w2 = pj(run_sb(w, [BUILD + "/sysprobe", "window-count", "force"], screen=1, engine="t-scr2"))
        check(6, "WindowServer 窗口枚举 CGWindowListCopyWindowInfo（只数个数）：沙盒外 %s ｜ 默认沙盒内 %s ｜ SCREEN=1 沙盒内 %s" % (w0["detail"], w1["detail"], w2["detail"]),
              w0["ok"] and not w1["ok"] and w2["ok"], "默认被拒 = 连 WindowServer 的连接都建不起来，更别说抓屏；声明后恢复")
        ev = wait_events("t-scr", time.time() - 8, timeout=3, sub="windowserver")
        check(6, "窗口枚举被拒在日志里记为 mach-lookup com.apple.windowserver.active + screen 标签", bool(ev), ev[0]["suggest"] if ev else "")
    else:
        unverified(6, "WindowServer 窗口枚举三方对照", "沙盒外没有屏幕录制授权，为避免任何弹窗风险跳过")
    unverified(6, "真正抓屏被拦（CGWindowListCreateImage / CGDisplayStream / ScreenCaptureKit / screencapture）", "会读到/截到用户屏幕且可能弹窗，按安全约束没做；结论基于'抓屏所需 Mach 服务 + TCC 服务不可达'")


# ----------------------------------------------------------------------------- 规则 7 / 8：间接外发、剪贴板
def t_exfil(w):
    section("规则 7  间接外发：LaunchServices / AppleEvent / exec（只读查询 + 拒绝日志，不真正打开任何东西）")
    eid = "t-exf"
    t0 = time.time()
    # exec
    for exe, args in (("/usr/bin/open", []), ("/usr/bin/osascript", ["-h"])):
        r = probe(w, "exec", exe, *args, engine=eid)
        check(7, "exec %s 被拒（沙盒内起不来）" % exe, not r["ok"], r["detail"][:100])
    # 沙盒外对照：用法输出无副作用，证明工具本身是好的
    cp = unsandboxed(["/usr/bin/open"])
    info(7, "对照：沙盒外 /usr/bin/open（无参数，只打印用法）rc=%d" % cp.returncode)
    # LaunchServices 只读查询
    base = pj(unsandboxed([BUILD + "/sysprobe", "ls-default-app"]))
    ins = pj(run_sb(w, [BUILD + "/sysprobe", "ls-default-app"], engine=eid))
    check(7, "LSCopyDefaultApplicationURLForURL：沙盒外成功(%s)，沙盒内失败" % os.path.basename(base["detail"]), base["ok"] and not ins["ok"], ins["detail"][:120])
    base = pj(unsandboxed([BUILD + "/sysprobe", "ws-url-for"]))
    ins = pj(run_sb(w, [BUILD + "/sysprobe", "ws-url-for"], engine=eid))
    check(7, "NSWorkspace.urlForApplication(toOpen:)：沙盒外成功，沙盒内 nil", base["ok"] and not ins["ok"], ins["detail"][:120])
    b = pj(unsandboxed([BUILD + "/fprobe", "ls-dependent"]))
    s = pj(run_sb(w, [BUILD + "/fprobe", "ls-dependent"], engine=eid))
    info(7, "封掉 LaunchServices 后 Foundation 里坏掉的东西（依赖 LS 数据库的 UTType / 资源属性）",
         "沙盒外: " + b["detail"][:230] + " ｜ 沙盒内: " + s["detail"][:230])
    # 服务可达性
    names = ["com.apple.coreservices.launchservicesd", "com.apple.lsd.open", "com.apple.coreservices.appleevents", "com.apple.pasteboard.1",
             "com.apple.distributed_notifications@Uv3", "com.apple.coreservices.quarantine-resolver"]
    base = lookup_unsandboxed(names)
    exist = [n for n, kr in base.items() if kr == 0]
    got = lookup_sb(w, exist, engine=eid)
    check(7, "沙盒外可达的 LaunchServices / AppleEvent / 剪贴板 / 分布式通知服务，沙盒内全部 kr=1100", bool(exist) and all(got.get(n) == 1100 for n in exist), "%d 个: %s" % (len(exist), ", ".join(n.replace("com.apple.", "") for n in exist)))
    # SBPL 专用操作
    for op, extra in (("lsopen", []), ("appleevent-send", []), ("appleevent-send", ["appleevent", "com.apple.finder"]), ("job-creation", []), ("hid-control", [])):
        d = sbcheck(w, op, *extra, engine=eid)
        check(7, "sandbox_check(%s %s) = 拒" % (op, " ".join(extra)), d == 1, "rc=%s" % d)
    # launchd：复制一份 launchctl（绕过按路径的 exec 拒绝），真试一次 submit（执行 /usr/bin/true；若竟然成功则立刻 remove）
    # 复制出来的平台二进制会被 AMFI 直接 SIGKILL（launch constraints），所以改用"去掉 launchctl 路径拒绝的 profile 变体"
    # 来单独检验底下那一层：真试一次 launchctl submit（作业只是 /usr/bin/true；若竟然成功则立刻 remove）
    variant = w.W + "/variant-no-exec-deny.sb"
    open(variant, "w").write(open(PROFILE).read().replace('(literal "/bin/launchctl")', '(literal "/nonexistent")'))
    label = "com.luoke.sbxtest.%d" % os.getpid()
    cp = run_sb(w, ["/bin/launchctl", "submit", "-l", label, "--", "/usr/bin/true"], engine=eid, profile=variant)
    created = subprocess.run(["/bin/launchctl", "list", label], capture_output=True, text=True).returncode == 0
    if created:
        subprocess.run(["/bin/launchctl", "remove", label], capture_output=True)
    check(7, "沙盒内（去掉 exec 路径拒绝的变体）launchctl submit 创建 launchd 作业被拒——经典的逃出沙盒路径", cp.returncode != 0 and not created,
          "rc=%d %s" % (cp.returncode, (cp.stderr or cp.stdout).strip()[:100]))
    cp = run_sb(w, ["/bin/launchctl", "print", "gui/%d" % os.getuid()], engine=eid, profile=variant)
    info(7, "沙盒内 launchctl print gui/UID（只读）rc=%d：对 launchd 的只读查询不受 mach-lookup 规则管，会泄露已装 LaunchAgents / 运行中服务的列表（信息泄露；无法借此外发或执行）" % cp.returncode)
    # 日志
    time.sleep(1.5)
    ev = events(eid, t0, cls="exfil")
    ops = sorted({e["op"] + " " + e["detail"].replace("com.apple.", "")[:34] for e in ev})
    check(7, "上述拒绝在日志里带 exfil 标签", len(ev) >= 3, "%d 条: %s" % (len(ev), "; ".join(ops)[:260]))
    xs = [e for e in ev if e["op"].startswith("process-exec")]
    info(7, "process-exec 被拒%s出现在日志里" % ("会" if xs else "不会"), xs[0]["detail"] if xs else "exec 拒绝只体现在 execvp 的 EPERM 上（sandbox-exec 在 fork 前的 exec 阶段拦截，不写 Sandbox 日志）")
    job = [e for e in events(eid, t0) if e["op"] in ("job-creation", "lsopen", "appleevent-send", "device-microphone", "device-camera")]
    info(7, "由系统守护进程代查的操作（job-creation/lsopen/appleevent-send/device-*）%s出现在 Sandbox 日志里" % ("会" if job else "未"), "; ".join(e["op"] for e in job)[:100] or "只能靠引擎收到的错误码/退出状态发现")

    section("规则 8  剪贴板（只读 changeCount，不读内容）")
    b = pj(unsandboxed([BUILD + "/sysprobe", "pasteboard-count"]))
    s = pj(run_sb(w, [BUILD + "/sysprobe", "pasteboard-count"], engine="t-pb"))
    info(8, "NSPasteboard.general.changeCount：沙盒外 %s ，沙盒内 %s（0 = 取不到）" % (b["detail"], s["detail"]))
    got = lookup_sb(w, ["com.apple.pasteboard.1"], engine="t-pb")
    check(8, "本模板下剪贴板服务 com.apple.pasteboard.1 不可达 (kr=1100)，即剪贴板不可读", got.get("com.apple.pasteboard.1") == 1100, json.dumps(got))
    info(8, "在 '(allow default) + 定向 deny' 型 profile 下该服务是可达的：sandbox_check(mach-lookup com.apple.pasteboard.1) 对照",
         "allow-default: rc=%s" % allow_default_check(w, "mach-lookup", "global", "com.apple.pasteboard.1"))


def allow_default_check(w, *args):
    p = w.W + "/allowdef.sb"
    open(p, "w").write("(version 1)\n(allow default)\n")
    cp = subprocess.run([SANDBOX_EXEC, "-f", p, BUILD + "/sbprobe", "check"] + list(args), capture_output=True, text=True)
    try:
        return json.loads(cp.stdout.strip().splitlines()[-1])["rc"]
    except Exception:
        return "?"


# ----------------------------------------------------------------------------- 规则 9：违规上报
def t_reporting(w, mon_factory):
    section("规则 9  违规上报：log stream 的字段、延迟、归属")
    # (a) 冷启动：新开一个 log stream，同时连续不断地触发金丝雀拒绝（每个探针记下发起时间）。
    #     "被收到的最早一只金丝雀的发起时间 - Popen 时间" = log stream 实际开始订阅所需的时间
    got = []
    m = mon_factory(lambda d: got.append(d) if d["engine"] == "t-canary" else None)
    t_start = time.time()
    m.start()
    attempts = []
    end = t_start + 15
    while time.time() < end and not got:
        cp = run_sb(w, [PY, PROBES + "/engine_probe.py", "write", w.outside + "/canary"], engine="t-canary")
        attempts.append(pj(cp).get("t"))
        time.sleep(0.02)
    time.sleep(0.5)
    m.stop()
    check(9, "新起的 log stream 能收到拒绝", bool(got), "共发出 %d 只金丝雀" % len(attempts))
    if got:
        # 找最早被收到的金丝雀：事件 log_ts 最接近的那次发起
        lt = min(parse_log_ts(g["log_ts"]) or 1e18 for g in got)
        first_seen_attempt = min(a for a in attempts if a is not None and abs(a - lt) < 0.5)
        info(9, "log stream 冷启动：Popen 后 %.2f s 起发出的拒绝就能收到（前 %d 只金丝雀丢了）；首条事件在 Popen 后 %.2f s 到达" %
             (first_seen_attempt - t_start, sum(1 for a in attempts if a is not None and a < first_seen_attempt - 0.05), got[0]["recv_ts"] - t_start))
    # log stream 常驻开销
    m2 = DenialMonitor(lambda d: None)
    m2.start()
    time.sleep(6)
    cpu = subprocess.run(["/bin/ps", "-o", "%cpu=,rss=,time=", "-p", str(m2.proc.pid)], capture_output=True, text=True).stdout.strip()
    m2.stop()
    info(9, "常驻一个 log stream 的开销（空闲 6 s 后 ps: %cpu / rss KB / cputime）", cpu)
    # (b) 稳态延迟：10 次
    lat_recv, lat_log = [], []
    for i in range(10):
        before = len([e for e in EVENTS if e["engine"] == "t-lat"])
        cp = run_sb(w, [PY, PROBES + "/engine_probe.py", "write", w.outside + "/lat%d" % i], engine="t-lat")
        r = pj(cp)
        t_act = r.get("t", time.time())    # 探针在发起被拒动作之前记下的时间
        end = time.time() + 5
        ev = None
        while time.time() < end:
            cur = events("t-lat", t_act - 0.5, op="file-write", sub="lat%d" % i)
            if cur:
                ev = cur[0]
                break
            time.sleep(0.01)
        if ev:
            lat_recv.append(ev["recv_ts"] - t_act)
            lt = parse_log_ts(ev["log_ts"])
            if lt:
                lat_log.append(lt - t_act)
    check(9, "稳态下 10 次被拒全部收到", len(lat_recv) == 10, "收到 %d/10" % len(lat_recv))
    if lat_recv:
        info(9, "稳态延迟（被拒动作发起 → 壳收到事件）: 中位 %.2f ms, 最大 %.2f ms；其中 内核时间戳 - 动作发起 中位 %.2f ms" %
             (statistics.median(lat_recv) * 1000, max(lat_recv) * 1000, statistics.median(lat_log) * 1000 if lat_log else float("nan")))
    # (c) 字段与归属
    cp = run_sb(w, [PY, PROBES + "/engine_probe.py", "write", w.outside + "/fields"], engine="t-fields")
    r = pj(cp)
    ev = wait_events("t-fields", r.get("t", time.time()) - 1, timeout=5, op="file-write")
    if ev:
        e = ev[0]
        check(9, "事件含 引擎id / pid / 进程名 / 操作 / 路径 / 标签 / 日志时间戳", e["engine"] == "t-fields" and e["pid"] > 0 and e["proc"] and e["detail"] == w.outside + "/fields" and e["tag_text"] == "write" and e["log_ts"],
              "pid=%s proc=%s op=%s detail=%s tag=%s" % (e["pid"], e["proc"], e["op"], e["detail"], e["tag_text"]))
        info(9, "壳据此生成的提示", "引擎 t-fields 被拦：%s %s → %s" % (e["op"], e["detail"], e["suggest"]))
        check(9, "pid 就是被拦的那个进程（和探针自报的 pid 一致）", e["pid"] == r.get("pid"), "event pid=%s probe pid=%s" % (e["pid"], r.get("pid")))
    else:
        check(9, "事件含完整字段", False, "没收到事件")
    # 网络事件的地址字段
    t0 = time.time()
    probe(w, "tcp", "127.0.0.1", w.ports["tcp4"], net="none", engine="t-fields")
    probe(w, "tcp", "1.1.1.1", 443, net="none", engine="t-fields")
    probe(w, "udp", "127.0.0.1", w.ports["udp4"], net="none", engine="t-fields")
    probe(w, "unix", w.sock, net="none", engine="t-fields")
    time.sleep(2.0)
    nev = events("t-fields", t0, op="network")
    info(9, "network 拒绝事件里的目标写法", "; ".join(sorted({"%s %s" % (e["op"], e["detail"]) for e in nev})))
    ok_addr = any(":443" in e["detail"] for e in nev) and any(e["detail"] == w.sock for e in nev)
    check(9, "网络事件带端口 / unix socket 路径（地址里的主机名被日志脱敏成 '*'）", ok_addr, "")
    # 子进程归属
    t0 = time.time()
    probe(w, "run-net", "curl", "127.0.0.1", w.ports["tcp4"], net="none", engine="t-child")
    ev = wait_events("t-child", t0, timeout=5, op="network")
    check(9, "子进程(curl)的拒绝同样带本引擎标签（不需要追踪进程树）", any(e["proc"] == "curl" for e in ev), ", ".join(sorted({e["proc"] for e in ev})))
    # 重复折叠
    t0 = time.time()
    run_sb(w, [PY, "-c", "\nfor i in range(60):\n    try: open(%r,'w')\n    except OSError: pass\n" % (w.outside + "/burst")], engine="t-burst")
    time.sleep(2.0)
    ev = events("t-burst", t0)
    plain = [e for e in ev if e["dups"] == 0]
    dups = sum(e["dups"] for e in ev)
    info(9, "60 次相同拒绝的折叠：收到 %d 条独立事件 + 折叠行合计 dups=%d（内核对相同拒绝限流，壳只需'每种操作首次通知'，正好够用）" % (len(plain), dups))
    check(9, "每种被拦的操作至少收到 1 条事件（'只在第一次通知'可行）", len(ev) >= 1)
    # 未标签的拒绝不会泄露到壳的订阅里
    info(9, "订阅谓词", 'sender == "Sandbox" AND eventMessage CONTAINS "LUOKE["（只收带标签的，系统里其它进程的上千条无关拒绝被过滤）')


# ----------------------------------------------------------------------------- 规则 10：开销
def t_overhead(w):
    section("规则 10  启动开销（中位数，每组 15 次交替运行）")
    def timeit(cmd, n=15):
        ts = []
        for _ in range(n):
            t = time.perf_counter()
            subprocess.run(cmd, capture_output=True, cwd=w.engine_dir, env=engine_env(w))
            ts.append((time.perf_counter() - t) * 1000)
        return ts
    sbx = sb_args(w, engine="t-ovh")
    pairs = {
        "python3 -c pass": ([PY, "-c", "pass"], sbx + [PY, "-c", "pass"]),
        "/usr/bin/true": (["/usr/bin/true"], sbx + ["/usr/bin/true"]),
        "Swift fprobe (basic)": ([BUILD + "/fprobe", "basic"], sbx + [BUILD + "/fprobe", "basic"]),
    }
    for name, (plain, boxed) in pairs.items():
        a, b = [], []
        for _ in range(3):  # warm
            timeit(plain, 1); timeit(boxed, 1)
        for i in range(15):
            a += timeit(plain, 1); b += timeit(boxed, 1)
        ma, mb = statistics.median(a), statistics.median(b)
        info(10, "%-22s 无沙盒 %.1f ms | sandbox-exec %.1f ms | +%.1f ms (p90 %.1f→%.1f)" % (name, ma, mb, mb - ma, sorted(a)[int(len(a) * .9) - 1], sorted(b)[int(len(b) * .9) - 1]))
        if name == "python3 -c pass":
            check(10, "sandbox-exec 带来的额外启动时间 < 50 ms（中位数）", mb - ma < 50, "+%.1f ms" % (mb - ma))
    # 重一点的 Python 启动：冷（无字节码缓存）vs 热（PYTHONPYCACHEPREFIX=DATA_DIR/pycache）
    heavy = [PY, "-c", "import asyncio, json, sqlite3, ssl, urllib.request, multiprocessing, email, http.client"]
    nocache = {"PYTHONPYCACHEPREFIX": w.W + "/no-such-dir"}    # 读不到任何缓存 = 全新机器上的最坏情况
    pfx = {"PYTHONPYCACHEPREFIX": w.data_dir + "/pycache"}
    def med(cmd, env, n=7):
        ts = []
        for _ in range(n):
            t = time.perf_counter(); subprocess.run(cmd, capture_output=True, cwd=w.engine_dir, env=env); ts.append((time.perf_counter() - t) * 1000)
        return statistics.median(ts)
    base = med(heavy, engine_env(w))
    cold = med(sbx + heavy, engine_env(w, nocache))
    first = med(sbx + heavy, engine_env(w, {"PYTHONPYCACHEPREFIX": w.data_dir + "/pycache-new"}), n=1)
    med(sbx + heavy, engine_env(w, pfx), n=2)
    warm = med(sbx + heavy, engine_env(w, pfx))
    info(10, "重一点的 import（asyncio/ssl/sqlite3/urllib/…）：无沙盒 %.0f ms ｜ 沙盒+无字节码缓存可读(最坏) %.0f ms ｜ 沙盒+PYTHONPYCACHEPREFIX 首次 %.0f ms → 之后 %.0f ms" % (base, cold, first, warm))


# ----------------------------------------------------------------------------- 其它语言运行时
def t_runtimes(w):
    section("规则 1/2 补充  其它语言的引擎：node(V8 JIT) / bun / ruby / perl / Swift（'任何语言'）")
    js = ("const fs=require('fs');fs.writeFileSync(process.env.LUOKE_IME_DATA+'/n.txt','x');"
          "let h='ok';try{fs.writeFileSync(process.env.HOME+'/.luoke_n','x');h='BAD'}catch(e){h=e.code}"
          "console.log(JSON.stringify({ok:h==='EPERM',detail:'child='+require('child_process').execSync('echo hi').toString().trim()+' home_write='+h}))")
    cases = []
    for name, exe in (("node", "/opt/homebrew/bin/node"), ("node", "/usr/local/bin/node"), ("bun", os.path.expanduser("~/.bun/bin/bun"))):
        if os.path.exists(exe) and name not in [c[0] for c in cases]:
            cases.append((name, [exe, "-e", js] if name == "node" else [exe, "-e", js]))
    cases.append(("ruby", ["/usr/bin/ruby", "-e", "puts '{\"ok\":true,\"detail\":\"' + (1+1).to_s + '\"}'"]))
    cases.append(("perl", ["/usr/bin/perl", "-e", "print '{\"ok\":true,\"detail\":\"' . (1+1) . '\"}'"]))
    for name, cmd in cases:
        t0 = time.time()
        cp = run_sb(w, cmd, engine="t-rt-" + name)
        r = pj(cp)
        time.sleep(1.0)
        ev = [e for e in events("t-rt-" + name, t0) if e["severity"] == "hard" and e["tag_text"] != "write"]
        check(1, "%s 引擎在沙盒里正常运行" % name, r.get("ok"), r.get("detail"))
        if name in ("node", "bun"):
            check(2, "%s：写数据目录成功、写 ~ 被 EPERM" % name, r.get("ok") and os.path.exists(w.data_dir + "/n.txt"), r.get("detail"))
        if ev:
            info(1, "%s 产生额外违规记录" % name, "; ".join("[%s] %s %s" % (e["tag_text"], e["op"], e["detail"][:50]) for e in ev[:4]))
    if not any(c[0] == "node" for c in cases):
        unverified(1, "node 引擎", "本机没有找到 node")
    # Homebrew / python.org 的 Python：字节码缓存写在模块旁边的 __pycache__，不设环境变量就会产生"写"违规
    hb = "/opt/homebrew/bin/python3"
    if os.path.exists(hb):
        mods = w.outside + "/pymods"
        os.makedirs(mods, exist_ok=True)
        open(mods + "/foo_mod.py", "w").write("X = 1\n")
        code = "import sys, json; sys.path.insert(0, %r); import foo_mod; print(json.dumps({'ok': True, 'detail': 'import ok'}))" % mods
        t0 = time.time()
        pj(run_sb(w, [hb, "-c", code], engine="t-hb-a"))
        time.sleep(1.0)
        ev_a = events("t-hb-a", t0)
        t0 = time.time()
        r = pj(run_sb(w, [hb, "-c", code], engine="t-hb-b", env=engine_env(w, {"PYTHONPYCACHEPREFIX": w.data_dir + "/pycache"})))
        time.sleep(1.0)
        ev_b = events("t-hb-b", t0)
        info(2, "Homebrew Python 不设 PYTHONPYCACHEPREFIX 时 import 产生 %d 条 write 记录（监听器归为 soft：%s）" % (len(ev_a), ev_a[0]["severity"] if ev_a else "-"), ev_a[0]["detail"][-60:] if ev_a else "")
        check(2, "设了 PYTHONPYCACHEPREFIX（壳应当总是设）后，Homebrew Python import 无任何违规记录", r["ok"] and not ev_b, "; ".join(e["detail"][-40:] for e in ev_b))


# ----------------------------------------------------------------------------- SBPL 求值顺序（profile.sb 的排布依赖它）
def t_semantics(w):
    section("SBPL 求值顺序（profile.sb 头部注释里写的规则，这里回归验证）")
    d = w.W + "/sem"
    os.makedirs(d + "/sub")
    def case(name, rules, target, want_ok):
        prof = w.W + "/sem.sb"
        open(prof, "w").write("(version 1)\n(allow default)\n" + rules.replace("@D", d))
        cp = subprocess.run([SANDBOX_EXEC, "-f", prof, "/bin/sh", "-c", "echo x > '%s'" % target.replace("@D", d)], capture_output=True, text=True)
        check(11, name, (cp.returncode == 0) == want_ok, "rc=%d" % cp.returncode)
        try:
            os.unlink(target.replace("@D", d))
        except OSError:
            pass
    case("带过滤器的 allow 在前、不带过滤器的 deny 在后 → 仍放行（过滤器规则压过整体缺省）", '(allow file-write* (subpath "@D"))\n(deny file-write*)', "@D/a", True)
    case("带过滤器的 deny 在前、不带过滤器的 allow 在后 → 仍拒绝", '(deny file-write* (subpath "@D"))\n(allow file-write*)', "@D/a", False)
    case("两条都带过滤器：先 allow 父目录、后 deny 子目录 → 子目录被拒（后写的赢）", '(deny file-write*)\n(allow file-write* (subpath "@D"))\n(deny file-write* (subpath "@D/sub"))', "@D/sub/a", False)
    case("两条都带过滤器：先 deny 子目录、后 allow 父目录 → 子目录放行（后写的赢）", '(deny file-write*)\n(deny file-write* (subpath "@D/sub"))\n(allow file-write* (subpath "@D"))', "@D/sub/a", True)


# ----------------------------------------------------------------------------- 对照：以 allow default 为底
def t_naive(w):
    section("对照实验  以 (allow default) 为底 + 定向 deny（设计文档里写的做法）会漏什么")
    naive = w.W + "/naive.sb"
    open(naive, "w").write("""(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write* (subpath (param "DATA_DIR")) (subpath (param "TMP_DIR")))
(allow file-write* (literal "/dev/null") (literal "/dev/dtracehelper") (subpath "/dev/fd"))
(deny device-microphone)
(deny device-camera)
(deny appleevent-send)
(deny lsopen)
(deny process-exec* (literal "/usr/bin/open") (literal "/usr/bin/osascript"))
""")
    names = ["com.apple.pasteboard.1", "com.apple.coreservices.launchservicesd", "com.apple.lsd.open", "com.apple.coreservices.appleevents",
             "com.apple.windowserver.active", "com.apple.replayd", "com.apple.dnssd.service", "com.apple.SystemConfiguration.configd",
             "com.apple.audio.coreaudiod", "com.apple.audio.audiohald", "com.apple.cmio.registerassistantservice", "com.apple.tccd.system"]
    base = lookup_unsandboxed(names)
    exist = [n for n, kr in base.items() if kr == 0]
    got_naive = lookup_sb(w, exist, profile=naive)
    got_ours = lookup_sb(w, exist)
    leaked = [n for n in exist if got_naive.get(n) == 0]
    check(11, "对照：allow-default 型 profile 下这些服务仍可达（泄漏 %d/%d），本模板下 0/%d" % (len(leaked), len(exist), len(exist)),
          len(leaked) > 0 and all(got_ours.get(n) == 1100 for n in exist), "泄漏: " + ", ".join(n.replace("com.apple.", "") for n in leaked))
    b = pj(run_sb(w, [BUILD + "/sysprobe", "ls-default-app"], profile=naive))
    pb = pj(run_sb(w, [BUILD + "/sysprobe", "pasteboard-count"], profile=naive))
    info(11, "allow-default 型 profile 下：LaunchServices 查询 ok=%s（%s）；剪贴板 %s；DNS 服务 dnssd 可达=%s" %
         (b["ok"], os.path.basename(b["detail"]), pb["detail"], got_naive.get("com.apple.dnssd.service") == 0),
         "即：网络/写/麦克风这些'被点名'的操作确实被拦了，但 LaunchServices(借它打开网址)、剪贴板、AppleEvent 服务、DNS 服务(dnssd)、WindowServer/replayd(抓屏)、音视频守护进程仍然可达")


# ----------------------------------------------------------------------------- 工程细节
def t_engineering(w):
    section("工程细节  真实 JSON-lines 引擎往返 / 终止 / 编译失败行为")
    ex = os.path.join(EXAMPLE_ENGINE, "engine.py")
    if os.path.exists(ex):
        full = sb_args(w, engine="t-jsonl") + [PY, ex]
        p = subprocess.Popen(full, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=os.path.dirname(ex), env=engine_env(w), bufsize=1)
        lat = []
        ok = True
        for i in range(20):
            t = time.perf_counter()
            p.stdin.write(json.dumps({"type": "query", "id": i, "input": "nihao"}) + "\n"); p.stdin.flush()
            ans = json.loads(p.stdout.readline())
            lat.append((time.perf_counter() - t) * 1000)
            ok = ok and ans.get("id") == i and ans["candidates"][0]["text"] == "你好"
        p.stdin.close()
        try:
            p.wait(timeout=2)
            exited = True
        except subprocess.TimeoutExpired:
            p.kill(); exited = False
        check(11, "examples/minimal 引擎在沙盒里经 stdin/stdout JSON lines 正常往返，关闭 stdin 后退出", ok and exited,
              "往返中位 %.2f ms; 引擎文件夹是只读的、cwd 不在可写区也没关系" % statistics.median(lat))
    else:
        unverified(11, "examples/minimal 引擎往返", "没找到 " + ex)
    # 终止：sandbox-exec 会 exec 成引擎本身，pid 不变；壳 SIGKILL 进程组能连孙进程一起清掉
    p = subprocess.Popen(sb_args(w, engine="t-kill") + ["/bin/sh", "-c", "sleep 60 & echo $!; wait"], stdout=subprocess.PIPE, text=True, cwd=w.engine_dir, start_new_session=True, env=engine_env(w))
    child = int(p.stdout.readline())
    pid_same = True
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    time.sleep(0.3)
    try:
        os.kill(child, 0)
        alive = True
    except ProcessLookupError:
        alive = False
    check(11, "壳（沙盒外）可以 killpg 整个引擎进程组（含孙进程）", not alive, "child %d alive=%s" % (child, alive))
    # 继承的文件描述符：Seatbelt 只在 open/connect 时检查，已经打开的 fd 不再检查
    target = w.outside + "/inherited-fd.txt"
    fd = os.open(target, os.O_WRONLY | os.O_CREAT, 0o600)
    cp = subprocess.run(sb_args(w, engine="t-fd") + [PY, "-c", "import os,sys; os.write(%d, b'leak')" % fd], capture_output=True, text=True, pass_fds=[fd], cwd=w.engine_dir, env=engine_env(w))
    os.close(fd)
    leaked = os.path.exists(target) and open(target).read() == "leak"
    info(11, "壳传给引擎的额外可写 fd 能被引擎写（leaked=%s）：Seatbelt 不管已经打开的 fd，所以壳 spawn 引擎时必须只传 stdio、其余全部 CLOEXEC" % leaked, (cp.stderr or "")[:80])
    # setuid 二进制：被沙盒化的进程根本 exec 不了（连 (allow default) 都一样），顺带意味着引擎里不能调 ps/top/ping/sudo/su
    cp = run_sb(w, ["/bin/ps", "-p", "1"], engine="t-ps")
    allow_all = w.W + "/allowall.sb"
    open(allow_all, "w").write("(version 1)\n(allow default)\n")
    cp2 = subprocess.run([SANDBOX_EXEC, "-f", allow_all, "/bin/ps", "-p", "1"], capture_output=True, text=True)
    check(11, "setuid 二进制 (/bin/ps) 在沙盒内无法 exec，且这是内核层面的，(allow default) 也一样 → 引擎不能借 setuid 程序提权；代价是引擎里用不了 ps/top/ping",
          cp.returncode != 0 and cp2.returncode != 0, "本模板 rc=%d, allow-default rc=%d: %s" % (cp.returncode, cp2.returncode, (cp.stderr or "").strip()[:80]))
    # 参数缺失
    cp = subprocess.run([SANDBOX_EXEC, "-f", PROFILE, "-D", "ENGINE_ID=x", "/usr/bin/true"], capture_output=True, text=True)
    info(11, "缺少必需参数 (DATA_DIR 等) 时 sandbox-exec 的表现 rc=%d" % cp.returncode, (cp.stderr or "").strip()[:140])


# ----------------------------------------------------------------------------- 主流程
def main():
    print("螺壳输入法 Seatbelt 实验  macOS %s  %s" % (subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(), subprocess.check_output(["uname", "-m"], text=True).strip()))
    build()
    w = World()
    w.start_listener()
    mon = DenialMonitor(on_event)
    mon.start()
    mon.ready.wait(0.1)
    time.sleep(3.0)  # 让 log stream 握手完成
    try:
        t_reads(w)
        t_writes(w)
        t_paths(w)
        t_declarations(w)
        t_network(w)
        t_children(w)
        t_devices(w)
        t_screen(w)
        t_exfil(w)
        t_reporting(w, lambda cb: DenialMonitor(cb))
        t_overhead(w)
        t_runtimes(w)
        t_semantics(w)
        t_naive(w)
        t_engineering(w)
    finally:
        mon.stop()
        w.close()
        for p in (HOME + "/.luoke-sbx-probe-%d" % os.getpid(),):
            if os.path.exists(p):
                os.unlink(p)
    # 汇总
    print("\n" + "=" * 78)
    print("汇总（每条规则：只要有一项 FAIL 即 FAIL）")
    fails = 0
    for rule in sorted(RULE_TITLE):
        rs = [r for r in RESULTS if r[0] == rule]
        if not rs:
            continue
        n_pass = sum(1 for r in rs if r[1] == "PASS")
        n_fail = sum(1 for r in rs if r[1] == "FAIL")
        n_unv = sum(1 for r in rs if r[1] == "UNVERIFIED")
        n_info = sum(1 for r in rs if r[1] == "INFO")
        status = "FAIL" if n_fail else "PASS"
        fails += n_fail
        print("  R%-2d %-4s  %-46s pass=%d fail=%d info=%d unverified=%d" % (rule, status, RULE_TITLE[rule], n_pass, n_fail, n_info, n_unv))
    if fails:
        print("\n失败项:")
        for r in RESULTS:
            if r[1] == "FAIL":
                print("  R%d %s — %s" % (r[0], r[2], r[3]))
    print("\n未验证项 (UNVERIFIED):")
    for r in RESULTS:
        if r[1] == "UNVERIFIED":
            print("  R%d %s — %s" % (r[0], r[2], r[3]))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
