#!/usr/bin/python3
"""Seatbelt 违规监听器（参考实现；IME 里用 Swift 的 Process 做同样的事即可）。

原理：沙盒内核扩展 (Sandbox.kext) 把每次拒绝写进统一日志，sender 为 "Sandbox"，
消息形如
    Sandbox: Python(44860) deny(1) file-write-create /Users/me/x
    LUOKE[my-engine] write                   <- profile.sb 里 (with message ...) 追加的第二行：标签 + 类别
`log stream` 实时读取（admin 用户即可，不需要 sudo；标准用户未验证）。我们在 profile 里给每条
deny 规则都加了 `LUOKE[<engine-id>] <类别>` 标签，所以谓词里直接按标签过滤，
不需要追踪子进程树 —— 引擎 fork 出来的 curl / nc 等子进程同样带标签。
类别: write write-protected network dns microphone camera screen tcc exfil read-other-engine-data other
hard 的要通知用户，soft 的（dns / tcc / __pycache__ / other）只记录。

用法:
    denial_monitor.py [--engine ID]              # 持续打印 JSON 行，Ctrl-C 结束
    from denial_monitor import DenialMonitor     # 作为库使用
"""
import json
import os
import re
import subprocess
import sys
import threading
import time

LOG = "/usr/bin/log"

# "Sandbox: Python(44860) deny(1) file-write-create /Users/me/x\nLUOKE[eng] need write"
_MSG = re.compile(
    r"^(?:(?P<dups>\d+) duplicate reports? for )?Sandbox: (?P<proc>.+?)\((?P<pid>\d+)\) deny\((?P<n>\d+)\) (?P<op>[\w\-\*]+)"
    r"(?: (?P<detail>[^\n]*))?(?:\n(?P<msg>.*))?$",
    re.S,
)
_TAG = re.compile(r"LUOKE\[(?P<engine>[^\]]*)\]\s*(?P<text>.*)", re.S)


def hint_for(op, detail, cls):
    """(标签类别, 操作, 细节) -> 该补哪条声明。severity: hard=要告诉用户; soft=只记录。"""
    detail = detail or ""
    if cls == "write" and "/__pycache__" in detail:
        return {"permission": None, "severity": "soft", "suggest": "Python 想写字节码缓存 (%s)：给引擎设环境变量 PYTHONPYCACHEPREFIX=<数据目录>/pycache 即可，不需要声明 write" % detail}
    if cls == "write":
        target = os.path.dirname(detail) if op == "file-write-create" and detail else detail
        return {"permission": "write", "severity": "hard", "suggest": "permissions.write 里加入 %s" % target}
    if cls == "write-protected":
        return {"permission": None, "severity": "hard", "suggest": "该位置永远只读（引擎文件夹 / 启动项 / shell 配置 / ~/.ssh），改写到数据目录: " + detail}
    if cls == "read-other-engine-data":
        return {"permission": None, "severity": "hard", "suggest": "不能读其它引擎的数据目录: " + detail}
    if cls == "network":
        if detail.startswith("/"):
            return {"permission": "network", "severity": "hard", "suggest": "unix domain socket 任何档位都不放行 (%s)；改用 127.0.0.1 的 TCP 端口并声明 network: local" % detail}
        m = re.match(r"(remote|local):\*?[^:]*:(\d+)", detail)
        port = m.group(2) if m else "?"
        return {"permission": "network", "severity": "hard",
                "suggest": 'permissions.network 提升为 "local"（只连本机，如 127.0.0.1:%s）或 "any"（任意联网）' % port}
    if cls == "dns":
        return {"permission": "network", "severity": "soft", "suggest": '名称解析 / 网络配置被拦 (%s)：只有需要解析非 localhost 主机名时才要 permissions.network: "any"' % detail}
    if cls == "tcc":
        return {"permission": None, "severity": "soft", "suggest": "引擎在查系统隐私授权 (%s)：若它要用麦克风/摄像头/屏幕，请声明对应的 permissions.*" % detail}
    if cls == "microphone":
        return {"permission": "microphone", "severity": "hard", "suggest": "permissions.microphone: true"}
    if cls == "camera":
        return {"permission": "camera", "severity": "hard", "suggest": "permissions.camera: true"}
    if cls == "screen":
        return {"permission": "screen", "severity": "hard", "suggest": "permissions.screen: true"}
    if cls == "exfil":
        return {"permission": None, "severity": "hard", "suggest": "借别的程序外发 / 读剪贴板 / 起 launchd 作业，没有对应声明，一律不放行: %s %s" % (op, detail)}
    return {"permission": None, "severity": "soft", "suggest": "未归类的拒绝: %s %s（看 README 的'other'）" % (op, detail)}


def parse_event(ev):
    """ev: log stream ndjson 解出的 dict -> 违规 dict 或 None。"""
    m = ev.get("eventMessage") or ""
    mm = _MSG.match(m)
    if not mm:
        return None
    t = _TAG.search(mm.group("msg") or "")
    if not t:
        return None
    out = {
        "log_ts": ev.get("timestamp"),
        "dups": int(mm.group("dups") or 0),      # >0 表示这是"重复 N 次"的折叠行（内核对相同拒绝限流）
        "engine": t.group("engine"),
        "proc": mm.group("proc"),
        "pid": int(mm.group("pid")),
        "op": mm.group("op"),
        "detail": mm.group("detail") or "",
        "tag_text": t.group("text").strip(),
    }
    out.update(hint_for(out["op"], out["detail"], out["tag_text"].split()[0] if out["tag_text"] else "other"))
    return out


class DenialMonitor:
    """长驻的 `log stream` 子进程。实测拉起后约 0.04 s 就能收到之后的拒绝、事件延迟 < 1 ms（见 README 第 4 节），
    常驻开销很小，所以壳应在启动时就开着，不要按需启动。"""

    def __init__(self, on_denial, engine=None):
        self.on_denial = on_denial
        pred = 'sender == "Sandbox" AND eventMessage CONTAINS "LUOKE[%s' % (engine or "")
        pred += ']"' if engine else '"'
        self.cmd = [LOG, "stream", "--style", "ndjson", "--predicate", pred]
        self.proc = None
        self.ready = threading.Event()

    def start(self):
        self.proc = subprocess.Popen(self.cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue  # 首行是 "Filtering the log data using ..."
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            self.ready.set()
            d = parse_event(ev)
            if d:
                d["recv_ts"] = time.time()
                self.on_denial(d)

    def stop(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait()


if __name__ == "__main__":
    eng = None
    if "--engine" in sys.argv:
        eng = sys.argv[sys.argv.index("--engine") + 1]
    mon = DenialMonitor(lambda d: print(json.dumps(d, ensure_ascii=False), flush=True), engine=eng)
    mon.start()
    try:
        mon.proc.wait()
    except KeyboardInterrupt:
        mon.stop()
