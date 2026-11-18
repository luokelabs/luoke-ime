#!/usr/bin/env python3
"""语音引擎分段的测试：不开麦克风、不连主控。

用合成的 WAV 当录音（test_wav），自己扮主控答转写：说 3 秒、停一下（segment_secs 设成 2，在停顿处分段），再松开。
分段以后，假的转写模型照抄它拿到的上下文（真模型在新的一段几乎没声音时会这样），看上屏的字有没有重复。

  ./build.sh && ./test_segments.py
"""
import json
import os
import random
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BINARY = os.path.join(HERE, "voice")
A = "另外，我注意到你说到的一点，就是把他对机器的了解列出来，变成我知道你机器上有多少多少文件。"
NEW = "所以我们换个做法。"
MID1, MID2 = "第三是数字和英文，比如 GitHub", "iPhone 17 这些写得对不对？"
LOUD, QUIET = 8000, 20  # 说话、停顿的振幅（停顿不能全是零：全零的块当话筒还没收音）
NOISY = 1000  # 底噪高的话筒的停顿：约 -35 dBFS，比原来认停顿的 -40 dBFS 响


def wav(path, parts):
    pcm = bytearray()
    for secs, amp in parts:
        for _ in range(int(secs * 16000)):
            pcm += struct.pack("<h", int(random.uniform(-amp, amp)))
    fmt = struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + fmt + b"data" + struct.pack("<I", len(pcm)) + pcm)


