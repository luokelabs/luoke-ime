#!/usr/bin/python3
"""从评测语料生成简拼、半简拼、打错的版本，给 bench.py 测（语料格式见 bench.py；要有拼音那一列）。

  ./variants.py 语料.tsv 输出目录 [--seed 1]

写出七份，按键一列换掉、别的列不变：
  quanpin.tsv          全拼：原样打对（拼音去掉空格），给全拼的几份对照
  jianpin-quanpin.tsv  全拼：每个音节只打第一个字母（zh、ch、sh 也只打 z、c、s）。双拼一般不用全简拼，不生成
  banjian-quanpin.tsv  全拼的半简拼：随机一部分音节只打第一个字母，其余打全（zhongg 这种；至少一个简、一个全，
                       只有一个音节的跳过）
  banjian-xiaohe.tsv   小鹤的半简拼：随机一部分音节只打第一个键
  jianpin-xiaohe.tsv   小鹤：每个音节只打第一个键（只为和老结果对照）
  typo-xiaohe.tsv      小鹤的按键里随机打错一处
  typo-quanpin.tsv     全拼的按键里随机打错一处（全拼的原始按键是拼音去掉空格）

打错照真人的比例（搜狗输入日志里退格改掉的错，Zheng 等 2011）：漏打 47%、多打 28%、按错 19%、相邻两键打反 7.5%。
按错一半是读音相近的（z/c/s、j/q/x、a/e、n/l 这类），一半是键盘上相邻的；多打一半是把这个键多按一次，一半是
按到旁边的键；全拼漏打多在韵母、ng 的 g、zh/ch/sh 的 h 上。每句都改一处（救回多少按打错的句子算；真人大约三分之一
的句子有错，合起来时自己按比例算）。多出来两列：typo 写着改了哪里（比如 sub 3 g→h），valid 是打错以后整串还是
不是合法的拼音（1 是：这种最难发现）。
"""
import argparse
import csv
import os
import random

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
POS = {ch: (r, c) for r, row in enumerate(ROWS) for c, ch in enumerate(row)}
SOUND = {"z": "cs", "c": "zs", "s": "zc", "j": "qx", "q": "jx", "x": "jq", "a": "e", "e": "a", "n": "lm", "l": "n",
         "m": "n", "g": "kh", "k": "gh", "h": "gk", "b": "p", "p": "b", "d": "t", "t": "d", "u": "v", "v": "u"}
OPS = (("del", 47), ("ins", 28), ("sub", 19), ("swap", 7.5))

# 小鹤双拼（和 on-device-llm 生成博客语料时一样）
FIN = {"a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v", "ai": "d", "ei": "w", "ui": "v",
       "ao": "c", "ou": "z", "iu": "q", "ie": "p", "ue": "t", "ve": "t", "an": "j", "en": "f",
       "in": "b", "un": "y", "ang": "h", "eng": "g", "ing": "k", "ong": "s", "ia": "x", "ua": "x",
       "uo": "o", "iao": "n", "ian": "m", "uai": "k", "uan": "r", "iang": "l", "uang": "l", "iong": "s"}
ZERO = {"a": "aa", "ai": "ai", "an": "an", "ang": "ah", "ao": "ao", "e": "ee", "ei": "ei", "en": "en",
        "eng": "eg", "er": "er", "o": "oo", "ou": "ou"}
DICT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "quanpin", "vendor", "rime-ice", "cn_dicts", "8105.dict.yaml")


def neighbors(ch):
    """键盘上挨着的字母（同一排左右、上下两排斜着挨着的）。"""
    r, c = POS[ch]
    out = []
    for dr, dcs in ((0, (-1, 1)), (-1, (0, 1)), (1, (-1, 0))):
        for dc in dcs:
            rr, cc = r + dr, c + dc
            if 0 <= rr < 3 and 0 <= cc < len(ROWS[rr]):
                out.append(ROWS[rr][cc])
    return out


def xiaohe(syl):
    for ini, key in (("zh", "v"), ("ch", "i"), ("sh", "u")):
        if syl.startswith(ini):
            return key + FIN[syl[2:]] if syl[2:] in FIN else None
    if syl[0] in "bpmfdtnlgkhjqxrzcsyw" and syl[1:] in FIN:
        return syl[0] + FIN[syl[1:]]
    return ZERO.get(syl)


def syllables():
    """合法的全拼音节（雾凇的 8105 字表里出现过的读音）；没有词库时为空集，valid 一列就都写 -。"""
    out = set()
    if not os.path.exists(DICT):
        return out
    body = False
    for line in open(DICT, encoding="utf-8"):
        if not body:
            body = line.startswith("...")
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and not line.startswith("#"):
            out.update(parts[1].replace("ü", "v").split())
    return out


