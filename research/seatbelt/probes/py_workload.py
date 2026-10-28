#!/usr/bin/python3
"""py_workload: 一个"普通 Python 引擎"会做的各种事（标准库为主）。在沙盒里应全部成功、且不产生违规报告。
数据目录取自环境变量 LUOKE_IME_DATA，临时目录取自 TMPDIR。输出一行 JSON: {"probe":"py_workload","ok":..,"detail":{步骤:结果}}"""
import asyncio, concurrent.futures, ctypes, hashlib, http.client, json, locale, logging, multiprocessing, os, pathlib, platform
import plistlib, queue, re, select, selectors, shutil, signal, socket, sqlite3, ssl, subprocess, sys, tempfile, threading, time
import unicodedata, urllib.request, zlib

res = {}
D = os.environ["LUOKE_IME_DATA"]

def step(name):
    def deco(f):
        try:
            res[name] = f() or "ok"
        except BaseException as e:
            res[name] = "FAIL %s: %s" % (type(e).__name__, e)
        return f
    return deco

@step("tempfile(TMPDIR)")
def _():
    with tempfile.NamedTemporaryFile() as f:
        f.write(b"x")
        assert os.path.dirname(f.name) == os.path.realpath(os.environ["TMPDIR"]).rstrip("/") or f.name.startswith(os.environ["TMPDIR"].rstrip("/")), f.name
@step("sqlite-memory")
def _(): sqlite3.connect(":memory:").execute("create table t(x)")
@step("sqlite-file(data)")
def _():
    c = sqlite3.connect(D + "/x.db"); c.execute("create table if not exists t(x)"); c.execute("insert into t values (1)"); c.commit()
@step("json/re/zlib/hashlib/unicodedata")
def _(): zlib.decompress(zlib.compress(b"abc")); hashlib.sha256(b"x").hexdigest(); unicodedata.normalize("NFC", "é"); re.compile("a+").match("aa")
@step("subprocess(/bin/echo)")
def _(): assert subprocess.run(["/bin/echo", "hi"], capture_output=True, text=True).stdout.strip() == "hi"
@step("subprocess(python child)")
def _(): assert subprocess.run([sys.executable, "-c", "print(1+1)"], capture_output=True, text=True).stdout.strip() == "2"
@step("subprocess(sh pipeline)")
def _(): assert subprocess.run("echo a | tr a b", shell=True, capture_output=True, text=True).stdout.strip() == "b"
@step("threads")
def _():
    out = []; t = threading.Thread(target=lambda: out.append(1)); t.start(); t.join(); assert out == [1]
@step("asyncio(loop+socketpair)")
def _():
    async def m(): await asyncio.sleep(0.01); return 1
    assert asyncio.run(m()) == 1
@step("asyncio(subprocess)")
def _():
    async def m():
        p = await asyncio.create_subprocess_exec("/bin/echo", "aio", stdout=asyncio.subprocess.PIPE)
        o, _ = await p.communicate(); return o.decode().strip()
    assert asyncio.run(m()) == "aio"
@step("socketpair")
def _(): a, b = socket.socketpair(); a.send(b"x"); assert b.recv(1) == b"x"
@step("multiprocessing.Pool(fork)")
def _():
    with multiprocessing.get_context("fork").Pool(2) as p: assert p.map(abs, [-1, -2]) == [1, 2]
@step("ProcessPoolExecutor")
def _():
    with concurrent.futures.ProcessPoolExecutor(1) as ex: assert ex.submit(abs, -3).result() == 3
@step("multiprocessing.shared_memory")
def _():
    from multiprocessing import shared_memory
    s = shared_memory.SharedMemory(create=True, size=16); s.close(); s.unlink()
@step("ctypes(libc)")
def _(): assert ctypes.CDLL(None).getpid() == os.getpid()
@step("select/pipe")
def _(): r, w = os.pipe(); os.write(w, b"x"); assert select.select([r], [], [], 0.2)[0] == [r]
@step("ssl context (no network)")
def _(): ssl.create_default_context()
@step("platform/locale/time")
def _(): platform.platform(); locale.getlocale(); time.strftime("%Z")
@step("pwd/expanduser")
def _():
    import pwd; pwd.getpwuid(os.getuid()); os.path.expanduser("~")
@step("read ~ (listdir)")
def _(): assert len(os.listdir(os.path.expanduser("~"))) > 0
@step("mkdir/rename/unlink in data")
def _():
    os.makedirs(D + "/a/b", exist_ok=True); open(D + "/a/f", "w").write("x"); os.rename(D + "/a/f", D + "/a/g"); os.unlink(D + "/a/g")
@step("fcntl.flock(data)")
def _():
    import fcntl; f = open(D + "/lock", "w"); fcntl.flock(f, fcntl.LOCK_EX)
@step("mmap(data)")
def _():
    import mmap; f = open(D + "/m", "wb+"); f.write(b"0" * 4096); f.flush(); mmap.mmap(f.fileno(), 4096)
@step("signal self")
def _(): signal.signal(signal.SIGUSR1, lambda *a: None); os.kill(os.getpid(), signal.SIGUSR1)
@step("shutil.copy (read outside -> data)")
def _(): shutil.copy("/etc/hosts", D + "/hosts.copy")
@step("getaddrinfo(localhost)")
def _(): socket.getaddrinfo("localhost", 80)
@step("dlopen 引擎自带的 .dylib")
def _():
    lib = os.path.join(os.environ["LUOKE_ENGINE_DIR"], "libtiny.dylib")   # 测试脚本用 clang 现编的 ad-hoc 签名库
    assert ctypes.CDLL(lib).tiny() == 7

bad = {k: v for k, v in res.items() if v != "ok"}
print(json.dumps({"probe": "py_workload", "ok": not bad, "detail": bad or "%d steps ok" % len(res)}, ensure_ascii=False))
