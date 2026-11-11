#!/usr/bin/python3
"""联想在用户自己的上屏上的效果：按时间切开，早的当作已经写过的（History），最近的一段留作测试，测试段在
History 里只有它之前的内容（和真用时一样，边打边攒）。

  ./eval_personal.py <记忆文件的副本> [--test-days 7] [--limit N] [--dump FILE]

只读，不写记忆；最好先把记忆文件复制一份（sqlite3 的 backup）再评。报告只有比例，不带原文；--dump 写逐条的前文、
正确结果和各办法给的联想，只给自己看，别提交。

联想的时机：壳在上屏后问。一段里上屏的边界没记下来，这里取两种点：标点后面（一句的开头），和每一句中间随机一处
（打到一半上屏了一个词）。正确结果是这个点到下一个标点之间的字；联想是它的开头才算对（和 eval_predict.py 一样）。

比较的办法（都按壳的规矩只看前 3 个）：
  现在     改之前的办法：用户写过的（History.predict）原样放在前面，模型的接在后面
  只模型   personal.model_candidates
  只写过的 History.predict
  只模型   personal.picked 不给写过的（单字的不给）
  模型挑   个人化组件现在的办法（personal.picked）：写过的交模型打分，每个字平均的对数概率低于门槛的、单字的、
           不是汉字的不要，再和模型的一起排；--floors 换着门槛比（personal.MINE_FLOOR 是现在用的）
报：出联想的比例、出时第一个对、出时前三个有对、出了却一个都不对（打扰，占全部的点）、每百次上屏省几个键
（双拼一个字两个键，选联想要按 Tab 和一个选词键：前三个里对的最长那个 k 个字，省 2k − 2 个键）。
"""
import argparse
import json
import os
import random
import sqlite3
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import personal  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PUNCT = personal.PUNCT


def segments(db):
    """上屏记录（ime-commit，切走时自动上屏的不要），按时间先后：(时间, 应用, 前文, 文字)。"""
    c = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    out = []
    for at, text, data in c.execute("select happened_at, text, data_json from records where topic = ? order by happened_at, id",
                                    (personal.COMMIT,)):
        d = json.loads(data or "{}")
        if d.get("auto"):
            continue
        ctx = (d.get("context") or {}).get("text") or ""
        out.append((at, d.get("app") or "", ctx, text))
    c.close()
    return out


def points(text, rng):
    """一段里问联想的点：标点后面，和每一句中间随机一处。→ [(位置, 正确结果, 哪种点)]"""
    out = []
    i = 0
    while i < len(text):
        j = next((k for k in range(i, len(text)) if text[k] in PUNCT), len(text))
        clause = text[i:j]
        if i > 0 and clause:
            out.append((i, clause, "句首"))
        if len(clause) >= 4:
            p = rng.randint(2, len(clause) - 2)
            out.append((i + p, clause[p:], "句中"))
        i = j + 1
    return [(p, g, k) for p, g, k in out if "一" <= g[0] <= "鿿"]


