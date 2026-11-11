#!/usr/bin/python3
"""语音转写的评测（主控的 luoke-ime.transcribe 任务，ADR 0016）：照语音引擎的用法经主控转写一组句子，算字错率和松开到终稿的用时。

  eval_transcribe.py --hub <主控的 socket> [--result 证据.json] [--voices tingting] [--limit N]

- 音频：sentences.tsv 里的句子用 macOS 的 say 现合成（16 kHz 单声道 PCM16，只写临时文件，不开麦克风、不放声音），
  每句前后各垫 0.2 秒静音；另加两条「按住不说话」：2 秒全静音、2 秒 -50 dB 底噪。
- 送法和 engines/voice 一样：一次听写一个会话，音频按 1 秒一块追加，每块要一份草稿（等它回来再送下一块，不按实时等），
  最后一块要终稿。终稿的用时 ≈ 松开时没有草稿在算的情况下，从松开到上屏。
- 总分：字准确率（100 − 字错率），去掉标点和空格、不分大小写比；「数字」一类的写法本来就不统一（三百五十六 / 356），
  不算进总分，只放在分类的明细里。
- 硬性条目：按住不说话不能出字（只有「嗯」「啊」这类语气词和标点的算没出字，引擎会把它当没说话）。
- 没评成（主控没有这个任务、一直没就绪、拒了）退出码 3，不写证据，和 engines/xiaohe/bench.py 一样。
"""
import argparse
import base64
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
TASK = "luoke-ime.transcribe"
SR = 16000
VOICES = {"tingting": "Tingting", "eddy": "Eddy (Chinese (China mainland))"}
FILLERS = set("嗯呃啊哦额唔噢") | {"um", "uh", "hmm"}
NOT_EVALUATED = 3


def not_evaluated(reason):
    print("没评成：" + reason, file=sys.stderr, flush=True)
    sys.exit(NOT_EVALUATED)


class Hub:
    """主控（luoke-core）：HTTP/1.1 跑在 Unix socket 上（V1 §2），跟壳一样带 X-Luoke-Accessory。"""

    def __init__(self, path):
        self.path = path
        with open(os.path.join(REPO, "Resources", "App", "luoke-accessory.json"), encoding="utf-8") as f:
            self.accessory = "luoke-ime/" + json.load(f)["version"]

    def call(self, method, url, body=None, timeout=60):
        c = http.client.HTTPConnection("localhost", timeout=timeout)
        c.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.sock.settimeout(timeout)
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


def norm(s):
    return "".join(c for c in unicodedata.normalize("NFKC", s).lower() if unicodedata.category(c)[0] in "LN")


def has_words(text):
    """去掉标点、空格和语气词以后还有没有字。"""
    t = unicodedata.normalize("NFKC", text).lower()
    for f in sorted(FILLERS, key=len, reverse=True):
        t = t.replace(f, "")
    return bool(norm(t))


def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def synth(text, voice, path):
    subprocess.check_call(["/usr/bin/say", "-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000", "-o", path, text])
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        return w.readframes(w.getnframes())


def items(voices, tmp):
    pad = bytes(int(0.2 * SR) * 2)
    out = []
    for line in open(os.path.join(HERE, "sentences.tsv"), encoding="utf-8"):
        if not line.strip() or line.startswith("#"):
            continue
        sid, cat, ref, *rest = line.rstrip("\n").split("\t")
        for v in voices:
            pcm = synth(rest[0] if rest and rest[0] else ref, VOICES[v], os.path.join(tmp, f"{sid}_{v}.wav"))
            out.append(dict(id=f"{sid}_{v}", cat=cat, ref=ref, pcm=pad + pcm + pad))
    import random
    rng = random.Random(0)
    noise = bytearray()
    for _ in range(2 * SR):
        noise += int(rng.gauss(0, 32767 * 10 ** (-50 / 20))).to_bytes(2, "little", signed=True)
    out.append(dict(id="s01_silence", cat="silence", ref="", pcm=bytes(2 * SR * 2)))
    out.append(dict(id="s02_noise", cat="silence", ref="", pcm=bytes(noise)))
    return out


def request(hub, body):
    """一次转写请求；not_ready、busy 照 retry_after 原样重发（这一块当没收到）。返回 (答复, 毫秒)。"""
    for _ in range(90):
        t = time.perf_counter()
        status, r = hub.call("POST", f"/tasks/{TASK}/v1/transcribe", body)
        ms = (time.perf_counter() - t) * 1000
        if status < 400:
            return r, ms
        if r.get("code") not in ("not_ready", "busy"):
            not_evaluated(f"主控拒了转写：{status} {r}")
        time.sleep(min(float(r.get("retry_after") or 1), 3))
    not_evaluated("主控一直没就绪")


