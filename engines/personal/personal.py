#!/usr/bin/env python3
"""螺壳输入法的个人化组件。协议见 docs/引擎协议.md#个人化组件，分工见 docs/设计.md#个人化与联想。

现在做的（第 1 期）：把壳转来的上屏写进螺壳的记忆（luoke-mem），话题和写法是和 luoke-mem 商定的
（顶层 projects/luoke-ime.md「在记忆里读写什么」）：
- ime-commit（用户 / 陈述）：上屏的字，同一应用里接连的上屏合成一段记一条；这一段开始时光标前的字放在
  data.context 里、标成第三方写的（前文可能是别人写的，记忆只拿它理解上下文）。切走时的自动上屏单独记、标 auto，归纳时不当依据。
- ime-correction（用户 / 活动）：上屏后马上删改、在候选里没选首选。
- ime-forget（用户 / 陈述）：在候选窗里忘掉一个候选（Shift+⌫）。
凭证（密码、验证码、密钥和令牌、完整卡号和证件号）只遮那一串、其余照记（顶层 ADR 0013，luoke_mem.mask_secrets；库写进去前
也会再遮）。健康、法律、宗教政治照 luoke_mem.sensitive_kinds 标上类别：标了不藏，只是推出来的要用户点头才生效。
安全输入、暂停记录、设了"禁止记录"的应用，壳根本不转过来；记忆记录关着时，壳不给记忆的路径。
写记忆在自己的线程里排队：别的工具正写时最多等锁 10 秒，不能让转问的答复等它。
上屏原文默认一直保留；选项里设了保留期，就定期删掉过期的（被理解引用的留下作依据）。

第 2 期：模型打分从小鹤、全拼引擎搬到这里。scorer.py 在自己的子进程里加载模型（要能跑 MLX 的 Python：oMLX 自带的），
引擎经壳转问 score：{"context", "candidates"} → {"logprobs"}。只加载一份模型，以后联想也用它。

第 3 期：联想（predict）：{"context"} → {"candidates"}。先找用户自己写过的：最近的上屏里，前文末尾的几个字后面
常接什么；再请模型接着写几种说法，太没把握的不要。壳上屏后问，有就提示"⇥ 联想"。

转问：ping 答 {"ok": true}；score、predict 见上；hotwords 还没做（第 5 期），答 not_implemented。

只用标准库。luoke_mem 用主控带的那份（组件跑在主控的 Python 上，它就在 sys.path 上；luoke-mem 的约定）；
导入不了就不写记忆。开发、测试时用 build.sh 带进 vendor/ 的那份。
"""
import json
import math
import os
import queue
import subprocess
import sys
import threading
import time
from collections import Counter

try:  # 主控的 Python 上有 luoke_mem；开发、测试时退到 build.sh 带进来的 vendor/
    import luoke_mem  # noqa: F401
except ImportError:
    sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))

TOOL = "luoke-ime"
COMMIT, CORRECTION, FORGET = "ime-commit", "ime-correction", "ime-forget"
GAP = 60.0        # 同一应用里两次上屏隔多久就断开成两段（秒）
IDLE = 20.0       # 停手多久把手上这一段写进记忆
LONGEST = 2000    # 一段最多多少字，再长就先写进去
KEEP = {"forever": None, "365": 365, "90": 90, "30": 30}   # 选项"上屏原文保留多久"：天数
SWEEP = 6 * 3600  # 设了保留期时，多久删一次过期的
MODEL = "~/.omlx/models/local/Qwen3.5-0.8B-Base-4bit"  # 选项里没写时用的打分模型

counts = Counter()  # 收到、写了、没写多少，只是次数（退出时写进标准错误，不带用户的字）


def stamp(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))


def log(s):
    print(s, file=sys.stderr, flush=True)


def squash(s):
    return "".join(s.split())


# ---- 写记忆 -------------------------------------------------------------------