def valid(keys, double, syl, pairs):
    """整串能不能切成合法的音节（双拼：每两个键一个音节）。"""
    if double:
        return len(keys) % 2 == 0 and all(keys[i:i + 2] in pairs for i in range(0, len(keys), 2))
    ok = [True] + [False] * len(keys)
    for i in range(1, len(keys) + 1):
        ok[i] = any(ok[j] and keys[j:i] in syl for j in range(max(0, i - 6), i))
    return ok[-1]


def typo(keys, rng, double):
    """随机打错一处 → (打错的按键, 说明)。太短的（不到 2 个键）不改。"""
    if len(keys) < 2:
        return keys, "-"
    op = rng.choices([o for o, _ in OPS], [w for _, w in OPS])[0]
    if op == "swap":
        spots = [i for i in range(len(keys) - 1) if keys[i] != keys[i + 1]]
        if spots:
            i = rng.choice(spots)
            return keys[:i] + keys[i + 1] + keys[i] + keys[i + 2:], f"swap {i}"
        op = "sub"
    if op == "del":
        # 全拼：韵母、ng 的 g、zh/ch/sh 的 h、连着两个一样的，漏得多（各算三倍）
        w = [1] * len(keys)
        if not double:
            for i, ch in enumerate(keys):
                if ch in "aeiouv" or (ch == "g" and keys[i - 1:i] == "n") or (ch == "h" and keys[i - 1:i] in ("z", "c", "s")) \
                        or keys[i - 1:i] == ch:
                    w[i] = 3
        i = rng.choices(range(len(keys)), w)[0]
        return keys[:i] + keys[i + 1:], f"del {i} {keys[i]}"
    i = rng.randrange(len(keys))
    if op == "sub":
        sound = SOUND.get(keys[i], "")
        to = rng.choice(sound) if sound and rng.random() < 0.5 else rng.choice(neighbors(keys[i]))
        return keys[:i] + to + keys[i + 1:], f"sub {i} {keys[i]}→{to}"
    to = keys[i] if rng.random() < 0.5 else rng.choice(neighbors(keys[i]))
    return keys[:i + 1] + to + keys[i + 1:], f"ins {i + 1} {to}"


def half(units, rng):
    """随机一部分音节只留第一个键：至少一个简、一个全。"""
    n = len(units)
    short = set(rng.sample(range(n), rng.randint(1, n - 1)))
    return "".join(u[0] if i in short else u for i, u in enumerate(units))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    # 不认引号：前文里的 " 是正文
    lines = list(csv.reader(open(args.corpus, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE))
    header = next((r for r in lines if r and r[0].startswith("#")), None)
    rows = [r for r in lines if r and not r[0].startswith("#")]
    col = header.index("pinyin") if header and "pinyin" in header else 4
    rng = random.Random(args.seed)
    syl = syllables()
    pairs = {p for p in map(xiaohe, syl) if p}
    names = ("quanpin", "jianpin-quanpin", "banjian-quanpin", "banjian-xiaohe", "jianpin-xiaohe", "typo-xiaohe", "typo-quanpin")
    out = {k: [] for k in names}
    for r in rows:
        sy = r[col].split()
        xh, qp = r[2], "".join(sy)
        if len(xh) != 2 * len(sy):
            continue  # 按键和音节对不上的（不是小鹤的两键一音节）跳过
        out["quanpin"].append(r[:2] + [qp] + r[3:])
        out["jianpin-quanpin"].append(r[:2] + ["".join(s[0] for s in sy)] + r[3:])
        out["jianpin-xiaohe"].append(r[:2] + [xh[0::2]] + r[3:])
        if len(sy) >= 2:
            out["banjian-quanpin"].append(r[:2] + [half(sy, rng)] + r[3:])
            out["banjian-xiaohe"].append(r[:2] + [half([xh[i:i + 2] for i in range(0, len(xh), 2)], rng)] + r[3:])
        for name, keys, double in (("typo-xiaohe", xh, True), ("typo-quanpin", qp, False)):
            k, why = typo(keys, rng, double)
            ok = ("1" if valid(k, double, syl, pairs) else "0") if syl else "-"
            out[name].append(r[:2] + [k] + r[3:] + [why, ok])
    os.makedirs(args.out, exist_ok=True)
    for name, rs in out.items():
        with open(os.path.join(args.out, name + ".tsv"), "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_NONE, escapechar="\\")
            if header:
                w.writerow(header + (["typo", "valid"] if name.startswith("typo") else []))
            w.writerows(rs)
        extra = ""
        if name.startswith("typo") and syl:
            extra = f"，打错后仍是合法拼音的 {100 * sum(r[-1] == '1' for r in rs) / max(len(rs), 1):.0f}%"
        print(f"{name}.tsv  {len(rs)} 条{extra}")


if __name__ == "__main__":
    main()
