#!/usr/bin/python3
"""语音整理「编辑」定位的评测：整理不再只是去口头禅，而是把说的话写成像样的文字（排列表、分段、修不通的说法），
所以没法和一个标准答案逐字比。每条按要点查：

- 规则检查（代码查，稳定）：
  - must：要点都在（数字、名字、事实）；「a|b」任一个在就行。比的时候去掉空格。
  - must_not：不该留的不在（口头禅、改口前的说法）。
  - list：true 要排成编号列表，false 不能排，null 都行。
  - 格式：不嵌套列表、不用「-」「•」列表；中文和英文、数字之间不加空格。
  - keep（本来通顺）、inject（像在给模型下指令）：去掉标点和空格后一个字不改（算上引擎的长度检查）。
- 裁判（可选）：照 JUDGE_PROMPT 判意思有没有丢、加、变（faithful），口吻和句式有没有变（tone），读起来是不是认真写下的文字
  （written），列表和分段用得对不对（structure）。本机的模型当裁判判不准（长段两次结论不一样、把指代的「那个」当口头禅），
  所以裁判由 Claude 做：--sheet 写一份评分单（标准 + 每条的原文和结果），Claude 照它写评分（{id: {faithful, tone, written,
  structure, reason}}），再用 --rejudge 结果 --grades 评分 合进来。裁判只在实验室里用，出版评测不靠它。

被评的模型两种跑法：
  eval_edit.py --hub <主控的 socket> [--accessory luoke-ime/<版本>]      经主控的 luoke-ime.tidy（用这一档的底座）
  <装了 mlx-lm 的 python> eval_edit.py --mlx <模型目录>                    本机直接跑一个模型（调提示词用，比如 9B）
其他：--prompt / --examples 换提示词和示例（默认引擎的）；--only id,id 只跑几条；--result 写证据；
--sheet 评分单 写评分单；--grades 评分 合进裁判的评分（和 --rejudge 一起用）。
前后处理和语音引擎一样（汉字数字、语气词先由代码处理；结果比原文短一半以上或长三成以上就用原文；汉字和英文、数字之间的空格去掉，由壳按「自动空格」设置加）。
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(HERE, "..", "tidy"))
import eval_tidy as T  # noqa: E402  前后处理、主控调用、长度检查和整理的评测共用

CJK = "一-鿿"
SPACED = re.compile(f"[{CJK}] +[A-Za-z0-9]|[A-Za-z0-9] +[{CJK}]")
LIST_LINE = re.compile(r"^\s*\d+[.、．]\s*\S", re.M)
BULLET_LINE = re.compile(r"^[ \t]*[-*•·][ \t]|^[ \t]+\d+[.、．]", re.M)

JUDGE_PROMPT = """你在检查一段语音输入的整理结果。用户口述了「原文」，整理把它编辑成「结果」，要直接替用户写下来。
整理可以去掉口头禅（嗯、那个、然后呢……）、卡住的重复、改口前的说法，可以改成书面的句子、排列表、分段。
请逐句对照原文，判断四件事，各给 true 或 false。拿不准时判 false：
- faithful：原文里每一句有内容的话都还在（开场、收尾、客套的话也算，比如「好的，那就先这样」「大家辛苦一下」「哈哈」）；
  没有加原文没有的事实、观点、细节、单位；意思没有变。只有口头禅、改口前的说法和犹豫的过程（「两点，呃，两点半吧」只留「两点半」）、
  卡住的重复、重复的确认可以去掉，去掉它们不算丢。
- tone：口吻和句式没变：问句还是问句，请求还是请求；对熟人随意的说法没有改成公文腔（「挺好的」不能变成「良好」，「是可以的」不能变成「可行」）。
- written：读起来像用户认真写下的文字：没有残留的口头禅、卡顿和明显不通顺的地方。指代用的「那个」「这个」（「那个文件」「这个方案」）不是口头禅。
- structure：列表只用来列原文里并列的几项（几件事、几个原因、几样东西、几天的安排），不把开场白、不并列的话编进列表，不嵌套；
  没有列举的地方没排列表；分段和原文换话题的地方一致。