class Store:
    """记忆的写入：在自己的线程里按顺序做，第一次用到时才打开记忆。"""

    def __init__(self, path):
        self.path = path
        self.jobs = queue.Queue()
        self.mem = None
        self.broken = False
        self.status = "pending"  # 记忆：pending 还没打开、ok、too_new（记忆文件比带的 luoke_mem 新）、broken；ping 里报给壳
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def put(self, job):
        self.jobs.put(job)

    def record(self, topic, kind, text, data, at, sensitive=None):
        kinds = list(sensitive or []) or None
        self.put(lambda mem: mem.record("user", kind, text, topic=topic, data=data, happened_at=stamp(at), sensitive=kinds))
        counts["written." + topic] += 1
        if kinds:
            counts["marked.sensitive"] += 1
        if topic == COMMIT and not data.get("auto"):
            history.add(text)

    def load_history(self, limit=5000):
        """把最近写过的上屏读进来给联想用（在写记忆的线程上做，不挡别的）。"""
        def job(mem):
            recent = mem.records(topic=COMMIT, limit=limit)  # 新的在前
            history.add_older([r["text"] for r in reversed(recent) if not (r.get("data") or {}).get("auto")])
        self.put(job)

    def _memory(self):
        if self.mem is None and not self.broken:
            try:
                from luoke_mem import Memory
                self.mem = Memory(self.path, tool=TOOL)
                self.status = "ok"
            except Exception as e:  # noqa: BLE001  打不开就不写，输入照常
                self.broken = True
                # 别的工具用新版 luoke_mem 写过之后，带的这份太旧会拒绝打开（宁可停也不漏）：要更新组件
                self.status = "too_new" if type(e).__name__ == "TooNew" else "broken"
                log("打不开记忆 %s：%s" % (self.path, e))
        return self.mem

    def _run(self):
        while True:
            job = self.jobs.get()
            if job is None:
                break
            mem = self._memory()
            if mem is not None:
                try:
                    job(mem)
                except Exception as e:  # noqa: BLE001
                    counts["write_failed"] += 1
                    log("写记忆失败：%s" % type(e).__name__)  # 不带内容

    def close(self, timeout):
        """把排着的写完（最多等 timeout 秒：壳关了标准输入后 1 秒就强制结束）。"""
        self.jobs.put(None)
        self.thread.join(timeout)
        if not self.thread.is_alive() and self.mem is not None:
            self.mem.close()


# ---- 上屏合成一段 --------------------------------------------------------------

class Segment:
    def __init__(self, m, now):
        self.app = m.get("app")
        self.source = m.get("source")
        self.kind = m.get("kind") or "typing"
        self.text = ""
        self.typed = ""        # 这一段打过的所有字，后来删掉的也在：标敏感类别按它
        self.corrections = []  # 这一段里的改选、删改，等这一段写进去时一起写（带一样的类别）
        self.context = m.get("context") or ""  # 这一段开始时光标前的字（第三方写的）
        self.started = now
        self.last = now
        self.ids = []  # 这一段里的上屏序号（个人化组件这边的），退格用它对上


