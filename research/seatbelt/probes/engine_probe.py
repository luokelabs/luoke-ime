#!/usr/bin/python3
"""engine_probe: 在沙盒里运行的"假引擎"。每个子命令做一件事，往 stdout 打一行 JSON:
   {"probe": 名字, "ok": 动作是否成功, "detail": 细节}
ok=True 表示"这个动作成功了"（所以被沙盒拦住的探测期望 ok=False）。仅用标准库 (python3 3.9)。"""
import json, os, socket, subprocess, sys, time

def emit(probe, ok, detail="", t=None):
    # t = 动作发起的时间（测延迟用）；缺省为 emit 时刻
    print(json.dumps({"probe": probe, "ok": bool(ok), "detail": str(detail), "t": t if t is not None else time.time(), "pid": os.getpid()}, ensure_ascii=False), flush=True)

def err(e):
    return "%s: %s" % (type(e).__name__, e)

def tcp(host, port, family=0):
    try:
        infos = socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)
        last = None
        for fam, typ, proto, _, addr in infos:
            s = socket.socket(fam, typ, proto); s.settimeout(3)
            try:
                s.connect(addr); s.sendall(b"GET / HTTP/1.0\r\n\r\n")
                data = s.recv(200); s.close()
                return emit("tcp", b"luoke-probe-ok" in data, "%s -> %r" % (addr, data[-20:]))
            except OSError as e:
                last = e; s.close()
        emit("tcp", False, err(last))
    except OSError as e:
        emit("tcp", False, err(e))

def connect_only(host, port):
    """只建立 TCP 连接再立刻关闭，不发任何载荷（用于唯一的一次外部连接）"""
    t = time.time()
    try:
        s = socket.create_connection((host, port), timeout=4); s.close()
        emit("connect", True, "%s:%s connected" % (host, port), t)
    except OSError as e:
        emit("connect", False, err(e), t)

def udp(host, port):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
        s.sendto(b"x", (host, port)); data, _ = s.recvfrom(100)
        emit("udp", b"luoke-probe-ok" in data, data)
    except OSError as e:
        emit("udp", False, err(e))

def unix(path):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(2)
        s.connect(path); s.sendall(b"GET / HTTP/1.0\r\n\r\n"); data = s.recv(200)
        emit("unix", b"luoke-probe-ok" in data, path)
    except OSError as e:
        emit("unix", False, err(e))

def listen(host):
    try:
        fam = socket.AF_INET6 if ":" in host else socket.AF_INET
        s = socket.socket(fam, socket.SOCK_STREAM); s.bind((host, 0)); s.listen(1)
        port = s.getsockname()[1]
        # 自连一次，确认 inbound 也通
        c = socket.socket(fam, socket.SOCK_STREAM); c.settimeout(2); c.connect((host, port)); a, _ = s.accept()
        emit("listen", True, "%s:%d self-connect ok" % (host, port))
    except OSError as e:
        emit("listen", False, err(e))

def dns(name):
    try:
        r = socket.getaddrinfo(name, 80, socket.AF_INET, socket.SOCK_STREAM)
        emit("dns", True, "%s -> %s" % (name, r[0][4][0]))
    except OSError as e:
        emit("dns", False, "%s: %s" % (name, err(e)))

def dns_socket():
    # 只 connect 到 mDNSResponder 的 unix socket（本机 IPC，不产生任何外部流量），然后立刻关闭
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(2)
        s.connect("/var/run/mDNSResponder"); s.close()
        emit("dns-socket", True, "/var/run/mDNSResponder reachable")
    except OSError as e:
        emit("dns-socket", False, err(e))

def wr(path, mode="w"):
    t = time.time()
    try:
        with open(path, mode) as f: f.write("x" if "b" not in mode else b"x")
        emit("write", True, path, t)
    except OSError as e:
        emit("write", False, err(e), t)

def mkdir(path):
    try:
        os.makedirs(path); emit("mkdir", True, path)
    except OSError as e:
        emit("mkdir", False, err(e))

def unlink(path):
    try:
        os.unlink(path); emit("unlink", True, path)
    except OSError as e:
        emit("unlink", False, err(e))

def rename(a, b):
    try:
        os.rename(a, b); emit("rename", True, "%s -> %s" % (a, b))
    except OSError as e:
        emit("rename", False, err(e))

def devnull():
    try:
        with open("/dev/null", "w") as f: f.write("x")
        emit("devnull", True, "/dev/null")
    except OSError as e:
        emit("devnull", False, err(e))

def read(path):
    try:
        with open(path, "rb") as f: n = len(f.read(4096))
        emit("read", True, "%s (%d bytes)" % (path, n))
    except OSError as e:
        emit("read", False, err(e))

