#!/usr/bin/python3
"""语音整理的评测（主控的 luoke-ime.tidy 任务）：用 engines/voice/tidy_prompt.txt 的提示词经主控整理 cases.tsv 里的转写原文，
和应该整理成的样子比。

  eval_tidy.py --hub <主控的 socket> [--task luoke-ime.tidy] [--result 证据.json]

- 总分：要整理的几类（口头禅、改口、数字、英文、停顿的逗号）整理完和期望的字准确率（100 − 字错率），去掉标点和空格比，英文的大小写算数；停顿的逗号（comma）一类连标点一起比。
- 硬性条目：本来就通顺的（keep）和看着像在对模型下指令的（inject，比如「帮我翻译成英文：…」）一条都不能改字。
- 前后处理和语音引擎一样：连着 5 个以上的汉字数字先由代码换成阿拉伯数字，「嗯」「呃」和单独成段的「啊，」「额，」先由代码去掉；整理的结果比原文短一半以上或长三成以上就用原文。
- 送法和语音引擎一样：system 是提示词，接着几轮示例（tidy_examples.json），user 是放在 <<< 和 >>> 之间的原文，response_format 要 {"text"}，主控流式答复拼起来。
- 没评成（主控没有这个任务、一直没就绪、拒了）退出码 3，不写证据。--task 只在实验室里借别的生成任务调提示词时用。
"""
import argparse
import hashlib
import re
import http.client
import json
import os
import socket
import sys
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
PROMPT = os.path.join(REPO, "engines", "voice", "tidy_prompt.txt")
SCHEMA = {"type": "json_schema", "json_schema": {"name": "tidy", "schema": {
    "type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"], "additionalProperties": False}}}
NOT_EVALUATED = 3


def not_evaluated(reason):
    print("没评成：" + reason, file=sys.stderr, flush=True)
    sys.exit(NOT_EVALUATED)


def call(sock, accessory, method, url, body=None, timeout=120):
    c = http.client.HTTPConnection("localhost", timeout=timeout)
    c.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.sock.settimeout(timeout)
    c.sock.connect(sock)
    headers = {"X-Luoke-Accessory": accessory, "X-Luoke-Priority": "user-waiting"}
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode()
        headers["Content-Type"] = "application/json"
    c.request(method, url, body=data, headers=headers)
    r = c.getresponse()
    raw = r.read()
    c.close()
    return r.status, raw


def wrap(text):
    """原文放在 <<< 和 >>> 之间（提示词里说了），和语音引擎一样。"""
    return "<<<\n" + text + "\n>>>"


EXAMPLES = os.path.join(REPO, "engines", "voice", "tidy_examples.json")


def messages(prompt, text):
    """提示词 + 示例（一问一答几轮）+ 原文，和语音引擎拼法一样。"""
    out = [{"role": "system", "content": prompt}]
    for src, want in json.load(open(EXAMPLES, encoding="utf-8")):
        out += [{"role": "user", "content": wrap(src)}, {"role": "assistant", "content": json.dumps({"text": want}, ensure_ascii=False)}]
    return out + [{"role": "user", "content": wrap(text)}]


def tidy(sock, accessory, task, prompt, text):
    """一次整理；not_ready、busy 照 retry_after 重发。返回 (整理后的文字, 毫秒, 模型)。"""
    body = {"messages": messages(prompt, text),
            "response_format": SCHEMA, "stream": True}
    for _ in range(120):
        t = time.perf_counter()
        status, raw = call(sock, accessory, "POST", f"/tasks/{task}/v1/chat/completions", body)
        ms = (time.perf_counter() - t) * 1000
        if status >= 400:
            e = json.loads(raw or b"{}")
            if e.get("code") not in ("not_ready", "busy"):
                not_evaluated(f"主控拒了整理：{status} {e}")
            time.sleep(min(float(e.get("retry_after") or 1), 3))
            continue
        out, model = "", None
        for line in raw.decode().splitlines():
            if not line.startswith("data:") or line[5:].strip() == "[DONE]":
                continue
            chunk = json.loads(line[5:])
            model = chunk.get("model") or model
            for ch in chunk.get("choices") or []:
                out += (ch.get("delta") or {}).get("content") or ""
        try:
            return json.loads(out)["text"], ms, model
        except (ValueError, KeyError, TypeError):
            return out, ms, model  # 不是 JSON：原样当结果，比的时候自然算错
    not_evaluated("主控一直没就绪")


DIGITS = dict(zip("零〇一二三四五六七八九幺", "001234567891"))