class Scorer:
    def __init__(self, model):
        py = personal.find_python()
        if py is None:
            sys.exit("找不到能跑 MLX 的 Python（oMLX）")
        env = dict(os.environ)
        if py[1]:
            env["PYTHONPATH"] = py[1]
        self.p = subprocess.Popen([py[0], os.path.join(HERE, "scorer.py"), model], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, env=env)
        if '"ready"' not in self.p.stdout.readline():
            sys.exit("模型没能加载")

    def _ask(self, obj):
        self.p.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def cont(self, ctx):
        req = personal.continue_params(ctx)
        return personal.continuations_from_branches(self._ask({"branches": req.pop("context"), **req})["branches"])

    def score(self, ctx, cands):
        return self._ask({"ctx": ctx, "cands": cands})["lp"] if cands else []

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory", help="记忆文件（最好是副本）")
    ap.add_argument("--test-days", type=float, default=7, help="最近几天的上屏留作测试")
    ap.add_argument("--limit", type=int, help="最多评多少个点")
    ap.add_argument("--model", default=os.path.expanduser(personal.MODEL))
    ap.add_argument("--floors", default="-0.5,-1.0,-1.5", help="模型挑时每个字平均对数概率的下限，逗号分开")
    ap.add_argument("--dump", metavar="FILE")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    segs = segments(args.memory)
    if not segs:
        sys.exit("记忆里没有上屏记录")
    from datetime import datetime, timedelta
    last = max(datetime.fromisoformat(s[0].replace("T", " ")[:19]) for s in segs)
    cut = (last - timedelta(days=args.test_days)).strftime("%Y-%m-%d %H:%M:%S")
    train = [s for s in segs if s[0].replace("T", " ") < cut]
    test = [s for s in segs if s[0].replace("T", " ") >= cut]
    print(f"上屏 {len(segs)} 段：之前 {len(train)} 段当作写过的，最近 {args.test_days:g} 天 {len(test)} 段做测试", file=sys.stderr)

    history = personal.History()
    history.add_older([s[3] for s in train])
    rng = random.Random(args.seed)
    floors = [float(x) for x in args.floors.split(",")]
    scorer = Scorer(args.model)
    dump = open(args.dump, "w") if args.dump else None
    ways = ["现在", "只模型", "只写过的"] + ["模型挑 %g" % f for f in floors]
    keep = personal.MINE_FLOOR
    stats = {k: {w: Counter() for w in ways} for k in ("全部", "句首", "句中")}
    n = 0
    for at, app, ctx0, text in test:
        for p, gold, kind in points(text, rng):
            if args.limit and n >= args.limit:
                break
            ctx = (ctx0 + text[:p])[-120:]
            raw = history.predict(ctx)
            cont = scorer.cont(ctx)
            model = personal.model_candidates(cont)
            # 「现在」照改之前的办法：写过的原样放在前面，模型的接在后面
            got = {"现在": (raw + [c for c in model if c not in raw])[:5], "只模型": personal.picked(cont), "只写过的": raw}
            mine = personal.mine_to_judge(raw)
            judge = personal.judge_request(mine, cont)
            lps = scorer.score(ctx, judge) if judge else None
            for f in floors:
                personal.MINE_FLOOR = f
                got["模型挑 %g" % f] = personal.picked(cont, mine, lps)
            personal.MINE_FLOOR = keep
            for w, cands in got.items():
                top = cands[:3]
                for k in ("全部", kind):
                    s = stats[k][w]
                    s["n"] += 1
                    if top:
                        s["shown"] += 1
                        hit = [c for c in top if gold.startswith(c)]
                        s["top1"] += gold.startswith(top[0])
                        s["top3"] += bool(hit)
                        s["miss"] += not hit
                        if hit:
                            s["keys"] += 2 * len(max(hit, key=len)) - 2
            if dump:
                dump.write(json.dumps({"ctx": ctx[-30:], "gold": gold, "kind": kind, "app": app, **got}, ensure_ascii=False) + "\n")
            n += 1
            if n % 100 == 0:
                print(f"进度 {n}", file=sys.stderr, flush=True)
        history.add(text)
    scorer.close()

    for k, by in stats.items():
        total = by["现在"]["n"]
        print(f"\n【{k}】{total} 个点")
        print("办法                  出联想   出时第一个对   出时前三有对   出了全不对（占全部）   每百次省几个键")
        for w in ways:
            s = by[w]
            sh = max(s["shown"], 1)
            print(f"{w:<18} {100 * s['shown'] / max(s['n'], 1):7.1f}%   {100 * s['top1'] / sh:10.1f}%   {100 * s['top3'] / sh:10.1f}%   "
                  f"{100 * s['miss'] / max(s['n'], 1):14.1f}%   {100 * s['keys'] / max(s['n'], 1):10.1f}")


if __name__ == "__main__":
    main()
