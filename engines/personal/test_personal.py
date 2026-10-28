"""个人化组件的测试：python3 -m unittest test_personal（在这个文件夹里跑；build.sh 先把 luoke_mem 带进 vendor/）。

三层：上屏怎么变成记录（Recorder，假时钟）、写记忆（Store，真的 luoke_mem 和临时的记忆文件）、
整个组件（起一个子进程，按协议喂消息，再读记忆）。"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import personal  # noqa: E402  （它会把 vendor/ 加进 sys.path）

try:
    from luoke_mem import Memory
except ImportError:  # pragma: no cover
    raise SystemExit("没有 vendor/luoke_mem：先跑 ./build.sh")


def commit(text, *, id=1, app="com.example.notes", source="xiaohe", kind="typing", context=None, auto=False, pieces=None):
    m = {"type": "committed", "id": id, "text": text, "auto": auto, "kind": kind, "source": source, "app": app}
    if context is not None:
        m["context"] = context
    if kind == "typing":
        m["pieces"] = pieces if pieces is not None else [{"input": "x", "text": text, "index": 0, "top": text}]
    return m


class Rig:
    def __init__(self):
        self.now = 1000.0
        self.written = []
        # 假的判断："口令8z"是凭证（只把这一串遮成〔密码〕），"医院"是健康（标上类别写，不藏）
        self.r = personal.Recorder(self.write, lambda s: s.replace("口令8z", "〔密码〕"), clock=lambda: self.now,
                                   kinds=lambda s: ["health"] if "医院" in s else [])

    def write(self, topic, kind, text, data, at, sensitive=None):
        self.written.append({"topic": topic, "kind": kind, "text": text, "data": data, "at": at, "sensitive": list(sensitive or [])})

    def wait(self, seconds):
        self.now += seconds
        self.r.tick()

    def topics(self, topic):
        return [w for w in self.written if w["topic"] == topic]

    def texts(self, topic=personal.COMMIT):
        return [w["text"] for w in self.topics(topic)]


class 合成一段(unittest.TestCase):
    def test_同一应用里接着打的合成一段_停手才写进去_前文放在data里(self):
        g = Rig()
        g.r.committed(commit("我们", id=1, context="会议纪要："))
        g.wait(2)
        g.r.committed(commit("，", id=2, kind="punctuation"))
        g.r.committed(commit("明天开会", id=3, context="会议纪要：我们，"))
        g.wait(personal.IDLE - 1)
        self.assertEqual(g.written, [])  # 还没停手够久
        g.wait(2)
        self.assertEqual(g.texts(), ["我们，明天开会"])
        w = g.topics(personal.COMMIT)[0]
        self.assertEqual(w["kind"], "statement")
        self.assertEqual(w["data"], {"app": "com.example.notes", "source": "xiaohe", "kind": "typing", "auto": False,
                                     "context": {"text": "会议纪要：", "speaker": "third_party"}})  # 前文放在 data 里、标成第三方
        self.assertEqual(w["at"], 1000.0)  # 记的是这一段开始的时间
        self.assertNotIn("会议纪要", w["text"])

    def test_换应用_换引擎_隔太久就断开(self):
        g = Rig()
        g.r.committed(commit("一", id=1, app="a"))
        g.r.committed(commit("二", id=2, app="b"))                    # 换应用
        g.r.committed(commit("三", id=3, app="b", source="voice", kind="hotkey"))  # 换引擎
        g.wait(personal.GAP + 1)
        g.r.committed(commit("四", id=4, app="b", source="voice", kind="hotkey"))  # 隔太久
        g.r.close()
        self.assertEqual(g.texts(), ["一", "二", "三", "四"])
        self.assertEqual(g.topics(personal.COMMIT)[2]["data"]["kind"], "hotkey")

    def test_前文对不上就断开_中间有不经输入法的字(self):
        g = Rig()
        g.r.committed(commit("我觉得", id=1, context=""))
        # 英文模式下敲了 Claude（不经输入法，不转过来），前文里看得到
        g.r.committed(commit("很好", id=2, context="我觉得 Claude "))
        g.r.close()
        self.assertEqual(g.texts(), ["我觉得", "很好"])

    def test_换了输入框_前文是空的也断开(self):
        g = Rig()
        g.r.committed(commit("你好", id=1, context="x"))
        g.r.committed(commit("再见", id=2, context=""))
        g.r.close()
        self.assertEqual(g.texts(), ["你好", "再见"])

    def test_前文比这一段长或短都认得出是接着的(self):
        g = Rig()
        g.r.committed(commit("甲" * 300, id=1, context="前面"))
        g.r.committed(commit("乙", id=2, context="甲" * 200))  # 前文只给最后 200 字
        g.r.close()
        self.assertEqual(g.texts(), ["甲" * 300 + "乙"])

    def test_壳在中英文之间加的空格留在记录里(self):
        g = Rig()
        g.r.committed(commit("你好", id=1, context=""))
        g.r.committed(commit("hello", id=2, context="你好 "))
        g.r.close()
        self.assertEqual(g.texts(), ["你好 hello"])

    def test_标点接在语音那一段后面_单独一个标点不成一段(self):
        g = Rig()
        g.r.committed(commit("，", id=1, kind="punctuation"))
        g.r.committed(commit("今天开会", id=2, source="voice", kind="hotkey", context=""))
        g.r.committed(commit("。", id=3, source="xiaohe", kind="punctuation"))
        g.r.close()
        self.assertEqual(g.texts(), ["今天开会。"])

    def test_选了联想接在这一段后面(self):
        g = Rig()
        g.r.committed(commit("今天天气", id=1, context=""))
        g.r.committed({"type": "committed", "id": 2, "text": "真好", "auto": False, "kind": "predict", "source": "personal",
                       "app": "com.example.notes", "context": "今天天气"})
        g.r.close()
        self.assertEqual(g.texts(), ["今天天气真好"])
        self.assertEqual(g.topics(personal.COMMIT)[0]["data"]["source"], "xiaohe")

    def test_切走时的自动上屏单独记一条并标出来(self):
        g = Rig()
        g.r.committed(commit("我们", id=1, context=""))
        g.r.committed(commit("下午", id=2, context="我们", auto=True))
        self.assertEqual(g.texts(), ["我们", "下午"])
        self.assertEqual([w["data"]["auto"] for w in g.topics(personal.COMMIT)], [False, True])

    def test_太长就先写进去(self):
        g = Rig()
        g.r.committed(commit("字" * personal.LONGEST, id=1, context=""))
        self.assertEqual(len(g.texts()), 1)


class 改选和删改(unittest.TestCase):
    def test_没选首选记成改选(self):
        g = Rig()
        g.r.committed(commit("行云", id=1, pieces=[{"input": "xkyy", "text": "行云", "index": 1, "top": "星云"}]))
        g.r.close()  # 改选跟着这一段写
        c = g.topics(personal.CORRECTION)
        self.assertEqual(len(c), 1)
        self.assertEqual(c[0]["kind"], "activity")
        self.assertEqual(c[0]["data"]["what"], "chose")
        self.assertEqual((c[0]["data"]["text"], c[0]["data"]["top"]), ("行云", "星云"))

    def test_上屏后马上删掉的字从这一段里去掉_另记一条删改(self):
        g = Rig()
        g.r.committed(commit("今天天气", id=1, context=""))
        g.r.committed(commit("，", id=2, kind="punctuation"))
        g.r.deleted({"type": "deleted", "after": 1, "count": 3, "followed_by": "，"})  # 删掉"，"和"天气"
        g.r.committed(commit("下雨", id=3, context="今天"))
        g.r.close()
        self.assertEqual(g.texts(), ["今天下雨"])
        c = g.topics(personal.CORRECTION)[0]
        self.assertEqual(c["data"]["what"], "deleted")
        self.assertEqual(c["data"]["deleted"], "天气，")

    def test_删的不在手上这一段里_只记删了几个字(self):
        g = Rig()
        g.r.deleted({"type": "deleted", "after": 9, "count": 2})
        self.assertEqual(g.topics(personal.CORRECTION)[0]["text"], "删掉了刚上屏的 2 个字")

    def test_忘掉候选记成用户的陈述(self):
        g = Rig()
        g.r.forget({"type": "forget", "input": "xkyy", "text": "行云", "source": "xiaohe"})
        f = g.topics(personal.FORGET)
        self.assertEqual(len(f), 1)
        self.assertEqual(f[0]["kind"], "statement")
        self.assertEqual(f[0]["data"]["text"], "行云")


class 凭证只遮那一串(unittest.TestCase):
    """顶层 ADR 0013：凭证只遮那一串、其余照记，不丢整段；健康这类标上类别，不藏。"""

    def test_一段里有凭证_只遮那一串_其余照记(self):
        g = Rig()
        g.r.committed(commit("我的密码是", id=1, context=""))
        g.r.committed(commit("口令8z", id=2, context="我的密码是"))
        g.r.close()
        self.assertEqual(g.texts(), ["我的密码是〔密码〕"])

    def test_改选_删改_忘掉里的也遮(self):
        g = Rig()
        g.r.committed(commit("口令8z", id=1, auto=True, pieces=[{"input": "mm", "text": "口令8z", "index": 1, "top": "口令"}]))
        g.r.forget({"type": "forget", "input": "mm", "text": "口令8z"})
        self.assertEqual(g.texts(), ["〔密码〕"])
        self.assertEqual(g.topics(personal.CORRECTION)[0]["data"]["text"], "〔密码〕")
        self.assertEqual(g.texts(personal.FORGET), ["不要候选「〔密码〕」"])
        self.assertNotIn("口令8z", json.dumps(g.written, ensure_ascii=False))

    def test_前文带上_标成第三方_里面的凭证也遮(self):
        g = Rig()
        g.r.committed(commit("好的", id=1, context="对方：验证码是口令8z，请回复"))
        g.r.close()
        self.assertEqual(g.topics(personal.COMMIT)[0]["data"]["context"],
                         {"text": "对方：验证码是〔密码〕，请回复", "speaker": "third_party"})

    def test_前文最多带200字(self):
        g = Rig()
        g.r.committed(commit("好", id=1, context="长" * 500))
        g.r.close()
        self.assertEqual(len(g.topics(personal.COMMIT)[0]["data"]["context"]["text"]), 200)

    def test_老版库遮不了_含凭证的整段不记(self):
        g = Rig()
        g.r.mask = lambda s: None if "口令8z" in s else s  # 老版 luoke_mem 没有 mask_secrets 时，退回 never_kept 的做法
        g.r.committed(commit("我的口令8z", id=1, context=""))
        g.r.close()
        self.assertEqual(g.written, [])

    def test_改选和删改跟在上屏后面写(self):
        g = Rig()
        g.r.committed(commit("今天", id=1, context="", pieces=[{"input": "x", "text": "今天", "index": 1, "top": "金田"}]))
        self.assertEqual(g.written, [])  # 等这一段写进去时才写
        g.r.close()
        self.assertEqual([w["topic"] for w in g.written], [personal.COMMIT, personal.CORRECTION])

    def test_健康这类标上类别写进去_改选删改带一样的类别(self):
        g = Rig()
        g.r.committed(commit("我在医院", id=1, context=""))
        g.r.committed(commit("看了心脏科", id=2, context="我在医院", pieces=[{"input": "x", "text": "看了心脏科", "index": 1, "top": "看了新章课"}]))
        g.r.committed(commit("下午", id=3, context="我在医院看了心脏科"))
        g.r.deleted({"type": "deleted", "after": 3, "count": 2})
        g.r.close()
        self.assertEqual(g.texts(), ["我在医院看了心脏科"])
        self.assertEqual([w["sensitive"] for w in g.written], [["health"]] * 3)  # 上屏、改选、删改

    def test_忘掉候选也按类别标(self):
        g = Rig()
        g.r.forget({"type": "forget", "input": "x", "text": "医院"})
        self.assertEqual(g.written[0]["sensitive"], ["health"])

    def test_用的是记忆自带的判断(self):
        from luoke_mem import never_kept, sensitive_kinds
        self.assertTrue(never_kept("验证码 123456"))
        self.assertFalse(never_kept("我在医院"))
        self.assertEqual(sensitive_kinds("我在医院"), ["health"])
        self.assertEqual(sensitive_kinds("明天下午开会"), [])


class 写记忆(unittest.TestCase):
    def test_敏感的记录写进去时标上类别_联想照样用(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            before = len(personal.history.texts)
            store = personal.Store(path)
            store.record(personal.COMMIT, "statement", "我在医院", {"app": "a"}, time.time(), sensitive=["health"])
            store.record(personal.COMMIT, "statement", "明天开会", {"app": "a"}, time.time())
            store.close(timeout=5)
            import sqlite3
            rows = sqlite3.connect(path).execute("SELECT text, sensitive FROM records ORDER BY id").fetchall()
            self.assertEqual(rows[0][0], "我在医院")
            self.assertIn("health", rows[0][1])
            self.assertFalse(rows[1][1])
            self.assertEqual(personal.history.texts[before:], ["我在医院", "明天开会"])  # 联想用全部写过的（顶层 ADR 0013）

    def test_真的库_凭证只遮那一串_前文标成第三方写进去(self):
        import luoke_mem
        if not hasattr(luoke_mem, "mask_secrets"):
            self.skipTest("老版 luoke_mem 没有 mask_secrets")
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            store = personal.Store(path)
            r = personal.Recorder(store.record, luoke_mem.mask_secrets, kinds=luoke_mem.sensitive_kinds)
            r.committed(commit("验证码是 482913，我家邮编 00427", id=1, context="对方：你的验证码是 777321"))
            r.close()
            store.close(timeout=5)
            mem = Memory(path, tool=personal.TOOL)
            rec = mem.records(topic=personal.COMMIT)[0]
            mem.close()
            self.assertEqual(rec["text"], "验证码是 〔验证码〕，我家邮编 00427")  # 邮编不算凭证
            self.assertEqual(rec["data"]["context"]["speaker"], "third_party")
            self.assertNotIn("777321", rec["data"]["context"]["text"])

    def test_在后台写_关之前排着的都写完(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            store = personal.Store(path)
            store.record(personal.COMMIT, "statement", "你好", {"app": "a"}, time.time())
            store.record(personal.CORRECTION, "activity", "删掉了刚上屏的「好」", {"what": "deleted"}, time.time())
            store.close(timeout=5)
            mem = Memory(path, tool=personal.TOOL)
            self.assertEqual([r["text"] for r in mem.records(topic=personal.COMMIT)], ["你好"])
            self.assertEqual(len(mem.records(topic=personal.CORRECTION)), 1)
            mem.close()

    def test_打不开记忆也不影响别的(self):
        store = personal.Store("/nonexistent/dir/that/cannot/be/made/mem.db")
        store.record(personal.COMMIT, "statement", "你好", {}, time.time())
        store.close(timeout=5)
        self.assertTrue(store.broken)
        self.assertEqual(store.status, "broken")

    def test_记忆文件比带的库新时报_too_new(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            Memory(path, tool="x").close()
            import sqlite3
            c = sqlite3.connect(path)
            c.execute("PRAGMA user_version=5000")  # 像是更新的 luoke_mem 写过
            c.commit()
            c.close()
            store = personal.Store(path)
            store.record(personal.COMMIT, "statement", "你好", {}, time.time())
            store.close(timeout=5)
            self.assertEqual(store.status, "too_new")

    def test_保留期的选项(self):
        self.assertIsNone(personal.keep_days({"keep": ["forever"]}))
        self.assertIsNone(personal.keep_days({}))
        self.assertEqual(personal.keep_days({"keep": ["90"]}), 90)


FAKE_SCORER = r"""
import json, sys, time
print(json.dumps({"ready": "fake"}), flush=True)
for line in sys.stdin:
    req = json.loads(line)
    if "branches" in req:  # 联想（通用续写，逐个 token）：有把握的"下午开会"、没把握的"乱码"
        print(json.dumps({"branches": [
            {"tokens": [{"text": "下午", "logprob": -0.5}, {"text": "开会", "logprob": -1.5}], "finish": "length"},
            {"tokens": [{"text": "乱", "logprob": -9.0}, {"text": "码", "logprob": -11.0}], "finish": "length"}], "ms": 1},
            ensure_ascii=False), flush=True)
        continue
    if req["ctx"] == "慢":
        time.sleep(0.5)
    if req["ctx"] == "退出":
        sys.exit(1)
    print(json.dumps({"lp": [-float(len(c)) for c in req["cands"]], "ms": 1}), flush=True)