def dictate(hub, pcm):
    """照语音引擎的用法送一次听写：1 秒一块，每块要草稿，最后一块要终稿。返回 (终稿, 终稿毫秒, 草稿毫秒列表)。"""
    session, chunk = uuid.uuid4().hex, SR * 2
    blocks = [pcm[i:i + chunk] for i in range(0, len(pcm), chunk)] or [b""]
    drafts = []
    for seq, b in enumerate(blocks):
        want = "final" if seq == len(blocks) - 1 else "draft"
        r, ms = request(hub, {"session": session, "seq": seq, "audio": base64.b64encode(b).decode(), "want": want})
        if want == "draft":
            drafts.append(ms)
        else:
            return r.get("text") or "", ms, drafts, r.get("model")


def pct(v, q):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(q * len(v)))]) if v else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hub", required=True)
    ap.add_argument("--result")
    ap.add_argument("--voices", default="tingting", help="逗号分隔，tingting、eddy；出版机只有 Tingting，默认只用它，和流水线的分数能比")
    ap.add_argument("--limit", type=int)
    args = ap.parse_args()
    if args.result:  # 写证据用仓库里的 scripts/evidence.py：先导入，别测完了才发现找不到
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        import evidence  # noqa: F401
    voices = [v for v in args.voices.split(",") if v]
    have = subprocess.run(["/usr/bin/say", "-v", "?"], capture_output=True, text=True).stdout
    missing = [VOICES[v] for v in voices if VOICES[v] not in have]
    if missing:  # 评测机的事，不是评测程序出错：照「没评成」退出，发布流水线不当成出错
        not_evaluated(f"这台 Mac 没有 {'、'.join(missing)} 这个声音：系统设置 → 辅助功能 → 朗读内容 → 系统声音 里加")

    hub = Hub(args.hub)
    status, tasks = hub.call("GET", "/tasks")
    if status >= 400 or TASK not in (tasks.get("tasks") or {}):
        not_evaluated(f"主控里没有 {TASK}")
    info = tasks["tasks"][TASK]
    hub.call("POST", "/warmup", {"task": TASK})

    with tempfile.TemporaryDirectory(prefix="luoke-transcribe-") as tmp:
        its = items(voices, tmp)
    if args.limit:
        its = its[: args.limit] + [i for i in its if i["cat"] == "silence"]
    dictate(hub, its[0]["pcm"])  # 第一次要编内核，不算

    results, model = [], None
    for n, it in enumerate(its, 1):
        text, ms, drafts, model = dictate(hub, it["pcm"])
        r = dict(id=it["id"], cat=it["cat"], audio_secs=round(len(it["pcm"]) / 2 / SR, 2), final_ms=round(ms),
                 draft_ms=[round(d) for d in drafts])
        if it["cat"] == "silence":
            r["words"] = has_words(text)
        else:
            r["errors"], r["chars"] = edits(norm(it["ref"]), norm(text)), len(norm(it["ref"]))
        results.append((it, text, r))
        if n % 10 == 0:  # 进度走标准错误：主控的发布脚本按它判断是不是停住了
            print(f"进度 {n}/{len(its)}", file=sys.stderr, flush=True)

    speech = [r for _, _, r in results if r["cat"] not in ("silence", "number")]
    cer = sum(r["errors"] for r in speech) / max(1, sum(r["chars"] for r in speech))
    cats = {}
    for _, _, r in results:
        if r["cat"] != "silence":
            c = cats.setdefault(r["cat"], [0, 0])
            c[0] += r["errors"]
            c[1] += r["chars"]
    silent_ok = all(not r["words"] for _, _, r in results if r["cat"] == "silence")
    finals = [r["final_ms"] for _, _, r in results]
    drafts = [d for _, _, r in results for d in r["draft_ms"]]
    score = {"char_accuracy_pct": round(100 * (1 - cer), 1), "cer_pct": round(100 * cer, 2),
             "by_category_cer_pct": {k: round(100 * e / max(1, n), 1) for k, (e, n) in cats.items()},
             "silence_no_words": silent_ok, "hard_ok": silent_ok, "voices": voices}
    latency = {"final": {"p50_ms": pct(finals, 0.5), "p90_ms": pct(finals, 0.9)}, "draft": {"p50_ms": pct(drafts, 0.5), "p90_ms": pct(drafts, 0.9)}}

    print(f"n={len(results)}  字准确率 {score['char_accuracy_pct']}%（不算数字）  按住不说话不出字：{'是' if silent_ok else '否'}")
    print("分类字错率：" + "  ".join(f"{k} {v}%" for k, v in score["by_category_cer_pct"].items()))
    print(f"终稿 p50 / p90 {latency['final']['p50_ms']} / {latency['final']['p90_ms']} ms，草稿 p50 / p90 {latency['draft']['p50_ms']} / {latency['draft']['p90_ms']} ms")
    for it, text, r in results:
        if r.get("errors") or r.get("words"):
            print(f"  {it['id']}：{it['ref'] or '（静音）'} → {text}")
    if args.result:
        import evidence
        # 逐条结果带识别出的字：句子是评测集自己写的，不是用户的数据
        evidence.write(args.result, TASK, os.path.join(HERE, "sentences.tsv"),
                       {"scorer": "hub", "model": model, "params": info.get("params")}, score, latency,
                       [dict(r, text=text) for _, text, r in results])


if __name__ == "__main__":
    main()