def dictate(tmp, name, parts, stop_at, after_roll, segment_secs=2, first=None, tidy=False):
    """按住、到 stop_at 秒松开；第一段的终稿答 first（默认 A），分段以后的转写都答 after_roll(上下文)。返回 (上屏的字, 显示过的草稿)。
    tidy：假的整理模型像真的一样，把每段都当成完整的话，末尾没有句末标点就补一个句号。
    "mark"：整理的结果用【】括起来（看得出整理的是哪一段还是整篇）；"slow"：同样括起来，但整篇编辑（A 和 NEW 都在）一直不答。"""
    first = first or A
    path = os.path.join(tmp, name + ".wav")
    wav(path, parts)
    p = subprocess.Popen([BINARY], cwd=HERE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    lock = threading.Lock()

    def put(m):
        with lock:
            p.stdin.write(json.dumps(m, ensure_ascii=False) + "\n")
            p.stdin.flush()

    put({"type": "hello", "options": {"test_wav": path, "tidy": bool(tidy), "segment_secs": segment_secs}})
    put({"type": "arm", "id": 1})
    put({"type": "start", "id": 1, "context": ""})
    out, shown, rolled = {}, [], threading.Event()

    def read():
        for line in p.stdout:
            m = json.loads(line)
            if m.get("type") == "ask":
                prm = m.get("params", {})
                if m.get("method") == "generate":
                    src = prm["messages"][-1]["content"].removeprefix("<<<\n").removesuffix("\n>>>")
                    if tidy in ("mark", "slow"):
                        if tidy == "slow" and A in src and NEW in src:
                            continue
                        out_text = "【" + src + "】"
                    else:
                        out_text = src if src[-1:] in "。！？.!?" else src.rstrip("，,、") + "。"
                    put({"type": "reply", "id": m["id"], "result": {"text": json.dumps({"text": out_text}, ensure_ascii=False)}})
                    continue
                if m.get("method") != "transcribe" or prm.get("want") in (None, "none", "cancel"):
                    put({"type": "reply", "id": m["id"], "result": {}})
                    continue
                if not rolled.is_set():
                    if prm["want"] == "final":
                        rolled.set()
                    text = first if prm["want"] == "final" else first[:10]
                else:
                    text = after_roll(prm.get("context", ""))
                put({"type": "reply", "id": m["id"], "result": {"text": text}})
            elif m.get("type") == "show":
                shown.append(m.get("text", ""))
            elif m.get("type") in ("commit", "end"):
                out["text"] = m.get("text", "")
                return

    t = threading.Thread(target=read, daemon=True)
    t.start()
    time.sleep(stop_at)
    put({"type": "stop", "id": 1})
    t.join(8)
    p.kill()
    return out.get("text"), shown


def no_hub(tmp):
    """螺壳没在跑：转问都答 unavailable。开头 0.5 秒全是零（话筒还没开始收音），所以「录音中」在提示之后才来，
    它也要带着「未连接螺壳」，不然壳上那句提示被盖掉，松开后只剩「整理中…」然后什么都没有。返回壳最后看到的提示。"""
    path = os.path.join(tmp, "nohub.wav")
    wav(path, [(0.5, 0), (2, LOUD), (0.5, QUIET)])
    p = subprocess.Popen([BINARY], cwd=HERE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    lock = threading.Lock()

    def put(m):
        with lock:
            p.stdin.write(json.dumps(m, ensure_ascii=False) + "\n")
            p.stdin.flush()

    hint, ended = [None], threading.Event()

    def read():
        for line in p.stdout:
            m = json.loads(line)
            if m.get("type") == "ask":
                put({"type": "reply", "id": m["id"], "error": {"code": "unavailable", "message": "主控不可用"}})
            elif m.get("type") == "show":
                hint[0] = m.get("hint")  # 壳每收到一条 show 就换掉提示
            elif m.get("type") in ("commit", "end"):
                ended.set()
                return

    put({"type": "hello", "options": {"test_wav": path}})
    put({"type": "arm", "id": 1})
    put({"type": "start", "id": 1, "context": ""})
    threading.Thread(target=read, daemon=True).start()
    time.sleep(2.5)
    put({"type": "stop", "id": 1})
    ended.wait(5)
    p.kill()
    return hint[0]


def main():
    if not os.path.exists(BINARY):
        sys.exit("先运行 ./build.sh")
    spoken_tail = [(3, LOUD), (0.6, QUIET), (2, LOUD), (0.5, QUIET)]
    cases = [
        ("刚分段就松开，模型照抄前文", [(3, LOUD), (2.5, QUIET)], 4.0, lambda ctx: A, A),
        ("分段后接着说，模型照抄前文再接新话", spoken_tail, 6.5, lambda ctx: A + NEW, A + NEW),
        ("分段后接着说，模型正常", spoken_tail, 6.5, lambda ctx: NEW, A + NEW),
        # 分段 3 秒、硬切 6 秒：5.8 秒松开，没在停顿处分段的话只有一段，上屏的就只有 A
        ("话筒底噪高，停顿也在停顿处分段", [(3.5, LOUD), (0.6, NOISY), (1.5, LOUD), (0.4, NOISY)], 5.8, lambda ctx: NEW, A + NEW, 3),
        # 切在一句话中间：整理给第一段补的句号不要，两段的英文中间空一格；汉字和英文、数字之间的空格去掉（壳按设置加）
        ("切在句中，整理补的句号不要", spoken_tail, 6.5, lambda ctx: MID2, "第三是数字和英文，比如GitHub iPhone 17这些写得对不对？", 2, MID1, True),
        # 分了段的：松开后整篇一起编辑一次，上屏它（不是各段整理完接起来的【A】【NEW】）
        ("分了段的松开后整篇一起编辑", spoken_tail, 6.5, lambda ctx: NEW, "【" + A + NEW + "】", 2, None, "mark"),
        # 整篇编辑等不到：用说话时各段整理好的（NEW 说完停了 0.5 秒，松开前也已经分段、整理好了）
        ("整篇编辑没等到，用各段整理好的", spoken_tail, 6.5, lambda ctx: NEW, "【" + A + "】【" + NEW + "】", 2, None, "slow"),
    ]
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for i, (name, parts, stop_at, after_roll, want, *seg) in enumerate(cases):
            got, shown = dictate(tmp, f"case{i}", parts, stop_at, after_roll, *seg)
            ok = got == want and not any(A + A in s for s in shown)
            bad += not ok
            print("通过" if ok else "不对", name, "" if ok else f"→ {got!r}")
        got = no_hub(tmp)
        ok = got == "未连接螺壳，语音输入不可用"
        bad += not ok
        print("通过" if ok else "不对", "螺壳没在跑，提示一直在", "" if ok else f"→ 最后的提示 {got!r}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
