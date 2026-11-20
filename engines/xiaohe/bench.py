#!/usr/bin/python3
"""小鹤双拼引擎的准确率和速度评测：经引擎协议，跟壳的用法一样。

语料是 TSV：类别、前文（- 表示没有，⏎ 表示换行）、按键、正确结果……（# 开头的行跳过）。
测全拼时用 --engine ../quanpin，按键一列换成全拼（不带空格）。

  ./bench.py 语料.tsv                 每条一次询问：先给的、不标 more 的、最后一份答复的首选准确率和用时
  ./bench.py 语料.tsv --typing 120    按 120 ms 一个键逐键询问（壳就是这样问的），从最后一个键算用时；
                                      并照壳的规则算停顿 0 / 100 / 200 ms 后按空格时上屏的是哪一份、对不对
  ./bench.py 语料.tsv --typing 0      逐键询问，每个键都等引擎答完再打下一个（相当于引擎总是来得及；结果是确定的）
  --dump FILE  每条一行 JSON：at（最后一个键的 Unix 时间，秒）、按键、前文、正确结果、先给的 / 不标 more 的 / 最后一份首选、
               ms（每份答复相对最后一个键的到达时间，毫秒）
  --limit N  只用前 N 条；--min-syllables N  只用至少 N 个音节的
  --result FILE  照 luoke-core V1 的证据格式写一份 JSON（配件版本、评测集哈希、模型和任务参数、机器、逐条对错和用时，
               不带语料原文），给主控的发布脚本读
引擎要先编译好（./build.sh）。--profile 文件里有引擎每次重排的各部分用时。
模型打分在个人化组件里：bench 像壳一样起一个（--personal，默认 ../personal），把引擎的转问转给它、答复转回来；
不给它记忆的路径，测的时候什么都不写进记忆。
--scorer hub|auto 让个人化组件经主控（luoke-core）打分：bench 也像壳一样把它 to: hub 的转问转给主控（--hub 是主控的 socket，
必须写明，不退回默认的位置），最后报主控那边的用时和前缀缓存命中率。主控只认登记过的配件版本，用 --accessory luoke-ime/<版本> 报（默认 luoke-ime/bench）。
"""
import argparse
import csv
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

SPACE_WAIT = 0.150  # 壳按空格时最多等补发多久
# 主控改过名（旧版是 螺壳主控.app，现在是 螺壳.app）：新名字先找，旧名字也认
# 主控 beta1 起装进系统的 /Applications（~/Applications 也认）：两处都找，新旧名字都认，核对 bundle id
def _hub_python():
    import plistlib
    for root in ("/Applications", os.path.expanduser("~/Applications")):
        for name in ("螺壳.app", "螺壳主控.app"):
            app = os.path.join(root, name)
            try:
                with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
                    if plistlib.load(f).get("CFBundleIdentifier") != "ai.luoke.core":
                        continue
            except OSError:
                continue
            py = os.path.join(app, "Contents/Resources/python/bin/python3")
            if os.path.exists(py):
                return py
    return "/Applications/螺壳.app/Contents/Resources/python/bin/python3"


HUB_PYTHON = _hub_python()


def resolve_run(run):
    """照壳的做法解析引擎说明的 run：luoke-python 是主控带的 Python（加 -B -E -s -u），没装主控时用 PATH 里的 python3。"""
    if run and run[0] == "luoke-python":
        py = os.path.realpath(HUB_PYTHON) if os.path.exists(HUB_PYTHON) else "python3"
        return [py, "-B", "-E", "-s", "-u"] + run[1:]
    return run


NOT_EVALUATED = 3  # 退出码：没评成（主控拒了打分、引擎没答复），和"评完了但没过"分开，不写证据