class Recorder:
    """把壳转来的上屏、退格、忘掉变成记忆里的记录。`write(topic, kind, text, data, at, sensitive=类别)` 真正去写；
    `mask(text)` 把凭证那一串遮掉、返回遮过的文字（老版 luoke_mem 没有 mask_secrets 时，含凭证就返回 None，整段不记）；
    `kinds(text)` 给出健康、法律、宗教政治这类上下文的类别（标上，不藏）。"""

    CONTEXT = 200  # 前文最多带多少字

    def __init__(self, write, mask, clock=time.time, kinds=lambda text: []):
        self.write = write
        self.mask = mask
        self.kinds = kinds
        self.clock = clock
        self.lock = threading.Lock()
        self.seg = None
        self.last_kinds = []  # 上一段的类别：之后对着它的删改也带上

    def committed(self, m):
        with self.lock:
            now = self.clock()
            kind = m.get("kind") or "typing"
            counts["committed." + kind] += 1
            chose = [("chose", "选了「%s」，没选首选「%s」" % (p["text"], p["top"]),
                      {"app": m.get("app"), "source": m.get("source"), "text": p["text"], "top": p["top"], "index": p["index"]}, now)
                     for p in m.get("pieces") or [] if p.get("index") and p.get("top") and p.get("text") != p.get("top")]
            text = m.get("text") or ""
            if m.get("auto"):
                # 切走时壳替用户选的：单独记一条、标出来，归纳时不当依据
                continuing = self.seg is not None and self._continues(m, now)
                before = self.seg.typed if continuing else ""
                context = self.seg.context if continuing else (m.get("context") or "")
                self._flush()
                if text.strip():
                    kinds = self.kinds(before + text)
                    self._write(COMMIT, "statement", text,
                                {"app": m.get("app"), "source": m.get("source"), "kind": kind, "auto": True}, now, kinds, context)
                    for c in chose:
                        self._correction(*c, kinds=kinds)
                return
            if not self._continues(m, now):
                self._flush()
            if self.seg is None:
                if kind == "punctuation":
                    return  # 单独一个标点，不成一段
                self.seg = Segment(m, now)
            seg = self.seg
            ctx = m.get("context")
            if ctx and seg.text and ctx[-1].isspace() and not seg.text[-1].isspace():
                seg.text += ctx[-1]  # 壳在中英文之间自动加的空格：上屏文字里没有，前文里看得到
                seg.typed += ctx[-1]
            seg.text += text
            seg.typed += text
            seg.corrections += chose
            seg.last = now
            seg.ids.append(m.get("id"))
            if len(seg.text) >= LONGEST:
                self._flush()

    def _continues(self, m, now):
        seg = self.seg
        if seg is None or m.get("app") != seg.app or now - seg.last > GAP:
            return False
        if (m.get("kind") or "typing") in ("punctuation", "predict"):
            return True  # 标点、选了联想：接在这一段后面，不管是谁出的字
        if m.get("source") != seg.source:
            return False
        ctx = m.get("context")
        if ctx is not None:
            # 前文得接着这一段：对不上就是光标挪过，或者中间有不经输入法的字（英文模式下敲的、粘贴的）
            a, b = squash(ctx), squash(seg.text)
            if not (a.endswith(b) or (a and b.endswith(a))):
                return False
        return True

    def deleted(self, m):
        with self.lock:
            now = self.clock()
            counts["deleted"] += 1
            count = int(m.get("count") or 0)
            seg = self.seg
            if seg is not None and m.get("after") in seg.ids and count > 0:
                # 上屏后紧接着的退格从这一段末尾删起（先删到紧跟着的标点）：记录里也不要这些字
                n = min(count, len(seg.text))
                gone = seg.text[len(seg.text) - n:]
                seg.text = seg.text[:len(seg.text) - n]
                seg.last = now
                seg.corrections.append(("deleted", "删掉了刚上屏的「%s」" % gone,
                                        {"app": seg.app, "source": seg.source, "count": count, "deleted": gone}, now))
            elif count > 0:
                self._correction("deleted", "删掉了刚上屏的 %d 个字" % count, {"count": count}, now, kinds=self.last_kinds)

    def forget(self, m):
        with self.lock:
            counts["forget"] += 1
            text = m.get("text") or ""
            # 用户明确说别再这样出它。以后候选来自一条常用说法（term）时，还要对那条理解调 reject（不是 forget）
            self._write(FORGET, "statement", "不要候选「%s」" % text,
                        {"source": m.get("source"), "input": m.get("input"), "text": text}, self.clock(), self.kinds(text))

    def tick(self):
        """定时调：停手够久就把手上这一段写进去。"""
        with self.lock:
            if self.seg is not None and self.clock() - self.seg.last >= IDLE:
                self._flush()

    def close(self):
        with self.lock:
            self._flush()

    def _flush(self):
        seg, self.seg = self.seg, None
        if seg is None:
            return
        kinds = self.kinds(seg.typed)
        self.last_kinds = kinds
        if seg.text.strip():
            self._write(COMMIT, "statement", seg.text, {"app": seg.app, "source": seg.source, "kind": seg.kind, "auto": False},
                        seg.started, kinds, seg.context)
        for c in seg.corrections:
            self._correction(*c, kinds=kinds)

    def _correction(self, what, text, data, now, kinds=()):
        self._write(CORRECTION, "activity", text, dict(data, what=what), now, sorted(set(kinds) | set(self.kinds(text))))

    def _write(self, topic, kind, text, data, at, kinds, context=""):
        """遮掉凭证再写；data 里的文字字段（改选、删掉的字、前文）也遮。老版库遮不了、含凭证的就不写。"""
        masked = self.mask(text)
        if masked is None:
            counts["dropped.secret"] += 1
            return
        data = dict(data)
        for k in ("text", "top", "deleted"):
            if isinstance(data.get(k), str):
                v = self.mask(data[k])
                if v is None:
                    counts["dropped.secret"] += 1
                    return
                data[k] = v
        if topic == COMMIT and context:
            v = self.mask(context[-self.CONTEXT:])
            if v:
                data["context"] = {"text": v, "speaker": "third_party"}  # 前文可能是别人写的，记忆只拿它理解上下文
        if masked != text:
            counts["masked.secret"] += 1
        self.write(topic, kind, masked, data, at, sensitive=kinds)


# ---- 联想：用户自己写过的 -----------------------------------------------------

# 标点表只有这一份：用户写过的里找后文、联想的截法、随请求传给主控的停止串都用它
PUNCT = "，。！？、；：,.!?;:\n\r\t 　“”‘’\"'（）()《》【】[]"


