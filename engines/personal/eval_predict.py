#!/usr/bin/python3
"""联想的命中率：用小鹤引擎的评测语料（类别、前文、按键、正确结果），把前文交给模型接着写，看真正接下来的那句
是不是以某个联想开头。只测模型那一路（用户自己写过的要等攒够了上屏，用博客语料测会把它当成个人化的素材）。

  ./eval_predict.py 语料.tsv [--limit N]
  ./eval_predict.py 语料.tsv --hub <主控的 socket>     经主控的联想任务（luoke-ime.predict）续写，不起本机的模型
  --result FILE  照 luoke-core V1 的证据格式写一份 JSON（不带语料原文），给主控的发布脚本读

按个人化组件挑联想的办法（personal.picked），对几个把握门槛（模型对下一个词的把握）分别报：
多少次给出了联想（壳会提示 ⇥）、给出时第一个就对的比例、前三个里有对的比例、所有询问里前三个有对的比例，以及每次用时。
"""
import argparse
import csv
import http.client
import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import personal  # noqa: E402

GATES = (0.5, 0.3, 0.2, 0.1, 0.0)  # 模型对下一个词的把握（第一个 token 的概率）
TASK = "luoke-ime.predict"
HERE = os.path.dirname(os.path.abspath(__file__))


class Hub:
    """主控（luoke-core）：HTTP/1.1 跑在 Unix socket 上（V1 §2），跟壳一样带 X-Luoke-Accessory。"""

    def __init__(self, path):
        self.path = path
        with open(os.path.join(HERE, "..", "..", "Resources", "App", "luoke-accessory.json"), encoding="utf-8") as f:
            self.accessory = "luoke-ime/" + json.load(f)["version"]

    def call(self, method, url, body=None):
        c = http.client.HTTPConnection("localhost", timeout=30)
        c.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.sock.settimeout(30)
        c.sock.connect(self.path)
        headers = {"X-Luoke-Accessory": self.accessory}
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        c.request(method, url, body=data, headers=headers)
        r = c.getresponse()
        out = json.loads(r.read() or b"{}")
        c.close()
        return r.status, out


NOT_EVALUATED = 3  # 退出码：没评成（主控拒了、一直没就绪），和评测程序自己出错分开，不写证据；和 xiaohe/bench.py 一样


def not_evaluated(reason):
    print("没评成：" + reason, file=sys.stderr, flush=True)
    sys.exit(NOT_EVALUATED)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--model", default=os.path.expanduser(personal.MODEL))
    ap.add_argument("--dump", metavar="FILE", help="每条的前文、正确结果、模型给的说法写成 JSON 行")
    ap.add_argument("--hub", metavar="SOCKET", help="经这个主控续写（必须写明，不退回默认的位置）")
    ap.add_argument("--result", metavar="FILE", help="证据（luoke-core V1 的格式，不带语料原文）写成 JSON")
    args = ap.parse_args()
    if args.hub and not os.path.exists(args.hub):
        ap.error("找不到主控的 socket：%s" % args.hub)
    if args.result:  # 写证据用仓库里的 scripts/evidence.py：先导入，别测完了才发现找不到
        sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))
        import evidence  # noqa: F401
    rows = [r for r in csv.reader(open(args.corpus, encoding="utf-8"), delimiter="\t") if r and not r[0].startswith("#")]
    rows = [r for r in rows if r[1] != "-"][: args.limit]
    if args.hub:
        return run_hub(args, rows)

    py = personal.find_python()
    if py is None:
        sys.exit("找不到能跑 MLX 的 Python（oMLX）")
    env = dict(os.environ)
    if py[1]:
        env["PYTHONPATH"] = py[1]
    p = subprocess.Popen([py[0], os.path.join(HERE, "scorer.py"), args.model], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         text=True, env=env)
    if '"ready"' not in p.stdout.readline():
        sys.exit("模型没能加载")

    def gen(ctx):
        req = personal.continue_params(ctx)
        p.stdin.write(json.dumps({"branches": req.pop("context"), **req}, ensure_ascii=False) + "\n")
        p.stdin.flush()
        return personal.continuations_from_branches(json.loads(p.stdout.readline())["branches"])
    results, ms = collect(args, rows, gen)
    p.stdin.close()
    p.wait()
    report(args, rows, results, ms, {"scorer": "local", "model": os.path.basename(args.model.rstrip("/")),
                                     "params": {"k": personal.CONT_K, "max_tokens": personal.CONT_TOKENS, "chars": personal.CONT_CHARS}})