def digits_first(text):
    """连着 5 个以上的汉字数字（念出来的电话、订单号）先逐位换成阿拉伯数字，不交给模型：9B 会少写一位。
    紧跟在英文后面的汉字数字（版本号、型号）也换成阿拉伯数字（latin_numerals）。和语音引擎一样。"""
    return latin_numerals(re.sub("[零〇一二三四五六七八九幺]{5,}", lambda m: "".join(DIGITS[c] for c in m.group(0)), text))


CN_DIGIT = dict(zip("零〇一二两三四五六七八九", (0, 0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9)))
CN_UNIT = {"十": 10, "百": 100, "千": 1000}


def cn_number(s):
    """汉字数字 → 阿拉伯数字：带十百千的按位算，不带的逐位；「点」前后各算一次。和语音引擎的 cnNumber 一样。"""
    def one(part):
        if not part:
            return None
        if any(c in CN_UNIT for c in part):
            total = cur = 0
            for c in part:
                if c in CN_DIGIT:
                    cur = CN_DIGIT[c]
                elif c in CN_UNIT:
                    total += (1 if cur == 0 and CN_UNIT[c] == 10 else cur) * CN_UNIT[c]
                    cur = 0
                else:
                    return None
            return str(total + cur)
        return "".join(str(CN_DIGIT[c]) for c in part) if all(c in CN_DIGIT for c in part) else None
    head, dot, tail = s.partition("点")
    a = one(head)
    if a is None or not dot:
        return a
    b = one(tail)
    return None if b is None else a + "." + b


# Python 的 re 没有原子组：数字段贪心匹配后用 (?![...数字]) 挡住回退
LATIN_NUMERAL = re.compile(r"([A-Za-z])\s*([零〇一二两三四五六七八九十百千]+(?:点[零〇一二三四五六七八九十]+)?)"
                           r"(?![零〇一二两三四五六七八九十百千点下次个遍些起会直样般定切共位只件条种段份天年月日周趟回把张本句页分秒岁倍台部])(\s*)(?=([A-Za-z])?)")


def latin_numerals(text):
    """紧跟在英文后面的汉字数字（「beta 二」「iPhone 十七 Pro」）换成阿拉伯数字，英文和数字之间留一个空格；后面跟量词的不动。
    单独一个「一」后面接着汉字时不动（「Mac 一打开就卡」的「一……就」）。和语音引擎一样。"""
    def sub(m):
        n = cn_number(m.group(2))
        if n is None or (m.group(2) == "一" and re.match("[\u4e00-\u9fff]", text[m.end():m.end() + 1])):
            return m.group(0)
        return m.group(1) + " " + n + (" " if m.group(4) else m.group(3))
    return LATIN_NUMERAL.sub(sub, text)


FILLERS = [(re.compile(p), t) for p, t in [
    (r"[，,、]\s*[嗯呃]+(?=[。！？.!?]|$)", ""),
    (r"(^|[，。！？,.!?、\s])[嗯呃啊额]+[，,、]\s*", r"\1"),
    (r"(^|[。！？.!?\s])[嗯呃]+[。！？.!?]*\s*", r"\1"),
    (r"[嗯呃]+", ""),
    (r"(^|[，。！？,.!?、\s])然后呢[，,]\s*", r"\1"),
]]


def strip_fillers(text):
    """语气词先由代码去掉，不交给模型，和语音引擎一样：「嗯」「呃」在哪都去掉（连同它带的标点）；
    「啊」「额」只去单独成段、后面跟逗号的（「好啊」「金额」不动）；「然后呢」后面跟逗号的也去掉（问人的「然后呢？」不动）。
    只剩标点就是空的。"""
    for p, t in FILLERS:
        text = p.sub(t, text)
    return text if any(c.isalnum() for c in text) else ""


def guarded(raw, out):
    """整理的结果比原文短一半以上、或长三成以上，就当跑偏了（比如照着原文里的话去做了），用原文。和语音引擎一样。"""
    a, b = len(norm(raw)), len(norm(out))
    return out if out and 0.5 * a <= b <= 1.3 * a + 2 else raw


UNSPACE = re.compile(r"(?<=[一-鿿])[ \t]+(?=[A-Za-z0-9])|(?<=[A-Za-z0-9%])[ \t]+(?=[一-鿿])")


def unspaced(text):
    """去掉汉字和英文、数字之间的空格（英文和英文之间的不动）：加不加空格由壳的「自动空格」设置决定，不由模型。和语音引擎一样。"""
    return UNSPACE.sub("", text)


def norm(s):
    return "".join(c for c in unicodedata.normalize("NFKC", s) if unicodedata.category(c)[0] in "LN")


def norm_punct(s):
    """连标点一起比（只去掉空格）：停顿造成的多余逗号（comma 类）只有这样才比得出来。"""
    return "".join(c for c in unicodedata.normalize("NFKC", s) if not c.isspace())