def not_evaluated(reason):
    """评测条件不满足、结果说明不了准确率：照"没评成"退出，不写 --result（luoke-core 的发布脚本据此记"没评成"，不记"没过"）。"""
    print("没评成：" + reason, file=sys.stderr, flush=True)
    os._exit(NOT_EVALUATED)  # 引擎、个人化组件是子进程：直接退出，管道断了它们自己会退


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--typing", type=float, metavar="MS", help="逐键询问，键间隔毫秒")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--min-syllables", type=int, default=0)
    ap.add_argument("--profile", metavar="FILE", help="把引擎的标准错误写到这个文件")
    ap.add_argument("--dump", metavar="FILE", help="每条的结果写成 JSON 行")
    ap.add_argument("--result", metavar="FILE", help="证据（luoke-core V1 的格式，不带语料原文）写成 JSON")
    ap.add_argument("--engine", metavar="DIR", help="要测的引擎文件夹（默认是 bench.py 所在的小鹤双拼；全拼是 ../quanpin）")
    ap.add_argument("--personal", metavar="DIR", help="个人化组件的文件夹（默认 bench.py 旁边的 ../personal）")
    ap.add_argument("--scorer", choices=("local", "hub", "auto"), help="个人化组件在哪打分（默认本机；它自己的默认是只经主控）")
    ap.add_argument("--engine-option", metavar="KEY=VALUE", action="append", default=[],
                    help="交给引擎的选项（hello 里的 options），可以写几次，比如 budget=small（每一步少给模型一半候选）")
    ap.add_argument("--data", metavar="DIR", help="引擎的数据目录（默认临时目录里按引擎固定的一份：RIME 编好的词库下次接着用，"
                    "M1 上编一次要几分钟；bench 不发上屏和忘掉，记住的改选总是空的，结果不受影响）")
    ap.add_argument("--hub-dump", metavar="FILE", help="每次转给主控的打分写一行 JSON：at（Unix 时间）、批数、候选数、前文长度、主控报的 ms、往返 ms、是否命中前缀缓存、拒绝的原因码")
    ap.add_argument("--score-delay", type=float, default=0, metavar="MS",
                    help="每次打分的答复晚这么多毫秒再交给引擎：在快的机器上模拟慢的（比如 16 GB 测试机（M1）上螺壳每次打分约 66 ms）")
    ap.add_argument("--hub", metavar="SOCKET", help="主控的 socket（--scorer hub / auto 时必填，不退回默认的位置）")
    ap.add_argument("--accessory", default="luoke-ime/bench", help="经主控时报的配件版本（X-Luoke-Accessory）：主控只认登记过的")
    args = ap.parse_args()
    if args.scorer in ("hub", "auto") and not args.hub:
        ap.error("--scorer hub / auto 要用 --hub 写明连哪个主控（不碰日常在用的实例）")
    if args.hub and not os.path.exists(args.hub):
        ap.error("找不到主控的 socket：%s" % args.hub)
    if args.result:  # 写证据用仓库里的 scripts/evidence.py：先导入，别测完了才发现找不到
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
        import evidence

    rows = [r for r in csv.reader(open(args.corpus, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE) if r and not r[0].startswith("#")]
    rows = [r for r in rows if len(r[2]) // 2 >= args.min_syllables][: args.limit]

    here = os.path.abspath(args.engine) if args.engine else os.path.dirname(os.path.abspath(__file__))
    run = json.load(open(os.path.join(here, "engine.json"), encoding="utf-8"))["run"]
    data = args.data or os.path.join(tempfile.gettempdir(), "luoke-bench", os.path.basename(here.rstrip("/")))
    os.makedirs(data, exist_ok=True)
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LUOKE_IME_DATA": data}
    env.update((k, v) for k, v in os.environ.items() if k.startswith("LUOKE_XIAOHE_"))  # 引擎的调试开关
    env["LUOKE_XIAOHE_PROFILE"] = "1"  # 引擎每处理完一条询问会在标准错误里说"答完 id"
    log = open(args.profile, "w") if args.profile else None
    p = subprocess.Popen(run, cwd=here, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    answers = {}  # id → [(到达时间, 答复)]
    done = set()
    cond = threading.Condition()
    ready = threading.Event()
    model_ready = threading.Event()
    write_lock = threading.Lock()

    # 个人化组件（模型打分在它那里）：像壳一样转问
    pdir = os.path.abspath(args.personal or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "personal"))
    pman = json.load(open(os.path.join(pdir, "engine.json"), encoding="utf-8"))
    penv = dict(env, LUOKE_IME_DATA=tempfile.mkdtemp(prefix="personal-bench-"))  # 没有 LUOKE_IME_MEMORY：不写记忆
    pp = subprocess.Popen(resolve_run(pman["run"]), cwd=pdir, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=penv)
    routes = {}  # 转给个人化组件的号 → 引擎发问时的号
    delayed = set()  # 其中要晚一点交给引擎的打分（--score-delay）
    ask_no = [0]
    score_sent = {}  # 转给个人化组件的打分（有候选的）：号 → 发出的时刻
    score_stats = {"n": 0, "ms": []}  # 引擎问了几次打分、每次模型的用时（不含 --score-delay）

    def to_engine(obj):
        with write_lock:
            p.stdin.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n")
            p.stdin.flush()

    def to_personal(obj):
        with personal_lock:
            pp.stdin.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
            pp.stdin.flush()

    hub_stats = {"n": 0, "hit": 0, "ms": [], "errors": {}}

    class Unix(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(5)
            self.sock.connect(args.hub)

    def hub_call(method, path, body=None):
        c = Unix("localhost")
        c.request(method, path, body=json.dumps(body).encode() if body is not None else None,
                  headers={"X-Luoke-Accessory": args.accessory,"Content-Type": "application/json"})
        resp = c.getresponse()
        data = json.loads(resp.read() or b"{}")
        c.close()
        return resp.status, data

    hub_params = {}
    hub_dump = open(args.hub_dump, "w") if args.hub_dump else None
    hub_dump_lock = threading.Lock()

    def ask_hub(r):
        """像壳一样把个人化组件的 to: hub 转问转给主控（luoke-core V1 §2）：按任务参数分批、截短前文，结果拼起来。"""
        params = r.get("params") or {}
        task = params.get("task")
        if r.get("method") in ("warmup", "predict", "continue", "tasks"):  # 预热、联想、任务状态：照壳的做法原样转，不算进打分的统计
            try:
                if r["method"] == "tasks":
                    status, data = hub_call("GET", "/tasks")
                elif r["method"] == "warmup":
                    status, data = hub_call("POST", "/warmup", {"task": task})
                elif r["method"] == "continue":
                    status, data = hub_call("POST", "/tasks/%s/v1/continue" % task,
                                            {k: params[k] for k in ("context", "k", "max_tokens", "stop") if k in params})
                else:
                    status, data = hub_call("POST", "/tasks/%s/v1/predict" % task, {"context": params.get("context", "")})
                to_personal({"type": "reply", "id": r["id"], **({"result": data} if status < 400 else {"error": data})})
            except OSError as e:
                to_personal({"type": "reply", "id": r["id"], "error": {"code": "unavailable", "message": str(e)}})
            return
        t0, wall = time.perf_counter(), time.time()
        batches = 0
        try:
            if task not in hub_params:
                status, t = hub_call("GET", "/tasks")
                hub_params[task] = ((t.get("tasks") or {}).get(task) or {}).get("params") or {}
            batch = int(hub_params[task].get("batch") or 16)
            ctx = (params.get("context") or "")[-int(hub_params[task].get("max_chars") or 2000):]
            cands = params.get("candidates") or []
            merged = {"logprobs": [], "cache_hit": True, "ms": 0, "model": None}
            data, status = {}, 200
            for i in range(0, max(len(cands), 1), batch):
                status, data = hub_call("POST", "/tasks/%s/v1/score" % task, {"context": ctx, "candidates": cands[i:i + batch]})
                batches += 1
                if status >= 400:
                    break
                merged["logprobs"] += data.get("logprobs") or []
                merged["cache_hit"] = merged["cache_hit"] and bool(data.get("cache_hit"))
                merged["ms"] += data.get("ms") or 0
                merged["model"] = data.get("model")
        except OSError as e:
            status, data = 503, {"code": "unavailable", "message": str(e)}
        if hub_dump:
            row = {"at": round(wall, 3), "batches": batches, "candidates": len(params.get("candidates") or []),
                   "context_chars": len(params.get("context") or ""), "round_trip_ms": round((time.perf_counter() - t0) * 1000, 1)}
            if status < 400:
                row.update(ms=merged["ms"], cache_hit=merged["cache_hit"])
            else:
                row.update(code=data.get("code"))
            with hub_dump_lock:
                hub_dump.write(json.dumps(row) + "\n")
                hub_dump.flush()
        if status < 400:
            hub_stats["n"] += 1
            hub_stats["model"] = merged["model"]
            hub_stats["hit"] += bool(merged["cache_hit"])
            hub_stats["ms"].append(merged["ms"])
            out = {"type": "reply", "id": r["id"], "result": merged}
        else:
            hub_stats["errors"][data.get("code")] = hub_stats["errors"].get(data.get("code"), 0) + 1
            out = {"type": "reply", "id": r["id"], "error": {k: data.get(k) for k in ("code", "message", "retry_after")}}
        to_personal(out)

    personal_lock = threading.Lock()

    def read_personal():
        for line in pp.stdout:
            r = json.loads(line)
            if r.get("type") == "reply" and r.get("id") in routes:
                late = r["id"] in delayed
                if r["id"] in score_sent:
                    score_stats["ms"].append(time.perf_counter() - score_sent.pop(r["id"]))
                delayed.discard(r["id"])
                r["id"] = routes.pop(r["id"])
                if late and args.score_delay > 0:
                    threading.Timer(args.score_delay / 1000, to_engine, (r,)).start()
                else:
                    to_engine(r)
            elif r.get("type") == "ask" and r.get("to") == "hub":
                threading.Thread(target=ask_hub, args=(r,), daemon=True).start()

    def read_personal_err():
        for line in pp.stderr:
            if log:
                log.write("个人化 ⟩ " + line)
                log.flush()
            if "模型已就绪" in line:
                model_ready.set()

    def read_out():
        for line in p.stdout:
            try:
                a = json.loads(line)
            except ValueError:
                print("引擎的输出不是 JSON：" + line[:80], file=sys.stderr)
                continue
            if a.get("type") == "ask":
                ask_no[0] += 1
                routes[ask_no[0]] = a["id"]
                if a.get("method") == "score" and (a.get("params") or {}).get("candidates"):
                    delayed.add(ask_no[0])
                    score_sent[ask_no[0]] = time.perf_counter()
                    score_stats["n"] += 1
                try:
                    to_personal({"type": "ask", "id": ask_no[0], "from": "bench", "method": a.get("method"), "params": a.get("params", {})})
                except OSError as e:  # 个人化组件退出了：像壳一样答不可用，别让读引擎输出的线程死掉
                    print("个人化组件写不进去：%s" % e, file=sys.stderr)
                    to_engine({"type": "reply", "id": a["id"], "error": {"code": "unavailable", "message": "个人化组件退出了"}})
                continue
            with cond:
                answers.setdefault(a.get("id"), []).append((time.perf_counter(), a))
                cond.notify_all()

    def read_err():
        seen = set()
        for line in p.stderr:
            if log:
                log.write(line)
                log.flush()
            if line.startswith("答完 "):
                with cond:
                    done.add(int(line.split()[1]))
                    cond.notify_all()
            elif "已就绪" in line:  # 等 RIME 就绪、引擎知道能打分了（选项关掉的那个不等）
                seen.add(line.split("已就绪")[0])
                if len(seen) >= need:
                    ready.set()

    eopts = {}
    for kv in args.engine_option:
        k, _, v = kv.partition("=")
        eopts[k] = json.loads(v) if v[:1] in "0123456789-[{tf" and v not in ("full", "small") else v
    need = (eopts.get("rime", True) is not False) + (eopts.get("rerank", True) is not False)
    if need == 0:
        ready.set()

    for f in (read_out, read_err, read_personal, read_personal_err):
        threading.Thread(target=f, daemon=True).start()

    send = to_engine  # 跟壳发的一样

    popts = dict(pman.get("options", {}).get("data", {}))
    popts["scorer"] = args.scorer or "local"  # 评测默认用本机的打分进程，经主控要写明 --scorer hub --hub
    to_personal({"type": "hello", "protocol": 1, "options": popts, "data_dir": penv["LUOKE_IME_DATA"]})
    send({"type": "hello", "protocol": 1, "options": eopts})
    model_ready.wait(180)
    next_id = [0]
    for _ in range(30):  # 引擎每隔 2 秒才再问一次能不能打分：用询问催它
        if ready.wait(2.1):
            break
        next_id[0] += 1
        send({"type": "query", "id": next_id[0], "input": "nihao", "context": ""})
    if not ready.is_set():
        if hub_stats["errors"]:  # 主控一直拒打分（模型加载不了、内存紧张）：没评成；别的（比如 RIME 没装好）照旧报错
            not_evaluated("模型一直没就绪，主控拒了打分：%s" % hub_stats["errors"])
        sys.exit("引擎没就绪（RIME 或模型）")

    def query(keys, ctx):
        next_id[0] += 1
        send({"type": "query", "id": next_id[0], "input": keys, "context": ctx})
        return next_id[0]

    def wait_done(q):
        with cond:
            if not cond.wait_for(lambda: q in done, timeout=30):
                if hub_stats["errors"]:
                    not_evaluated(f"引擎 30 秒没答完询问 {q}，其间主控拒了打分：{hub_stats['errors']}")
                sys.exit(f"引擎 30 秒没答完询问 {q}")
            # 「答完」走标准错误、答复走标准输出，两个线程读，先后不定：最终答复（不标 more 的）还没读到就再等一会儿
            cond.wait_for(lambda: any(not a.get("more") for _, a in answers.get(q, [])), timeout=2)
            return answers.get(q, [])

    def top(a, keys):
        full = [c["text"] for c in a["candidates"] if c["consume"] == len(keys)]
        return full[0] if full else None

    def at_space(got, when):
        """照壳的规则：按空格时手上的答复；标了 more 就最多再等 SPACE_WAIT。返回 (答复, 是否不必再等)。"""
        have = None
        for t, a in got:
            if t > when:
                break
            have = a
        if have is None or have.get("more"):
            for t, a in got:
                if when < t <= when + SPACE_WAIT:
                    have = a
                    if not a.get("more"):
                        break
        return have, have is not None and not have.get("more")

    GAPS = (0, 100, 200)  # 最后一个键到按空格的停顿（毫秒）
    fast_ok = settled_ok = final_ok = changed = fixed = broke = 0
    caught = dict.fromkeys(GAPS, 0)
    space_ok = dict.fromkeys(GAPS, 0)
    dump = open(args.dump, "w") if args.dump else None
    lat_first, lat_settled, lat_last = [], [], []
    items = []  # 证据里的逐条结果（不带原文）
    refused_before = sum(hub_stats["errors"].values())  # 开跑前等模型就绪时的拒绝不算
    score_stats["n"], score_stats["ms"] = 0, []  # 只算计时那段
    for r in rows:
        ctx = "" if r[1] == "-" else r[1].replace("⏎", "\n")[-120:]
        keys, gold = r[2], r[3]
        scores_before = score_stats["n"]
        if args.typing is not None:
            for i in range(1, len(keys)):
                q = query(keys[:i], ctx)
                if args.typing > 0:
                    time.sleep(args.typing / 1000)
                else:  # 0：每个键都等引擎答完（相当于引擎总是来得及），结果是确定的
                    wait_done(q)
        t, wall = time.perf_counter(), time.time()
        got = [(at - t, a) for at, a in wait_done(query(keys, ctx))]
        if not got:  # 引擎一份答复都没给（比如主控内存紧张停了打分进程，这里 got[0] 崩了）
            not_evaluated("引擎对第 %d 条一份答复都没给；主控拒了打分：%s" % (len(items) + 1, hub_stats["errors"] or "无"))
        settled = next(((at, a) for at, a in got if not a.get("more")), got[-1])
        first, mid, final = top(got[0][1], keys), top(settled[1], keys), top(got[-1][1], keys)
        lat_first.append(got[0][0])
        lat_settled.append(settled[0])
        lat_last.append(got[-1][0])
        for g in GAPS:
            a, ok = at_space(got, g / 1000)
            caught[g] += ok
            space_ok[g] += a is not None and top(a, keys) == gold
        fast_ok += first == gold
        settled_ok += mid == gold
        final_ok += final == gold
        changed += final != first
        fixed += first != gold and final == gold  # 模型改对的
        broke += first == gold and final != gold  # 模型改错的：先给的对了，被重排换掉
        item = {"i": len(items), "category": r[0], "keys": len(keys), "fast_ok": first == gold, "settled_ok": mid == gold,
                "final_ok": final == gold, "ms": [round(at * 1000) for at, _ in got]}
        if args.typing:
            item["space_ok"] = {str(g): (lambda a: a is not None and top(a, keys) == gold)(at_space(got, g / 1000)[0]) for g in GAPS}
        items.append(item)
        if dump:
            dump.write(json.dumps({"at": round(wall, 3), "keys": keys, "ctx": ctx, "gold": gold, "fast": first, "settled": mid, "final": final,
                                   "ms": [round(at * 1000) for at, _ in got], "scores": score_stats["n"] - scores_before}, ensure_ascii=False) + "\n")
        if len(items) % 50 == 0:  # 进度走标准错误：主控的发布脚本按它判断是不是停住了（不是慢）
            print(f"进度 {len(items)}/{len(rows)}", file=sys.stderr, flush=True)

    n = len(rows)
    # 计时那段里主控拒过打分（内存紧张停了打分进程、忙）：个人化组件会照 retry_after 停一阵不问主控，这一阵只是没重排的样子，
    # 准确率说明不了模型，算没评成；经主控却一次都没打成分也一样。开跑前等模型就绪时的拒绝不算
    refused = sum(hub_stats["errors"].values()) - refused_before
    if args.scorer == "hub" and hub_stats["n"] == 0:
        not_evaluated("经主控打分，可一次都没打成（主控拒了：%s）" % (hub_stats["errors"] or "无"))
    if refused > 0:
        not_evaluated("计时那段里主控拒了 %d 次打分（%s）" % (refused, hub_stats["errors"]))
    pct = lambda xs, q: sorted(xs)[min(n - 1, int(q * n))] * 1000
    print(f"n={n}  先给的首选 {100 * fast_ok / n:.1f}%  不标 more 的首选 {100 * settled_ok / n:.1f}%  最终首选 {100 * final_ok / n:.1f}%  补发改了 {changed} 条（改对 {fixed}、改错 {broke}）")
    since = "最后一个键" if args.typing is not None else "询问"
    for name, xs in (("第一份答复", lat_first), ("不标 more 的答复", lat_settled), ("最后一份答复", lat_last)):
        print(f"{since}到{name}：p50 {pct(xs, .5):.0f} ms  p90 {pct(xs, .9):.0f} ms  p99 {pct(xs, .99):.0f} ms  最长 {max(xs) * 1000:.0f} ms")
    if hub_stats["n"] or hub_stats["errors"]:
        hm = sorted(hub_stats["ms"]) or [0]
        print(f"主控打分 {hub_stats['n']} 次：前缀缓存命中 {100 * hub_stats['hit'] / max(hub_stats['n'], 1):.1f}%，"
              f"主控里的用时 p50 {hm[len(hm) // 2]:.0f} ms p90 {hm[int(len(hm) * 0.9)]:.0f} ms；拒绝 {hub_stats['errors'] or '无'}")
    if score_stats["n"]:
        sm = sorted(score_stats["ms"]) or [0]
        print(f"引擎问打分 {score_stats['n']} 次（每条 {score_stats['n'] / n:.1f} 次）：模型用时合计 {sum(sm):.1f} 秒，"
              f"p50 {sm[len(sm) // 2] * 1000:.0f} ms p90 {sm[int(len(sm) * 0.9)] * 1000:.0f} ms")
    if args.typing:
        for g in GAPS:
            print(f"停顿 {g} ms 后按空格（壳最多再等 {SPACE_WAIT * 1000:.0f} ms）：不必再等的 {100 * caught[g] / n:.1f}%，上屏的首选准确率 {100 * space_ok[g] / n:.1f}%")
    if args.result:
        via_hub = hub_stats["n"] > 0
        combo = {"scorer": "hub" if via_hub else "local", "model": hub_stats.get("model") if via_hub else os.path.basename((popts.get("model") or "").rstrip("/")) or None,
                 "params": hub_params.get("luoke-ime.rerank") if via_hub else None, "engine": os.path.basename(here.rstrip("/")),
                 "engine_options": eopts, "typing_ms": args.typing, "score_delay_ms": args.score_delay or None}
        score = {"fast_top1_pct": round(100 * fast_ok / n, 1), "settled_top1_pct": round(100 * settled_ok / n, 1),
                 "final_top1_pct": round(100 * final_ok / n, 1), "changed": changed, "fixed": fixed, "broke": broke,
                 # 硬性条目：模型改错的不超过 max(3, 1%)。打分坏了（比如分数反了）时准确率可能还过得去，这条拦得住
                 "broke_max": max(3, n // 100)}
        score["hard_ok"] = broke <= score["broke_max"]
        if args.typing:
            score["space"] = {str(g): {"caught_pct": round(100 * caught[g] / n, 1), "top1_pct": round(100 * space_ok[g] / n, 1)} for g in GAPS}
        latency = {name: {"p50_ms": round(pct(xs, .5)), "p90_ms": round(pct(xs, .9)), "p99_ms": round(pct(xs, .99))}
                   for name, xs in (("first", lat_first), ("settled", lat_settled), ("last", lat_last))}
        extra = {}
        if via_hub:
            hm = sorted(hub_stats["ms"]) or [0]
            extra["hub"] = {"n": hub_stats["n"], "prefix_cache_hit_pct": round(100 * hub_stats["hit"] / hub_stats["n"], 1),
                            "p50_ms": hm[len(hm) // 2], "p90_ms": hm[int(len(hm) * 0.9)], "errors": hub_stats["errors"]}
        evidence.write(args.result, "luoke-ime.rerank", args.corpus, combo, score, latency, items, **extra)
    p.stdin.close()
    p.wait()
    pp.stdin.close()
    pp.wait()


if __name__ == "__main__":
    main()