def run_hub(args, rows):
    hub = Hub(args.hub)
    status, tasks = hub.call("GET", "/tasks")
    if status >= 400 or TASK not in (tasks.get("tasks") or {}):
        sys.exit("主控里没有 %s：%s" % (TASK, tasks))
    info = tasks["tasks"][TASK]
    hub.call("POST", "/warmup", {"task": TASK})
    seen = {}

    def gen(ctx):
        for _ in range(60):  # 主控还在加载模型时答 not_ready：等它
            status, r = hub.call("POST", "/tasks/%s/v1/continue" % TASK, personal.continue_params(ctx))
            if status < 400:
                seen["model"] = r.get("model")
                return personal.continuations_from_branches(r.get("branches"))
            if r.get("code") != "not_ready":
                not_evaluated("主控拒绝了联想：%s" % r)
            time.sleep(r.get("retry_after") or 1)
        not_evaluated("主控一直没就绪")
    results, ms = collect(args, rows, gen)
    report(args, rows, results, ms, {"scorer": "hub", "model": seen.get("model"), "params": info.get("params"),
                                     "ime": {"k": personal.CONT_K, "max_tokens": personal.CONT_TOKENS, "chars": personal.CONT_CHARS}})


def collect(args, rows, gen):
    dump = open(args.dump, "w") if args.dump else None
    results, ms = [], []
    for r in rows:
        ctx = r[1].replace("⏎", "\n")[-120:]
        gold = r[3]
        t = time.perf_counter()
        cont = gen(ctx)
        ms.append((time.perf_counter() - t) * 1000)
        results.append((gold, cont))
        if len(results) % 50 == 0:  # 进度走标准错误：主控的发布脚本按它判断是不是停住了（不是慢）
            print(f"进度 {len(results)}/{len(rows)}", file=sys.stderr, flush=True)
        if dump:
            dump.write(json.dumps({"ctx": ctx[-30:], "gold": gold, "cont": cont}, ensure_ascii=False) + "\n")
    return results, ms


def report(args, rows, results, ms, combo):
    n = len(results)
    if n == 0:
        sys.exit("语料里没有能评的条目（要带前文的）")
    ms_each = list(ms)
    ms.sort()
    print(f"n={n}  每次用时 p50 {ms[n // 2]:.0f} ms  p90 {ms[int(n * 0.9)]:.0f} ms")
    print("把握门槛  给出联想   给出时第一个对   给出时前三个有对   所有询问里前三个有对")
    gates = {}
    for gate in GATES:
        shown = top1 = top3 = 0
        for gold, cont in results:
            items = personal.picked(cont, gate=gate)[:3]
            if not items:
                continue
            shown += 1
            top1 += gold.startswith(items[0])
            top3 += any(gold.startswith(c) for c in items)
        mark = "  ← 现在用的" if gate == personal.MODEL_GATE else ""
        print(f"{gate:6.2f}   {100 * shown / n:6.1f}%   {100 * top1 / max(shown, 1):12.1f}%   {100 * top3 / max(shown, 1):14.1f}%   {100 * top3 / n:16.1f}%{mark}")
        gates[str(gate)] = {"shown_pct": round(100 * shown / n, 1), "top1_when_shown_pct": round(100 * top1 / max(shown, 1), 1),
                            "top3_when_shown_pct": round(100 * top3 / max(shown, 1), 1), "top3_pct": round(100 * top3 / n, 1)}
    if args.result:
        import evidence
        items = []
        for i, ((gold, cont), r, t) in enumerate(zip(results, rows, ms_each)):
            got = personal.picked(cont)[:3]
            items.append({"i": i, "category": r[0], "shown": bool(got), "top1": bool(got) and gold.startswith(got[0]),
                          "top3": any(gold.startswith(c) for c in got), "ms": round(t)})
        g = gates[str(personal.MODEL_GATE)]
        score = dict(g, gate=personal.MODEL_GATE, gates=gates)
        # 硬性条目：联想全坏（不出、或出的几乎都不对）时不能只算回退。单字的不给以后，出时第一个对从 41% 降到约 26%
        # （少的是单字的，省不了键）
        score["floors"] = {"shown_pct": 3, "top1_when_shown_pct": 25}
        score["hard_ok"] = all(g[k] >= v for k, v in score["floors"].items())
        evidence.write(args.result, TASK, args.corpus, combo, score, {"p50_ms": round(ms[n // 2]), "p90_ms": round(ms[int(n * 0.9)])}, items)


if __name__ == "__main__":
    main()