"""


class 模型打分(unittest.TestCase):
    """打分器在子进程里（这里用一个假的），转问排队、按顺序算，答复从打分线程发回。"""

    def setUp(self):
        self.replies = []
        self.real_send = personal.send
        personal.send = self.replies.append
        self.dir = tempfile.TemporaryDirectory()
        fake = os.path.join(self.dir.name, "fake_scorer.py")
        open(fake, "w").write(FAKE_SCORER)
        self.scorer = personal.Scorer([sys.executable, fake])
        self.old_timeout = personal.Scorer.TIMEOUT
        personal.Scorer.TIMEOUT = 0.3

    def tearDown(self):
        personal.send = self.real_send
        personal.Scorer.TIMEOUT = self.old_timeout
        self.scorer.proc.kill()
        self.dir.cleanup()

    def wait_ready(self):
        for _ in range(100):
            if self.scorer.state == "ready":
                return
            time.sleep(0.02)
        self.fail("打分器没就绪")

    def ask(self, id, ctx, cands):
        self.scorer.ask({"type": "ask", "id": id, "from": "xiaohe", "method": "score", "params": {"context": ctx, "candidates": cands}})

    def reply(self, id, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            for r in self.replies:
                if r["id"] == id:
                    return r
            time.sleep(0.01)
        self.fail("没有答复 %d" % id)

    def test_加载好之前答not_ready_之后按候选给对数概率(self):
        # 刚起来时可能还没读到 ready
        if self.scorer.state == "loading":
            self.ask(1, "今天", ["天气"])
            self.assertEqual(self.reply(1)["error"]["code"], "not_ready")
        self.wait_ready()
        self.ask(2, "今天", ["天气", "天七好"])
        self.assertEqual(self.reply(2)["result"], {"logprobs": [-2.0, -3.0]})
        self.ask(3, "", [])  # 空的：引擎用它试试能不能打分
        self.assertEqual(self.reply(3)["result"], {"logprobs": []})

    def test_超时的答复晚到时丢掉_不串到下一次(self):
        self.wait_ready()
        self.ask(1, "慢", ["甲"])
        self.assertEqual(self.reply(1)["error"]["code"], "timeout")
        self.ask(2, "快", ["乙乙"])
        self.assertEqual(self.reply(2)["result"], {"logprobs": [-2.0]})

    def test_排队太久的不算(self):
        self.wait_ready()
        self.scorer.jobs.put((time.monotonic() - 5, {"type": "ask", "id": 9, "params": {"context": "", "candidates": ["甲"]}}))
        self.assertEqual(self.reply(9)["error"]["code"], "expired")

    def test_打分器退出了答不可用(self):
        self.wait_ready()
        self.ask(1, "退出", ["甲"])
        self.assertEqual(self.reply(1)["error"]["code"], "unavailable")
        self.ask(2, "今天", ["甲"])
        self.assertEqual(self.reply(2)["error"]["code"], "unavailable")

    def test_联想先给用户自己写过的_再给模型有把握的(self):
        self.wait_ready()
        self.scorer.ask_continuations({"type": "ask", "id": 4, "params": {"context": "我们明天"}}, ["上午"])
        self.assertEqual(self.reply(4)["result"], {"candidates": ["上午", "下午", "下午开会"]})

    def test_经主控打分时_本机的打分进程闲久了就停掉(self):
        self.wait_ready()
        old = (personal.scorer, personal.scorer_mode)
        personal.scorer, personal.scorer_mode = self.scorer, "auto"
        try:
            personal.stop_idle_local()
            self.assertIs(personal.scorer, self.scorer)  # 刚用过，不停
            self.scorer.last_used -= personal.LOCAL_IDLE + 1
            personal.stop_idle_local()
            self.assertIsNone(personal.scorer)
            self.assertEqual(self.scorer.state, "stopped")
            self.scorer.proc.wait(timeout=5)
        finally:
            personal.scorer, personal.scorer_mode = old

    def test_经主控打分时要退回本机才起本机的打分进程(self):
        started = []
        old = (personal.scorer, personal.scorer_options, personal.start_scorer)
        personal.scorer, personal.scorer_options = None, {"model": "x"}
        personal.start_scorer = started.append
        try:
            personal.ensure_local()
            self.assertEqual(started, [{"model": "x"}])
        finally:
            personal.scorer, personal.scorer_options, personal.start_scorer = old

    def test_没有打分器时答不可用(self):
        old = (personal.scorer, personal.scorer_mode)
        personal.scorer, personal.scorer_mode = None, "local"
        try:
            personal.on_ask({"type": "ask", "id": 5, "method": "score", "params": {"candidates": ["甲"]}})
        finally:
            personal.scorer, personal.scorer_mode = old
        self.assertEqual(self.reply(5)["error"]["code"], "unavailable")


class 模型的联想(unittest.TestCase):
    def test_续写到了字数上限退回上一个token的边界_碰到标点截在标点前(self):
        # 碰到过"结论和方法建"：截法归输入法，不在词中间断
        b = [{"tokens": [{"text": "结论", "logprob": -1.0}, {"text": "和方法", "logprob": -0.5}, {"text": "建议", "logprob": -0.2}]},
             {"tokens": [{"text": "特点", "logprob": -1.2}, {"text": "，", "logprob": -0.1}, {"text": "比如", "logprob": -0.3}]},
             {"tokens": [{"text": "", "logprob": -2.0}, {"text": "，", "logprob": -0.1}]},
             {"tokens": [{"text": "结论", "logprob": -3.0}, {"text": "和方法", "logprob": -0.5}]}]
        got = personal.continuations_from_branches(b)
        self.assertEqual([g[0] for g in got], ["特点", "结论和方法"])  # 空的丢掉，文字一样的只留一个；按对数概率之和排
        self.assertEqual(got[1][2:], ("结论", -1.0))

    def test_把握大的开头的词_加上最有把握的那句续写(self):
        cont = [["下午开会", -2.0, "下午", -0.5], ["上午", -1.5, "上午", -1.5], ["开会吧", -3.0, "开", -2.0], ["乱码", -20.0, "乱", -9.0]]
        self.assertEqual(personal.model_candidates(cont), ["下午", "下午开会", "上午", "开"])

    def test_对下一个词没把握就不给(self):
        self.assertEqual(personal.model_candidates([["下午", -2.0, "下午", -2.0]]), [])  # 概率 0.14 < 0.2

    def test_开头不是汉字的不要(self):
        self.assertEqual(personal.model_candidates([["CA", -0.5, "CA", -0.2]]), [])
        self.assertEqual(personal.model_candidates([["CA", -0.5, "CA", -0.2], ["因此", -1.0, "因此", -0.9]]), ["因此"])


class 用户自己写过的(unittest.TestCase):
    def setUp(self):
        self.h = personal.History()

    def test_前文末尾的几个字后面常接什么(self):
        for t in ["我们明天下午开会", "明天下午三点见", "明天上午", "后天下午"]:
            self.h.add(t)
        self.assertEqual(self.h.predict("那我们明天"), ["下午开会"])        # 末尾"我们明天"只出现过一次
        self.assertEqual(self.h.predict("回头见，明天"), ["下午"])          # 只对上"明天"：三种接法里"下午"出现了两次

    def test_只对上两个字时要出现两次才算(self):
        self.h.add("天气很好")
        self.assertEqual(self.h.predict("今天气"), [])                      # "天气"只出现一次
        self.h.add("天气不错")
        self.assertEqual(sorted(self.h.predict("今天气")), [])             # 两种接法各一次，都不够
        self.h.add("天气很好")
        self.assertEqual(self.h.predict("今天气"), ["很好"])

    def test_接到标点为止_最多六个字(self):
        self.h.add("我们一起去吃好吃的火锅吧，好不好")
        self.assertEqual(self.h.predict("我们一起"), ["去吃好吃的火"])
        self.h.add("然后，再说")
        self.assertEqual(self.h.predict("那就然后"), [])                    # 后面紧跟着标点

    def test_前文末尾是标点时不找(self):
        self.h.add("好的，明天见")
        self.assertEqual(self.h.predict("好的，"), [])

    def test_从记忆里读来的放在前面_太多时去掉最早的(self):
        h = personal.History(size=3)
        h.add("新的一句")
        h.add_older(["很早的", "早的"])
        self.assertEqual(h.texts, ["很早的", "早的", "新的一句"])
        h.add("又一句")
        self.assertEqual(h.texts, ["早的", "新的一句", "又一句"])


class 经主控打分(unittest.TestCase):
    """转问主控（luoke-core）的打分：发 to: hub 的转问，答复从标准输入回来；主控不行时按 retry_after 交给本机。"""

    def setUp(self):
        self.sent = []
        self.real_send = personal.send
        personal.send = self.sent.append
        self.hub = personal.HubRelay()

    def tearDown(self):
        personal.send = self.real_send

    def ask(self, id=1):
        return {"type": "ask", "id": id, "from": "xiaohe", "method": "score", "params": {"context": "今天", "candidates": ["天气"]}}

    def test_转问主控_答复转回发问的引擎(self):
        self.hub.score(self.ask(), lambda a: self.fail("不该交给本机"))
        out = self.sent[-1]
        self.assertEqual((out["to"], out["method"], out["params"]["task"]), ("hub", "score", "luoke-ime.rerank"))
        self.hub.on_reply({"type": "reply", "id": out["id"], "result": {"logprobs": [-1.5], "model": "m", "cache_hit": True, "ms": 3}})
        self.assertEqual(self.sent[-1], {"type": "reply", "id": 1, "result": {"logprobs": [-1.5], "cache_hit": True, "via": "hub", "slow": False}})

    def test_主控在加载时这一次不重排_不起本机的模型(self):
        local = []
        self.hub.score(self.ask(), local.append)
        self.hub.on_reply({"type": "reply", "id": self.sent[-1]["id"], "error": {"code": "not_ready", "message": "", "retry_after": 2}})
        self.assertEqual(local, [])
        self.assertEqual(self.sent[-1]["error"]["code"], "not_ready")
        self.assertFalse(self.hub.up)
        n = len(self.sent)
        self.hub.score(self.ask(2), local.append)  # 2 秒内也不交给本机、不问主控
        self.assertEqual((local, len(self.sent)), ([], n + 1))
        self.assertEqual(self.sent[-1]["error"]["code"], "not_ready")
        self.hub.down_until = 0
        self.hub.score(self.ask(3), local.append)
        self.assertEqual(self.sent[-1]["to"], "hub")

    def test_主控真的不可用时交给本机_过了重试时间再试主控(self):
        local = []
        self.hub.score(self.ask(), local.append)
        self.hub.on_reply({"type": "reply", "id": self.sent[-1]["id"], "error": {"code": "unavailable", "message": "连不上"}})
        self.assertEqual(len(local), 1)
        n = len(self.sent)
        self.hub.score(self.ask(2), local.append)
        self.assertEqual((len(local), len(self.sent)), (2, n))

    def test_主控标了慢就随打分答复告诉引擎(self):
        self.hub.check_tasks(every=0)
        q = self.sent[-1]
        self.assertEqual((q["method"], q["params"]), ("tasks", {}))
        self.hub.on_reply({"type": "reply", "id": q["id"], "result": {"tasks": {"luoke-ime.rerank": {"slow": {"measured_ms": 152, "threshold_ms": 124}}}}})
        self.assertTrue(self.hub.slow)
        self.hub.score(self.ask(), lambda a: self.fail("不该交给本机"))
        self.hub.on_reply({"type": "reply", "id": self.sent[-1]["id"], "result": {"logprobs": [-1.0], "cache_hit": True}})
        self.assertTrue(self.sent[-1]["result"]["slow"])
        self.hub.check_tasks(every=0)
        self.hub.on_reply({"type": "reply", "id": self.sent[-1]["id"], "result": {"tasks": {"luoke-ime.rerank": {"slow": None}}}})
        self.assertFalse(self.hub.slow)

    def test_一起来就请主控预热(self):
        self.hub.warmup()
        self.assertEqual([(m["method"], m["params"]["task"]) for m in self.sent], [("warmup", "luoke-ime.rerank"), ("warmup", "luoke-ime.predict")])
        self.hub.on_reply({"type": "reply", "id": self.sent[0]["id"], "result": {"accepted": True}})
        self.assertEqual(len(self.sent), 2)  # 不用答复

    def test_请求本身不对不算主控不可用(self):
        local = []
        self.hub.score(self.ask(), local.append)
        self.hub.on_reply({"type": "reply", "id": self.sent[-1]["id"], "error": {"code": "invalid_request", "message": "", "retry_after": None}})
        self.assertEqual(len(local), 1)  # 这一次交给本机
        self.assertTrue(self.hub.up)      # 下一次照样先问主控

    def test_联想经主控_挑法和本机一样_接在自己写过的后面(self):
        self.hub.predict({"type": "ask", "id": 5, "params": {"context": "今天天气"}}, ["很好"], lambda a: self.fail("不该交给本机"))
        out = self.sent[-1]
        # 主控只做通用续写：开头个数、最多几个 token、停止串由输入法传；截和挑在这边
        self.assertEqual(out["method"], "continue")
        self.assertEqual({k: out["params"][k] for k in ("task", "context", "k", "max_tokens")},
                         {"task": "luoke-ime.predict", "context": "今天天气", "k": 8, "max_tokens": 6})
        self.assertIn("。", out["params"]["stop"])
        self.hub.on_reply({"type": "reply", "id": out["id"], "result": {"branches": [
            {"tokens": [{"text": "真", "logprob": -0.2}, {"text": "好", "logprob": -0.2}, {"text": "。", "logprob": -0.1}], "finish": "stop"},
            {"tokens": [{"text": "不错", "logprob": -1.0}], "finish": "length"}]}})
        self.assertEqual(self.sent[-1]["result"], {"candidates": ["很好", "真", "真好", "不错"]})

    def test_老主控没有续写时退回旧的联想(self):
        self.hub.predict({"type": "ask", "id": 7, "params": {"context": "今天天气"}}, [], lambda a: self.fail("不该交给本机"))
        self.hub.on_reply({"type": "reply", "id": self.sent[-1]["id"],
                           "error": {"code": "invalid_request", "message": "没有这个端点：POST /tasks/luoke-ime.predict/v1/continue"}})
        out = self.sent[-1]
        self.assertEqual((out["method"], out["params"]), ("predict", {"task": "luoke-ime.predict", "context": "今天天气"}))
        self.hub.on_reply({"type": "reply", "id": out["id"], "result": {"continuations": [["真好", -0.4, "真", -0.2]]}})
        self.assertEqual(self.sent[-1]["result"], {"candidates": ["真", "真好"]})

    def test_联想经主控不行时交给本机(self):
        local = []
        self.hub.predict({"type": "ask", "id": 6, "params": {"context": "x"}}, [], local.append)
        self.hub.on_reply({"type": "reply", "id": self.sent[-1]["id"], "error": {"code": "unavailable"}})
        self.assertEqual(len(local), 1)

    def test_不认识的号丢掉(self):
        self.hub.on_reply({"type": "reply", "id": 99, "result": {"logprobs": []}})
        self.assertEqual(self.sent, [])


class 整个组件(unittest.TestCase):
    def run_component(self, path, messages, options=None):
        env = dict(os.environ, LUOKE_IME_MEMORY=path) if path else {k: v for k, v in os.environ.items() if k != "LUOKE_IME_MEMORY"}
        opts = dict({"scorer": "local"}, **(options or {"keep": ["forever"]}), score=False)  # 本机打分但不起真的模型
        lines = [{"type": "hello", "protocol": 1, "options": opts, "data_dir": "/tmp"}] + messages
        p = subprocess.run([sys.executable, os.path.join(HERE, "personal.py")], input="".join(json.dumps(m, ensure_ascii=False) + "\n" for m in lines),
                           capture_output=True, text=True, env=env, timeout=20)
        return p.stdout, p.stderr

    def test_发布版没有scorer_py_选项写local也只经主控(self):
        with tempfile.TemporaryDirectory() as d:  # 照 scripts/bundle-engines.sh 组装：只有 personal.py 和 vendor/
            shutil.copy(os.path.join(HERE, "personal.py"), d)
            os.symlink(os.path.join(HERE, "vendor"), os.path.join(d, "vendor"))
            hello = {"type": "hello", "protocol": 1, "options": {"scorer": "local", "keep": ["forever"]}, "data_dir": d}
            env = {k: v for k, v in os.environ.items() if k != "LUOKE_IME_MEMORY"}
            p = subprocess.run([sys.executable, os.path.join(d, "personal.py")], input=json.dumps(hello) + "\n",
                               capture_output=True, text=True, env=env, timeout=20)
            asks = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
            self.assertIn("当 hub", p.stderr)
            self.assertNotIn("MLX", p.stderr)
            self.assertEqual({(a.get("to"), a.get("method")) for a in asks}, {("hub", "warmup")})

    def test_上屏写进记忆_退出时手上的那一段也写进去_标准错误里没有用户的字(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            out, err = self.run_component(path, [
                commit("我们明天", id=1, context="会议纪要："),
                commit("开会", id=2, context="会议纪要：我们明天"),
                {"type": "ask", "id": 7, "from": "xiaohe", "method": "ping", "params": {}},
            ])
            r = json.loads(out.strip())
            self.assertEqual((r["id"], r["result"]["ok"]), (7, True))
            self.assertIn(r["result"]["memory"], ("pending", "ok"))
            mem = Memory(path, tool=personal.TOOL)
            recs = mem.records(topic=personal.COMMIT)
            self.assertEqual([r["text"] for r in recs], ["我们明天开会"])
            self.assertEqual(recs[0]["speaker"], "user")
            mem.close()
            self.assertNotIn("我们", err)
            self.assertNotIn("会议", err)

    def test_设了保留期就删掉过期的_被理解引用的留下(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            mem = Memory(path, tool=personal.TOOL)
            old = "2020-01-01 10:00:00"
            gone = mem.record("user", "statement", "很早以前的话", topic=personal.COMMIT, happened_at=old)
            cited = mem.record("user", "statement", "螺壳输入法", topic=personal.COMMIT, happened_at=old)
            mem.conclude("term", "螺壳输入法", cites=[cited])
            forgot = mem.record("user", "statement", "不要候选「行云」", topic=personal.FORGET, happened_at=old)
            mem.close()
            self.run_component(path, [], options={"keep": ["30"]})
            mem = Memory(path, tool=personal.TOOL)
            left = {r["id"] for r in mem.records()}
            mem.close()
            self.assertNotIn(gone, left)
            self.assertIn(cited, left)   # 常用说法的依据留下
            self.assertIn(forgot, left)  # 忘掉候选是用户的选择，不随保留期删

    def test_一直保留时什么都不删(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            mem = Memory(path, tool=personal.TOOL)
            rid = mem.record("user", "statement", "很早以前的话", topic=personal.COMMIT, happened_at="2020-01-01 10:00:00")
            mem.close()
            self.run_component(path, [])
            mem = Memory(path, tool=personal.TOOL)
            self.assertEqual([r["id"] for r in mem.records()], [rid])
            mem.close()

    def test_联想用上记忆里以前写过的(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "mem.db")
            mem = Memory(path, tool=personal.TOOL)
            for t in ["我们明天下午开会", "明天下午见"]:
                mem.record("user", "statement", t, topic=personal.COMMIT, data={"auto": False})
            mem.close()
            out, _ = self.run_component(path, [{"type": "ask", "id": 3, "from": "shell", "method": "predict", "params": {"context": "好，明天"}}])
            # 记忆是在后台读进来的：第一次问时可能还没读完，这里只要求答复格式对、读完以后能用上
            r = json.loads(out.strip().splitlines()[-1])
            self.assertEqual(r["id"], 3)
            self.assertIn("candidates", r["result"])

    def test_默认只经主控打分_不起本机的打分进程(self):
        # 发布版没有本机退路：选项里没写 scorer 时，打分转给主控
        out, err = self.run_component(None, [
            {"type": "ask", "id": 3, "from": "xiaohe", "method": "score", "params": {"context": "我们", "candidates": ["明天"]}},
        ], options={"scorer": None})
        asks = [json.loads(l) for l in out.splitlines() if l.strip()]
        self.assertIn(("warmup", "luoke-ime.rerank"), [(a.get("method"), a["params"].get("task")) for a in asks if a.get("to") == "hub"])
        score = [a for a in asks if a.get("to") == "hub" and a.get("method") == "score"]
        self.assertEqual(score[0]["params"]["candidates"], ["明天"])
        self.assertNotIn("打分进程", err)

    def test_没声明记忆时不写_照样答转问(self):
        out, _ = self.run_component(None, [commit("你好", id=1), {"type": "ask", "id": 1, "from": "x", "method": "ping"}])
        self.assertIn('"ok":true', out)


if __name__ == "__main__":
    unittest.main()