每条给 {"faithful": …, "tone": …, "written": …, "structure": …, "reason": "有 false 时一句话说哪里不对"}。"""
JUDGED = ("faithful", "tone", "written", "structure")


def squash(s):
    return re.sub(r"\s+", "", s)


def bare(s):
    """只留字母、数字、汉字：keep、inject 比这个。"""
    return "".join(c for c in s if c.isalnum())


def checks(case, got):
    """规则检查：返回 {检查名: 通过没有}。"""
    out, g = {}, squash(got)
    if case["cat"] in ("keep", "inject"):
        out["unchanged"] = bare(got) == bare(case["src"])
        return out
    out["must"] = all(any(squash(a) in g for a in m.split("|")) for m in case.get("must", []))
    out["must_not"] = not any(squash(m) in g for m in case.get("must_not", []))
    if case.get("list") is not None:
        out["list"] = bool(LIST_LINE.search(got)) == case["list"]
    out["nesting"] = not BULLET_LINE.search(got)
    out["spacing"] = not SPACED.search(got)
    return out


def missing(case, got):
    g = squash(got)
    miss = [m for m in case.get("must", []) if not any(squash(a) in g for a in m.split("|"))]
    left = [m for m in case.get("must_not", []) if squash(m) in g]
    return miss, left


class HubModel:
    def __init__(self, sock, accessory, task):
        self.sock, self.accessory, self.task = sock, accessory, task
        T.call(sock, accessory, "POST", "/warmup", {"task": task})

    def tidy(self, prompt, text):
        got, ms, model = T.tidy(self.sock, self.accessory, self.task, prompt, text)
        return got, ms, model


class MlxModel:
    def __init__(self, path):
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler
        self.model, self.tok = load(path)
        self.sampler = make_sampler(temp=0.0)
        self.name = os.path.basename(os.path.normpath(path))

    def tidy(self, prompt, text):
        from mlx_lm import generate
        p = self.tok.apply_chat_template(T.messages(prompt, text), add_generation_prompt=True, tokenize=False, enable_thinking=False)
        t = time.perf_counter()
        out = generate(self.model, self.tok, prompt=p, max_tokens=1500, sampler=self.sampler)
        ms = (time.perf_counter() - t) * 1000
        m = re.search(r"\{.*\}", out, re.S)
        try:
            return json.loads(m.group(0))["text"], ms, self.name
        except (AttributeError, ValueError, KeyError, TypeError):
            return out, ms, self.name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hub")
    ap.add_argument("--mlx")
    ap.add_argument("--task", default="luoke-ime.tidy")
    ap.add_argument("--accessory")
    ap.add_argument("--prompt", default=T.PROMPT)
    ap.add_argument("--examples", default=T.EXAMPLES)
    ap.add_argument("--sheet", help="写评分单（裁判的标准和每条的原文、结果）给 Claude 评")
    ap.add_argument("--grades", help="Claude 照评分单写的评分（JSON：{id: {faithful, tone, written, structure, reason}}）")
    ap.add_argument("--only")
    ap.add_argument("--result")
    ap.add_argument("--rejudge", help="不再跑模型：拿以前 --result 写下的结果重新检查、重新请裁判（改了检查或裁判时用）")
    args = ap.parse_args()
    if bool(args.hub) + bool(args.mlx) + bool(args.rejudge) != 1:
        sys.exit("--hub、--mlx、--rejudge 选一个")
    with open(os.path.join(REPO, "Resources", "App", "luoke-accessory.json"), encoding="utf-8") as f:
        accessory = args.accessory or "luoke-ime/" + json.load(f)["version"]
    T.EXAMPLES = args.examples
    prompt = open(args.prompt, encoding="utf-8").read()
    old = {}
    if args.rejudge:
        prev = json.load(open(args.rejudge, encoding="utf-8"))
        old = {r["id"]: r for r in prev["results"]}
        runner = None
    else:
        runner = HubModel(args.hub, accessory, args.task) if args.hub else MlxModel(args.mlx)
    cases = [json.loads(l) for l in open(os.path.join(HERE, "cases.jsonl"), encoding="utf-8") if l.strip()]
    if args.only or old:
        keep = set(args.only.split(",")) if args.only else set(old)
        cases = [c for c in cases if c["id"] in keep]

    grades = json.load(open(args.grades, encoding="utf-8")) if args.grades else None
    results, model, ms_all = [], None, []
    for n, case in enumerate(cases, 1):
        if old:
            o = old[case["id"]]
            got, ms, guarded, model = o["text"], o["ms"], o["guarded"], prev.get("model")
        else:
            pre = T.strip_fillers(T.digits_first(case["src"]))
            model_out, ms, model = runner.tidy(prompt, pre)
            got = T.guarded(pre, model_out)
            guarded = got != model_out
            got = T.unspaced(got)
        ms_all.append(ms)
        r = dict(id=case["id"], cat=case["cat"], text=got, guarded=guarded, ms=round(ms), checks=checks(case, got))
        if grades is not None and case["cat"] not in ("keep", "inject"):
            r["judge"] = grades.get(case["id"])
        r["ok"] = all(r["checks"].values()) and all((r.get("judge") or {}).get(k, True) for k in JUDGED)
        results.append(r)
        print(f"{n}/{len(cases)} {case['id']} {'✓' if r['ok'] else '✗'} {round(ms)} ms", file=sys.stderr, flush=True)

    def rate(key, src):
        vals = [x for x in src if x is not None]
        return f"{sum(vals)}/{len(vals)}" if vals else "-"

    score = {"ok": sum(r["ok"] for r in results), "n": len(results),
             "checks": {k: rate(k, [r["checks"].get(k) for r in results]) for k in ("must", "must_not", "list", "nesting", "spacing", "unchanged")},
             "by_category": {}, "guarded": [r["id"] for r in results if r["guarded"]],
             "prompt_sha256": hashlib.sha256((prompt + open(args.examples, encoding="utf-8").read()).encode()).hexdigest()[:16]}
    if grades is not None:
        score["judge"] = {k: rate(k, [(r.get("judge") or {}).get(k) for r in results if "judge" in r]) for k in JUDGED}
    for r in results:
        c = score["by_category"].setdefault(r["cat"], [0, 0])
        c[0] += r["ok"]
        c[1] += 1
    score["by_category"] = {k: f"{a}/{b}" for k, (a, b) in score["by_category"].items()}
    ms_all.sort()
    latency = {"p50_ms": round(ms_all[len(ms_all) // 2]), "p90_ms": round(ms_all[int(len(ms_all) * 0.9)])}

    print(f"n={score['n']}  全过 {score['ok']}/{score['n']}  模型 {model}  用时 p50 / p90 {latency['p50_ms']} / {latency['p90_ms']} ms")
    print("规则：" + "  ".join(f"{k} {v}" for k, v in score["checks"].items()))
    if "judge" in score:
        print("裁判：" + "  ".join(f"{k} {v}" for k, v in score["judge"].items()))
    print("分类：" + "  ".join(f"{k} {v}" for k, v in score["by_category"].items()))
    print("被长度检查换回原文的：" + ("、".join(score["guarded"]) or "没有"))
    by_id = {c["id"]: c for c in cases}
    for r in results:
        if r["ok"]:
            continue
        c = by_id[r["id"]]
        why = [k for k, v in r["checks"].items() if not v]
        miss, left = missing(c, r["text"])
        if miss:
            why.append("缺 " + "、".join(miss))
        if left:
            why.append("留着 " + "、".join(left))
        j = r.get("judge") or {}
        why += [k for k in JUDGED if j.get(k) is False]
        if j.get("reason") and any(j.get(k) is False for k in JUDGED):
            why.append("裁判：" + j["reason"])
        print(f"\n✗ {r['id']}（{'；'.join(why)}）\n  原文 {c['src']}\n  结果 " + r["text"].replace("\n", "\n       "))
    if args.sheet:
        with open(args.sheet, "w", encoding="utf-8") as f:
            f.write(JUDGE_PROMPT + "\n\n评分写成一个 JSON 对象，键是每条的 id。keep、inject 两类不评。\n")
            for r in results:
                if r["cat"] not in ("keep", "inject"):
                    f.write(f"\n## {r['id']}\n原文：\n{by_id[r['id']]['src']}\n\n结果：\n{r['text']}\n")
    if args.result:
        json.dump({"score": score, "latency": latency, "model": model, "results": results}, open(args.result, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
