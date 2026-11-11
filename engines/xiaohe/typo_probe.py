#!/usr/bin/python3
"""打错纠正的原型（只是评测，引擎里还没有）：把按键改一处的各种可能（按成相邻的键、相邻两键打反、漏一个、多一个）
都问一遍引擎，留下整串都读得通的，各取首选，连同原样按键的首选一起交模型按前文打分，挑最通顺的。
原样的按键加 bonus（对数概率）：打对的时候不该被改掉。

  ./typo_probe.py 语料.tsv [--engine .] [--bonus 0,2,4,6]

拿 variants.py 生成的 typo-xiaohe.tsv 测能救回多少，拿原来的语料测会改错多少（两份都要测）。全拼用 --engine ../quanpin
（按键是拼音去掉空格：typo-quanpin.tsv、quanpin.tsv）；双拼只留偶数个键的改法。
"""
import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "personal"))
sys.path.insert(0, HERE)
import personal  # noqa: E402
from variants import neighbors  # noqa: E402


def first_bad(keys, pairs):
    """双拼：第一个读不通的键的位置（两个键一对；末尾单独一个键是声母也算读得通）；都读得通时为 None。"""
    for i in range(0, len(keys) - 1, 2):
        if keys[i:i + 2] not in pairs:
            return i
    if len(keys) % 2 and keys[-1] not in "bpmfdtnlgkhjqxrzcsywaeoviu":
        return len(keys) - 1
    return None


def edits(keys, double=True, lo=0, hi=None):
    """改一处的各种可能；lo、hi 限定改哪些位置。"""
    out = set()
    for i, ch in enumerate(keys):
        if i < lo or (hi is not None and i >= hi):
            continue
        for n in neighbors(ch):
            out.add(keys[:i] + n + keys[i + 1:])               # 按成了相邻的键
            out.add(keys[:i + 1] + n + keys[i + 1:])           # 多按了一个相邻的键
        out.add(keys[:i] + keys[i + 1:])                       # 漏了一个
        if i + 1 < len(keys) and keys[i] != keys[i + 1]:
            out.add(keys[:i] + keys[i + 1] + keys[i] + keys[i + 2:])  # 打反了
    out.discard(keys)
    return [k for k in out if k and (not double or len(k) % 2 == 0)]


class Engine:
    def __init__(self, path):
        self.dir = tempfile.mkdtemp()
        manifest = json.load(open(os.path.join(path, "engine.json")))
        run = manifest["run"]
        cmd = [os.path.join(path, run[0])] + run[1:]
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, cwd=path)
        self.send({"type": "hello", "protocol": 1, "options": {"rerank": False}, "data_dir": self.dir})
        self.id = 0
        import time
        time.sleep(4)  # RIME 起来要一会儿

    def send(self, m):
        self.p.stdin.write(json.dumps(m, ensure_ascii=False) + "\n")
        self.p.stdin.flush()

    def top(self, keys):
        """整串都读得通时的首选（用掉全部按键的汉字候选），否则 None。"""
        self.id += 1
        self.send({"type": "query", "id": self.id, "input": keys, "context": ""})
        while True:
            m = json.loads(self.p.stdout.readline())
            if m.get("type") == "answer" and m.get("id") == self.id:
                break
        for c in m.get("candidates") or []:
            t = c["text"]
            if c["consume"] == len(keys) and all("㐀" <= ch <= "鿿" for ch in t):
                return t
        return None


class Scorer:
    """个人化组件的本机打分进程（scorer.py）：{"ctx","cands"} → {"lp"}。"""

    def __init__(self, model):
        py = personal.find_python()
        if py is None:
            sys.exit("找不到能跑 MLX 的 Python（oMLX）")
        env = dict(os.environ)
        if py[1]:
            env["PYTHONPATH"] = py[1]
        self.p = subprocess.Popen([py[0], os.path.join(HERE, "..", "personal", "scorer.py"), model], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, env=env)
        if '"ready"' not in self.p.stdout.readline():
            sys.exit("模型没能加载")

    def score(self, ctx, cands):
        self.p.stdin.write(json.dumps({"ctx": ctx, "cands": cands}, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())["lp"]

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("--engine", default=HERE)
    ap.add_argument("--bonus", default="0,2,4,6,8")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--show", action="store_true", help="逐条打出改成了什么")
    ap.add_argument("--only-unreadable", action="store_true", help="只纠读不通的（双拼）：原样读得通就不改")
    ap.add_argument("--window", type=int, help="只改第一个读不通的那对键和它前面这么多个键（双拼，配 --only-unreadable）")
    args = ap.parse_args()
    from variants import syllables, xiaohe
    pairs = {p for p in map(xiaohe, syllables()) if p}
    rows = [r for r in csv.reader(open(args.corpus, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE) if r and not r[0].startswith("#")][: args.limit]
    eng = Engine(os.path.abspath(args.engine))
    sc = Scorer(os.path.expanduser(personal.MODEL))
    bonuses = [float(x) for x in args.bonus.split(",")]
    right = {b: 0 for b in bonuses}
    plain = reachable = tried = asked = changed = 0
    double = "quanpin" not in os.path.basename(os.path.abspath(args.engine))
    for i, r in enumerate(rows):
        ctx = "" if r[1] == "-" else r[1].replace("⏎", "\n")[-120:]
        keys, gold = r[2], r[3]
        own = eng.top(keys)
        plain += own == gold
        tops = {}
        lo, hi = 0, None
        if args.only_unreadable:
            bad = first_bad(keys, pairs)
            if bad is None:
                right = {b: right[b] + (own == gold) for b in bonuses}
                reachable += own == gold
                continue
            tried += 1
            if args.window is not None:
                lo, hi = max(0, bad - args.window), bad + 2
        else:
            tried += 1
        ks = edits(keys, double, lo, hi)
        asked += len(ks)
        for k in ks:
            t = eng.top(k)
            if t and t != own:
                tops.setdefault(t, k)
        cands = ([own] if own else []) + list(tops)
        reachable += gold in cands
        if cands:
            lps = sc.score(ctx, cands)
            for b in bonuses:
                best = max(range(len(cands)), key=lambda j: lps[j] + (b if own and j == 0 else 0))
                right[b] += cands[best] == gold
                if b == bonuses[0]:
                    changed += cands[best] != own
                    if args.show:
                        print(f"  {keys} → {cands[best]}（{tops.get(cands[best], keys)}）  应为 {gold}")
        if (i + 1) % 50 == 0:
            print(f"进度 {i + 1}/{len(rows)}", file=sys.stderr, flush=True)
    sc.close()
    n = len(rows)
    print(f"n={n}  原样的首选 {100 * plain / n:.1f}%  改一处能改出正确结果的 {100 * reachable / n:.1f}%  "
          f"试着纠的 {tried} 条、平均每条问 {asked / max(tried, 1):.0f} 种改法、改了首选的 {changed} 条")
    for b in bonuses:
        print(f"  原样加 {b:g}：挑完的首选 {100 * right[b] / n:.1f}%")


if __name__ == "__main__":
    main()