class History:
    """最近写过的上屏（只在内存里，来自记忆和这次写进去的），联想时找前文末尾的几个字后面常接什么。"""

    def __init__(self, size=5000):
        self.lock = threading.Lock()
        self.texts = []
        self.size = size

    def add(self, text):
        if not text:
            return
        with self.lock:
            self.texts.append(text)
            if len(self.texts) > self.size:
                del self.texts[: len(self.texts) - self.size]

    def add_older(self, texts):
        """启动时从记忆里读来的（按时间先后）：放在这次写进去的前面；太多时去掉最早的。"""
        with self.lock:
            self.texts = (list(texts) + self.texts)[-self.size:]

    def predict(self, context, limit=3, longest=6, chars=6):
        """前文末尾 longest..2 个字在以前的上屏里出现过、后面接着的字（到标点为止，最多 chars 个）。
        接法各不相同时，按它们共同的开头算（"下午开会""下午三点见"都算"下午"）；出现得多的在前，一样多时长的在前。
        末尾只对上两个字时，至少要出现两次才算。"""
        ctx = context.rstrip()
        with self.lock:
            texts = list(self.texts)
        for n in range(min(longest, len(ctx)), 1, -1):
            tail = ctx[-n:]
            if any(ch in PUNCT for ch in tail):
                continue
            found = Counter()
            for t in texts:
                start = 0
                while True:
                    i = t.find(tail, start)
                    if i < 0:
                        break
                    rest = t[i + n:]
                    cut = next((j for j, ch in enumerate(rest) if ch in PUNCT), len(rest))
                    cont = rest[:min(cut, chars)]
                    for k in range(1, len(cont) + 1):
                        found[cont[:k]] += 1
                    start = i + 1
            need = 2 if n == 2 else 1
            out = []
            for c, k in sorted(found.items(), key=lambda x: (-x[1], -len(x[0]))):
                if k < need:
                    break
                if any(o.startswith(c) and found[o] == k for o in out):
                    continue  # 是已经选上的那个的开头、出现得一样多：多余
                out.append(c)
                if len(out) == limit:
                    break
            if out:
                return out
        return []


history = History()


# ---- 转问 ---------------------------------------------------------------------

out_lock = threading.Lock()  # 打分的答复从打分线程发，别的从主线程发


def send(message):
    line = json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n"
    with out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def reply(ask, result=None, error=None, message=""):
    if error:
        send({"type": "reply", "id": ask["id"], "error": {"code": error, "message": message}})
    else:
        send({"type": "reply", "id": ask["id"], "result": result})


def not_yet(ask):
    reply(ask, error="not_implemented", message="%s 还没做" % ask.get("method"))


def find_python():
    """能跑 MLX 的 Python：oMLX 应用自带的，或 Homebrew 装的 omlx。返回 (解释器, 要加进 PYTHONPATH 的目录)。"""
    app = "/Applications/oMLX.app/Contents/Resources/Python"
    if os.access(app + "/cpython-3.11/bin/python3.11", os.X_OK):
        return app + "/cpython-3.11/bin/python3.11", app + "/framework-mlx-base/lib/python3.11/site-packages"
    if os.access("/opt/homebrew/opt/omlx/libexec/bin/python3", os.X_OK):
        return "/opt/homebrew/opt/omlx/libexec/bin/python3", None
    return None