def listdir(path):
    try:
        emit("listdir", True, "%s (%d entries)" % (path, len(os.listdir(path))))
    except OSError as e:
        emit("listdir", False, err(e))

def tempfile_default():
    import tempfile
    try:
        fd, p = tempfile.mkstemp(); os.close(fd); os.unlink(p)
        emit("tempfile", True, p)
    except BaseException as e:
        emit("tempfile", False, err(e))

def pycache(engine_dir):
    # 从引擎文件夹 import 一个模块；python 想写 __pycache__ 会被拒绝，但必须优雅地继续
    sys.path.insert(0, engine_dir)
    sys.dont_write_bytecode = False
    try:
        import sample_mod
        pc = os.path.join(engine_dir, "__pycache__")
        emit("pycache", True, "import ok (%s); __pycache__ exists=%s" % (sample_mod.VALUE, os.path.exists(pc)))
    except BaseException as e:
        emit("pycache", False, err(e))

def run(args, timeout=10):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout + p.stderr).strip().replace("\n", " | ")[:160]
        emit("run", p.returncode == 0, "rc=%d %s" % (p.returncode, out))
    except BaseException as e:
        emit("run", False, err(e))

def run_net(tool, host, port):
    if tool == "curl":
        run(["/usr/bin/curl", "-sS", "-m", "3", "http://%s:%s/" % (host, port)])
    elif tool == "nc":
        run(["/usr/bin/nc", "-z", "-w", "2", host, str(port)])
    elif tool == "python":
        # 内层探针自己报告成败（外层 rc 恒为 0）
        try:
            p = subprocess.run([sys.executable, os.path.abspath(__file__), "tcp", host, str(port)], capture_output=True, text=True, timeout=10)
            d = json.loads(p.stdout.strip().splitlines()[-1])
            emit("run", d["ok"], "python child: " + d["detail"])
        except BaseException as e:
            emit("run", False, err(e))

def bind_unix(path):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); s.listen(1)
        emit("bind-unix", True, path)
    except OSError as e:
        emit("bind-unix", False, err(e))

def asyncio_probe():
    import asyncio
    async def m():
        await asyncio.sleep(0.01); return "ok"
    try:
        emit("asyncio", asyncio.run(m()) == "ok", "event loop + self-pipe socketpair")
    except BaseException as e:
        emit("asyncio", False, err(e))

def daemon_net(host, port, outfile):
    """双 fork + setsid 脱离进程组的孙进程去连网，结果写到 outfile（验证：脱离也逃不出沙盒）。"""
    pid = os.fork()
    if pid == 0:
        os.setsid()
        if os.fork() == 0:
            r = subprocess.run([sys.executable, os.path.abspath(__file__), "tcp", host, str(port)], capture_output=True, text=True)
            tmp = outfile + ".tmp"
            with open(tmp, "w") as f: f.write(r.stdout)
            os.rename(tmp, outfile)
        os._exit(0)
    os.waitpid(pid, 0)
    for _ in range(40):
        if os.path.exists(outfile):
            line = open(outfile).read().strip().splitlines()[-1]
            d = json.loads(line); return emit("daemon-net", d["ok"], "grandchild: " + d["detail"])
        time.sleep(0.1)
    emit("daemon-net", False, "grandchild produced no result")

def exec_probe(path, *a):
    try:
        p = subprocess.run([path] + list(a), capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
        emit("exec", True, "rc=%d %s" % (p.returncode, (p.stdout + p.stderr).strip()[:80].replace("\n", " ")))
    except BaseException as e:
        emit("exec", False, err(e))

if __name__ == "__main__":
    c, a = sys.argv[1], sys.argv[2:]
    fn = {
        "tcp": lambda: tcp(a[0], int(a[1]), int(a[2]) if len(a) > 2 else 0), "connect": lambda: connect_only(a[0], int(a[1])), "udp": lambda: udp(a[0], int(a[1])), "unix": lambda: unix(a[0]),
        "listen": lambda: listen(a[0]), "dns": lambda: dns(a[0]), "dns-socket": dns_socket,
        "write": lambda: wr(a[0], a[1] if len(a) > 1 else "w"), "mkdir": lambda: mkdir(a[0]), "unlink": lambda: unlink(a[0]),
        "rename": lambda: rename(a[0], a[1]), "devnull": devnull, "read": lambda: read(a[0]), "listdir": lambda: listdir(a[0]),
        "tempfile": tempfile_default, "pycache": lambda: pycache(a[0]), "run-net": lambda: run_net(a[0], a[1], a[2]),
        "bind-unix": lambda: bind_unix(a[0]), "daemon-net": lambda: daemon_net(a[0], int(a[1]), a[2]), "asyncio": asyncio_probe, "exec": lambda: exec_probe(*a),
    }[c]
    fn()