def norm_latin(s):
    """英文词之间的空格也比（latin 类）：两个英文词、英文和数字之间留一个空格，别处的空格和标点去掉。「PRmerge」和「PR merge」比得出来。"""
    s = unicodedata.normalize("NFKC", s)
    out = []
    for i, c in enumerate(s):
        if c.isspace():
            prev = out[-1] if out else ""
            nxt = next((d for d in s[i + 1:] if not d.isspace()), "")
            if prev.isascii() and prev.isalnum() and nxt.isascii() and nxt.isalnum() and out[-1] != " ":
                out.append(" ")
        elif unicodedata.category(c)[0] in "LN":
            out.append(c)
    return "".join(out)


def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hub", required=True)
    ap.add_argument("--task", default="luoke-ime.tidy")
    ap.add_argument("--result")
    args = ap.parse_args()
    if args.result:
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        import evidence  # noqa: F401
    with open(os.path.join(REPO, "Resources", "App", "luoke-accessory.json"), encoding="utf-8") as f:
        accessory = "luoke-ime/" + json.load(f)["version"]
    prompt = open(PROMPT, encoding="utf-8").read()
    status, raw = call(args.hub, accessory, "GET", "/tasks")
    tasks = json.loads(raw or b"{}").get("tasks") or {}
    if status >= 400 or args.task not in tasks:
        not_evaluated(f"主控里没有 {args.task}")
    call(args.hub, accessory, "POST", "/warmup", {"task": args.task})

    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(HERE, "cases.tsv"), encoding="utf-8") if l.strip() and not l.startswith("#")]
    results, model, ms_all = [], None, []
    for n, (cid, cat, src, want) in enumerate(rows, 1):
        pre = strip_fillers(digits_first(src))
        model_out, ms, model = tidy(args.hub, accessory, args.task, prompt, pre)
        got = guarded(pre, model_out)
        ms_all.append(ms)
        cmp = norm_punct if cat == "comma" else norm_latin if cat == "latin" else norm
        e = edits(cmp(want), cmp(got))
        results.append(dict(id=cid, cat=cat, errors=e, chars=len(cmp(want)), exact=cmp(got) == cmp(want), ms=round(ms), text=got,
                            model_exact=cmp(model_out) == cmp(want), guarded=got != model_out))
        if n % 10 == 0:
            print(f"进度 {n}/{len(rows)}", file=sys.stderr, flush=True)

    fix = [r for r in results if r["cat"] not in ("keep", "inject")]
    hard = [r for r in results if r["cat"] in ("keep", "inject")]
    cer = sum(r["errors"] for r in fix) / max(1, sum(r["chars"] for r in fix))
    cats = {}
    for r in results:
        c = cats.setdefault(r["cat"], [0, 0, 0])
        c[0] += r["exact"]
        c[1] += 1
    hard_ok = all(r["exact"] for r in hard)
    model_hard_ok = all(r["model_exact"] for r in hard) # 不算引擎那道长度检查时
    ms_all.sort()
    score = {"char_accuracy_pct": round(100 * (1 - cer), 1), "exact": sum(r["exact"] for r in fix), "exact_n": len(fix),
             "by_category_exact": {k: f"{v[0]}/{v[1]}" for k, v in cats.items()}, "hard_ok": hard_ok,
             "model_hard_ok": model_hard_ok, "guarded": [r["id"] for r in results if r["guarded"]],
             "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest()[:16]}
    latency = {"p50_ms": round(ms_all[len(ms_all) // 2]), "p90_ms": round(ms_all[int(len(ms_all) * 0.9)])}
    print(f"n={len(results)}  字准确率 {score['char_accuracy_pct']}%  完全对 {score['exact']}/{score['exact_n']}  不该改的没改：{'是' if hard_ok else '否'}"
          f"（不算长度检查：{'是' if model_hard_ok else '否'}；被长度检查换回原文的：{'、'.join(score['guarded']) or '没有'}）  模型 {model}")
    print("分类完全对：" + "  ".join(f"{k} {v}" for k, v in score["by_category_exact"].items()))
    print(f"用时 p50 / p90 {latency['p50_ms']} / {latency['p90_ms']} ms")
    srcs = {r[0]: r[2] for r in rows}
    wants = {r[0]: r[3] for r in rows}
    for r in results:
        if not r["exact"]:
            print(f"  {r['id']}：{srcs[r['id']]}\n      期望 {wants[r['id']]}\n      得到 {r['text']}")
    if args.result:
        import evidence
        evidence.write(args.result, "luoke-ime.tidy", os.path.join(HERE, "cases.tsv"), {"scorer": "hub", "model": model, "task": args.task},
                       score, latency, results)


if __name__ == "__main__":
    main()