class Scorer:
    """模型打分：scorer.py 在子进程里，按行一问一答、按顺序算。转问在这里排队，由打分线程算完直接答复；
    模型还没加载好答 not_ready，加载不了答 unavailable。发问的引擎只等 0.7 秒，排队太久的就不算了。"""

    TIMEOUT = 2.0  # 一次打分最多等多久，超时的答复晚到时丢掉
    STALE = 0.7    # 在队里等了这么久还没轮到：发问的已经不等了，不算

    def __init__(self, command, env=None):
        self.jobs = queue.Queue()
        self.lines = queue.Queue()
        self.state = "loading"  # loading → ready，或 failed、stopped
        self.owed = 0           # 超时了还没读到的答复数
        self.last_used = time.monotonic()
        try:
            self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         text=True, bufsize=1, env=env)
        except OSError as e:
            self.state = "failed"
            log("启动模型打分器失败：%s" % e)
            return
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._errors, daemon=True).start()
        threading.Thread(target=self._run, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _errors(self):
        for line in self.proc.stderr:
            log("模型 ⟩ " + line.rstrip())

    def stop(self):
        """不用了：结束打分进程，放掉它占的显存（经主控打分时，全机只留一份模型）。"""
        self.state = "stopped"
        try:
            self.proc.terminate()
        except (OSError, AttributeError):
            pass

    def ask(self, ask):
        self.last_used = time.monotonic()
        if self.state == "ready":
            self.jobs.put((time.monotonic(), ask))
        elif self.state == "loading":
            reply(ask, error="not_ready", message="模型还在加载")
        else:
            reply(ask, error="unavailable", message="模型打分器没起来")

    def ask_continuations(self, ask, mine):
        """联想：模型接着写几种说法，接在 mine（用户自己写过的）后面答复；模型不在就只答 mine。"""
        self.last_used = time.monotonic()
        if self.state == "ready":
            self.jobs.put((time.monotonic(), dict(ask, _mine=mine)))
        else:
            reply(ask, {"candidates": mine})

    def _request(self, obj):
        """发一行、读一行；返回解析好的答复，超时返回 ""，打分器退出返回 None。"""
        try:
            self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            return None
        while self.owed:  # 先丢掉之前超时的晚到答复
            if self._line(self.TIMEOUT) is None:
                return None
            self.owed -= 1
        line = self._line(self.TIMEOUT)
        if line is None:
            return None
        if not line:
            self.owed += 1
            return ""
        try:
            return json.loads(line)
        except ValueError:
            return {}

    def _line(self, timeout):
        try:
            return self.lines.get(timeout=timeout)
        except queue.Empty:
            return ""

    def _run(self):
        first = self._line(180)
        if not first or '"ready"' not in first:
            self.state = "failed"
            log("模型没能加载")
            return
        self.state = "ready"
        log("模型已就绪")
        while True:
            at, ask = self.jobs.get()
            if "_mine" in ask:
                if not self._continue(at, ask):
                    return
                continue
            params = ask.get("params") or {}
            cands = params.get("candidates") or []
            if not cands:  # 空的也答：引擎用它试试能不能打分
                reply(ask, {"logprobs": []})
                continue
            if time.monotonic() - at > self.STALE:
                counts["score.stale"] += 1
                reply(ask, error="expired", message="排队太久，发问的已经不等了")
                continue
            got = self._request({"ctx": params.get("context") or "", "cands": cands})
            if got is None:
                return self._died(ask)
            if got == "":
                counts["score.timeout"] += 1
                reply(ask, error="timeout", message="打分超时")
                continue
            lp = got.get("lp")
            if not isinstance(lp, list):
                reply(ask, error="failed", message="打分器的答复看不懂")
                continue
            counts["score"] += 1
            reply(ask, {"logprobs": [x if x != float("-inf") else -1e9 for x in lp]})

    def _continue(self, at, ask):
        mine = ask.pop("_mine")
        if time.monotonic() - at > self.STALE:  # 壳等联想只等 1 秒
            reply(ask, {"candidates": mine})
            return True
        params = ask.get("params") or {}
        req = continue_params(params.get("context") or "")
        got = self._request({"branches": req.pop("context"), **req})
        if got is None:
            self._died(ask, {"candidates": mine})
            return False
        model = [c for c in model_candidates(continuations_from_branches((got or {}).get("branches"))) if c not in mine]
        counts["predict"] += 1
        counts["predict.model" if model else "predict.none"] += 1
        reply(ask, {"candidates": (mine + model)[:5]})
        return True

    def _died(self, ask, result=None):
        self.state = "failed"
        log("模型打分器退出了")
        if result is not None:
            reply(ask, result)
        else:
            reply(ask, error="unavailable", message="模型打分器退出了")


# 模型对下一个词有多大把握（第一个 token 的概率）低于这个，就不给模型的联想：博客语料上，≥ 0.2 时约 7% 的上屏有联想，
# 第一个就对的约 41%、前三个里有对的约 49%；不设门槛时几乎每次都有、第一个对的只有 14%（eval_predict.py）。
MODEL_GATE = 0.2


# 联想的截法（归输入法，主控只做通用续写，见 docs/续写接口草案.md）：碰到标点就截在标点前；超过
# CONT_CHARS 个字就退回上一个 token 的边界，不在词中间断（"结论和方法建" → "结论和方法"）。随请求传给主控（或本机的打分进程）的
# 只有开头个数、最多几个 token 和停止串（PUNCT）。
CONT_K, CONT_TOKENS, CONT_CHARS = 8, 6, 6


def continue_params(ctx):
    return {"context": ctx, "k": CONT_K, "max_tokens": CONT_TOKENS, "stop": list(PUNCT)}


def continuations_from_branches(branches):
    """逐个 token 的续写（主控 /v1/continue 或本机打分进程的 branches）→ model_candidates 要的
    [(文字, 留下的 token 的对数概率之和, 第一个 token 的文字, 它的对数概率)]，把握大的在前；空的丢掉，文字一样的只留一个。"""
    out, seen = [], set()
    for b in branches or []:
        toks = [t for t in (b.get("tokens") or []) if isinstance(t, dict)] if isinstance(b, dict) else []
        if not toks:
            continue
        text, total = "", 0.0
        for t in toks:
            piece, lp = str(t.get("text") or ""), float(t.get("logprob") or 0.0)
            cut = next((i for i, ch in enumerate(piece) if ch in PUNCT), None)
            if cut is not None:
                if cut:
                    text, total = text + piece[:cut], total + lp
                break
            if len(text) + len(piece) > CONT_CHARS:
                if not text:  # 第一个 token 就超了：只好在字数上限切
                    text, total = piece[:CONT_CHARS], lp
                break
            text, total = text + piece, total + lp
        if text and text not in seen:
            seen.add(text)
            out.append((text, total, str(toks[0].get("text") or ""), float(toks[0].get("logprob") or 0.0)))
    return sorted(out, key=lambda x: -x[1])


def model_candidates(cont, gate=MODEL_GATE):
    """模型接着写的说法 → 联想候选：把握最大的几个开头的词（多半是整个词），再加上最有把握的那句续写（比开头长时）。
    cont 是 scorer.py 的 [(续写, 总对数概率, 第一个 token, 它的对数概率)]。"""
    heads, best = [], None
    for text, total, head, head_lp in sorted(cont, key=lambda x: -x[3]):
        if not all("\u4e00" <= ch <= "\u9fff" for ch in head) or not head:
            continue
        if best is None:
            if math.exp(head_lp) < gate:
                return []
            best = (text, total)
        elif math.exp(head_lp) < 0.05:
            break  # 后面的开头太不可能了
        if head not in heads:
            heads.append(head)
    if best is None:  # 开头都不是汉字（英文、数字、半个字）
        return []
    out = heads[:3]
    text, total = best
    if len(text) > len(out[0]) and text.startswith(out[0]) and total / len(text) >= -1.5 and text not in out:
        out.insert(1, text)
    return out


scorer = None          # 本机的打分进程：scorer 选项是 local 时收到 hello 就起；经主控时要退回本机才起
scorer_options = None  # 起它用的选项（经主控时先记着）
LOCAL_IDLE = 300       # 经主控打分时，本机打分进程闲了这么久就停掉（全机只留一份模型，ADR 0001）
LOCAL_SCORER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scorer.py")  # 发布版不带（scripts/bundle-engines.sh）


def ensure_local():
    """经主控打分、主控不可用时才起本机的打分进程（起来要几秒，这期间答 not_ready）。"""
    if scorer is None and scorer_options is not None:
        start_scorer(scorer_options)


def stop_idle_local():
    """主控好着、本机打分进程又闲了 LOCAL_IDLE 秒：停掉它。ticker 每秒调。"""
    global scorer
    s = scorer
    if scorer_mode != "local" and s is not None and hub.up and time.monotonic() - s.last_used > LOCAL_IDLE:
        log("主控好着，本机的打分进程停掉")
        scorer = None
        s.stop()


def start_scorer(options):
    """按选项起模型打分器；找不到能跑 MLX 的 Python 或模型就不起，score 答 unavailable。"""
    global scorer
    if scorer is not None or (options or {}).get("score") is False:
        return
    model = os.path.expanduser((options or {}).get("model") or MODEL)
    py = find_python()
    if py is None:
        log("找不到能跑 MLX 的 Python（oMLX），不打分")
        return
    if not os.path.isdir(model):
        log("找不到模型 %s，不打分" % model)
        return
    env = dict(os.environ)
    if py[1]:
        env["PYTHONPATH"] = py[1]
    scorer = Scorer([py[0], LOCAL_SCORER, model], env)


def predict(ask):
    ctx = (ask.get("params") or {}).get("context") or ""
    mine = history.predict(ctx)

    def local(a):
        ensure_local()
        if scorer is None:
            reply(a, {"candidates": mine})
        else:
            scorer.ask_continuations(a, mine)
    if scorer_mode == "local":
        local(ask)
    else:  # hub：只用主控（不行就只给用户自己写过的）；auto：不行时交给本机
        hub.predict(ask, mine, local if scorer_mode == "auto" else (lambda a: reply(a, {"candidates": mine})))


RERANK = "luoke-ime.rerank"    # 主控里的重排打分任务（luoke-core 的配方）
PREDICT = "luoke-ime.predict"  # 主控里的联想（续写）任务


class HubRelay:
    """经壳转问主控（luoke-core）打分：发 to: hub 的转问，答复从标准输入回来（主循环交给 on_reply）。
    主控不可用、模型在加载、忙时交给 fallback（本机的打分进程，或者答错误），并照 retry_after 过一会儿再试主控。"""

    STALE = 0.7  # 发问的引擎只等 0.7 秒：主控的拒绝来得比这晚，就不必再交给本机算了
    DOWN = {"unavailable", "not_ready", "busy", "paused", "engine_failed", "task_unavailable", "unsupported", "needs_user"}
    # 这几种才退回本机：主控真的不可用。在加载（not_ready）、忙（busy）只是等几秒：这几秒不重排，不为它起本机的模型
    # （本机加载比主控还慢，起了就是全机两份模型）
    FALLBACK = {"unavailable", "engine_failed", "task_unavailable", "unsupported", "needs_user", "paused"}

    def __init__(self):
        self.lock = threading.Lock()
        self.pending = {}
        self.last_error = None  # 最近一次主控的错误（联想据此判断是不是老主控）
        self.counter = 0
        self.down_until = 0.0
        self.down_code = None
        self.slow = False       # 主控按实测给 rerank 标了 slow（比如 M1）：随打分答复告诉引擎，引擎少给候选
        self.checked_at = -1e9  # 上一次读 GET /tasks

    @property
    def up(self):
        return time.monotonic() >= self.down_until

    def _while_down(self, ask, fallback, message="主控暂时不可用"):
        """主控最近说了不行：真不可用就交给本机，在加载、忙就这一次不算。"""
        if self.down_code in self.FALLBACK:
            fallback(ask)
        else:
            reply(ask, error=self.down_code or "unavailable", message=message)

    def check_tasks(self, every=60):
        """隔一会儿读一次主控的任务状态（GET /tasks），记下 rerank 是不是标了 slow。"""
        if time.monotonic() - self.checked_at < every:
            return
        self.checked_at = time.monotonic()

        def ok(r):
            t = (r.get("tasks") or {}).get(RERANK) or {}
            slow = bool(t.get("slow"))
            if slow != self.slow:
                log("主控说这台机器上打分慢" if slow else "主控说打分不慢了")
            self.slow = slow
            return True
        self._ask("tasks", {}, ok, None, lambda a: None)

    def warmup(self):
        """经主控打分时，一起来就请主控把打分模型加载好（答复不用管）。"""
        for task in (RERANK, PREDICT):
            self._ask("warmup", {"task": task}, lambda r: True, None, lambda a: None)

    def _ask(self, method, params, ok, ask, fallback):
        """发一个转问给主控；成功交给 ok(result)，失败交给 fallback(ask)（或者来得太晚时答错误）。"""
        with self.lock:
            self.counter += 1
            k = self.counter
            self.pending[k] = (ask, ok, fallback, time.monotonic())
        send({"type": "ask", "id": k, "to": "hub", "method": method, "params": params})

    def score(self, ask, fallback):
        if not self.up:
            return self._while_down(ask, fallback)
        params = ask.get("params") or {}

        def ok(r):
            if not isinstance(r.get("logprobs"), list):
                return False
            counts["hub.score"] += 1
            counts["hub.cache_hit"] += bool(r.get("cache_hit"))
            reply(ask, {"logprobs": r["logprobs"], "cache_hit": r.get("cache_hit"), "via": "hub", "slow": self.slow})
            return True
        self._ask("score", {"task": RERANK, "context": params.get("context") or "", "candidates": params.get("candidates") or []},
                  ok, ask, fallback)

    def predict(self, ask, mine, fallback):
        """联想里模型那一路：主控的通用续写（/v1/continue），截法、挑法都在这里（continuations_from_branches、
        model_candidates），接在 mine（用户自己写过的）后面。老主控还没有 continue 时退回旧的 predict（截法在主控里）。"""
        if not self.up:
            return fallback(ask) if self.down_code in self.FALLBACK else reply(ask, {"candidates": mine})
        ctx = (ask.get("params") or {}).get("context") or ""

        def answer(cont):
            counts["hub.predict"] += 1
            model = [c for c in model_candidates(cont) if c not in mine]
            reply(ask, {"candidates": (mine + model)[:5]})
            return True

        def ok(r):
            return isinstance(r.get("branches"), list) and answer(continuations_from_branches(r["branches"]))

        def legacy(a):
            e = self.last_error or {}
            if e.get("code") != "invalid_request" or "端点" not in str(e.get("message") or ""):
                return fallback(a)  # 主控不可用、忙这些：照常交出去；只有老主控答"没有这个端点"时才用旧的 predict
            ok_old = lambda r: isinstance(r.get("continuations"), list) and answer(r["continuations"])  # noqa: E731
            self._ask("predict", {"task": PREDICT, "context": ctx}, ok_old, a, fallback)
        self._ask("continue", dict(continue_params(ctx), task=PREDICT), ok, ask, legacy)

    def on_reply(self, m):
        with self.lock:
            entry = self.pending.pop(m.get("id"), None)
        if entry is None:
            return
        ask, ok, fallback, at = entry
        r = m.get("result")
        if isinstance(r, dict) and ok(r):
            return
        if ask is None:  # 预热之类不用答复的
            return
        e = m.get("error") or {}
        code = e.get("code") or "failed"
        self.last_error = e
        counts["hub." + code] += 1
        if code in self.DOWN:  # 主控不可用、在加载、忙：照 retry_after 过一会儿再试；请求本身不对（invalid_request 等）不算
            wait = e.get("retry_after")
            self.down_until = time.monotonic() + (wait if isinstance(wait, (int, float)) and wait > 0 else 5)
            self.down_code = code
        if time.monotonic() - at < self.STALE and code not in ("not_ready", "busy"):
            fallback(ask)
        else:
            reply(ask, error=code, message=e.get("message") or "")


hub = HubRelay()
scorer_mode = "hub"  # 选项 scorer：hub（只用主控，默认）、local（本机的打分进程）、auto（主控优先，不可用时本机）。
# 发布版只经主控、没有本机退路：本机打分要能跑 MLX 的 Python（现在借 oMLX 的），干净的 Mac 上没有。


def local_score(ask):
    ensure_local()
    if scorer is None:
        reply(ask, error="unavailable", message="没有模型打分器（找不到 oMLX 或模型，或选项里关了）")
    else:
        scorer.ask(ask)


def score(ask):
    cands = (ask.get("params") or {}).get("candidates") or []
    if scorer_mode == "local" or (not cands and scorer_mode == "auto" and scorer is not None and scorer.state == "ready"):
        return local_score(ask)
    if not cands:  # 引擎试试能不能打分：主控最近没说不行就算能
        if hub.up:
            return reply(ask, {"logprobs": []})
        if scorer_mode == "auto" and hub.down_code in HubRelay.FALLBACK:  # 主控真不可用：退回本机
            return local_score(ask)
        return reply(ask, error=hub.down_code or "unavailable", message="主控暂时不可用")
    if scorer_mode == "auto":
        hub.score(ask, local_score)
    else:
        hub.score(ask, lambda a: reply(a, error="unavailable", message="主控暂时不可用"))


METHODS = {
    "ping": lambda ask: reply(ask, {"ok": True, "memory": store.status if store is not None else "off"}),
    "score": score,       # 前文 + 候选 → 各自的对数概率（第 2 期）
    "predict": predict,   # 前文 → 几个接着写的候选（第 3 期：联想）
    "hotwords": not_yet,  # → 常用的专名和说法（给语音）
}


def on_ask(ask):
    handler = METHODS.get(ask.get("method"))
    if handler is None:
        reply(ask, error="unknown_method", message="不认识的方法 %s" % ask.get("method"))
    else:
        handler(ask)


# ---- 主循环 -------------------------------------------------------------------

def keep_days(options):
    choice = (options or {}).get("keep") or ["forever"]
    return KEEP.get(choice[0] if isinstance(choice, list) and choice else "forever")


store = None  # 写记忆的（声明了记忆、用户同意了才有）


def main():
    global store, scorer_mode, scorer_options
    recorder = None
    path = os.environ.get("LUOKE_IME_MEMORY")  # 只在声明了 permissions.memory 时有
    if path:
        try:
            from luoke_mem import sensitive_kinds
            try:
                from luoke_mem import mask_secrets as mask
            except ImportError:  # 老版 luoke_mem（0.23 以前）：遮不了，含凭证的整段不记
                from luoke_mem import never_kept

                def mask(text):
                    return None if never_kept(text) else text
        except ImportError:
            log("导入不了 luoke_mem（没装主控？），不写记忆")
        else:
            store = Store(path)
            store.load_history()
            recorder = Recorder(store.record, mask, kinds=sensitive_kinds)
    days = None

    def sweep():
        if store is not None and days:
            until = stamp(time.time() - days * 86400)
            store.put(lambda mem: mem.forget_records(topics=[COMMIT, CORRECTION], until=until, keep_cited=True))

    def ticker():
        last_sweep = time.time()
        while True:
            time.sleep(1)
            if recorder is not None:
                recorder.tick()
            stop_idle_local()
            if scorer_mode != "local":
                hub.check_tasks()
            if time.time() - last_sweep >= SWEEP:
                last_sweep = time.time()
                sweep()

    threading.Thread(target=ticker, daemon=True).start()
    for line in sys.stdin:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        t = m.get("type")
        if t == "hello":
            scorer_mode = (m.get("options") or {}).get("scorer") or "hub"
            if scorer_mode != "hub" and not os.path.exists(LOCAL_SCORER):  # 发布版：选项里写了什么都只经主控
                log("没有本机打分（发布版只经主控），选项 scorer=%s 当 hub" % scorer_mode)
                scorer_mode = "hub"
            days = keep_days(m.get("options"))
            sweep()
            if scorer_mode == "local":
                start_scorer(m.get("options"))
            else:
                scorer_options = m.get("options") or {}  # 经主控打分：本机的打分进程要退回本机时才起
                hub.warmup()
        elif t == "ask":
            on_ask(m)
        elif t == "reply":
            hub.on_reply(m)  # 转问主控的答复
        elif recorder is None:
            counts[t or "?"] += 1
        elif t == "committed":
            recorder.committed(m)
        elif t == "deleted":
            recorder.deleted(m)
        elif t == "forget":
            recorder.forget(m)
        # 不认识的类型：忽略
    if recorder is not None:
        recorder.close()
    if store is not None:
        store.close(timeout=0.8)
    log("个人化组件退出：%s" % dict(counts))


if __name__ == "__main__":
    main()
