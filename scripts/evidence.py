"""评测证据：照 luoke-core V1 §7 的证据记录格式（配件版本、任务、评测集哈希、组合、参数、机器与芯片、日期、逐条结果）
写一份 JSON，给主控的发布脚本（luoke-core tools/release.py）读。engines/xiaohe/bench.py（重排）和
engines/personal/eval_predict.py（联想）的 --result 用它。

逐条结果不带语料原文：语料是作者的博客，只在作者自己的机器上跑，配方里只记结论和哈希（和 luoke-core 商定）。
"""
import hashlib
import json
import os
import platform
import subprocess
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
MANIFEST = os.path.join(REPO, "Resources", "App", "luoke-accessory.json")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def machine():
    mem = _run("/usr/sbin/sysctl", "-n", "hw.memsize")
    return {"os": "macOS " + platform.mac_ver()[0], "model": _run("/usr/sbin/sysctl", "-n", "hw.model"),
            "chip": _run("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"),
            "memory_gb": round(int(mem) / 2 ** 30) if mem.isdigit() else None}


def accessory():
    """配件标识和版本（LuokeIME.app 里的配件清单），加上这份代码的提交号（有没提交的改动时标 dirty）。"""
    with open(MANIFEST, encoding="utf-8") as f:
        m = json.load(f)
    rev = _run("/usr/bin/git", "-C", REPO, "rev-parse", "--short", "HEAD")
    if rev and _run("/usr/bin/git", "-C", REPO, "status", "--porcelain", "--untracked-files=no"):
        rev += "-dirty"
    if not rev:  # 不是 git 仓库（比如 rsync 过去的副本）：同步的人写在 .luoke-commit 里
        try:
            with open(os.path.join(REPO, ".luoke-commit"), encoding="utf-8") as f:
                rev = f.read().strip()
        except OSError:
            pass
    return {"accessory": m["accessory"], "version": m["version"], "commit": rev or None}


def write(path, task, evalset, combo, score, latency, items, **extra):
    """task：主控里的任务名（luoke-ime.rerank、luoke-ime.predict）；evalset：语料文件的路径（只记文件名、条数和哈希）；
    combo：{"scorer": local / hub, "model", "params"（主控给的任务参数）, …}；score、latency：汇总；items：逐条结果。"""
    out = dict(accessory(), task=task,
               evalset={"name": os.path.basename(evalset), "sha256": sha256(evalset), "n": len(items)},
               combo=combo, machine=machine(), date=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               score=score, latency=latency, **extra, items=items)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")
