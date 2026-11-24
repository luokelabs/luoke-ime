#!/usr/bin/env python3
"""语音引擎的 VAD 和热词纠正的测试：不开麦克风、不连主控。

- VAD 的分数和 earshot 本身对得上：testdata/earshot-1.wav（earshot 仓库自带的测试录音，MIT OR Apache-2.0）每帧的分数，
  testdata/earshot-1.scores 是照 earshot 1.2.2 逐行写的参考实现算的。
- 真人说话（earshot-1.wav）上屏；同样响的随机噪声（像键盘声、风扇声）不上屏，也不提示「音量过低」。
- 热词纠正：同音同调的人名、大小写和空格不对的英文专名换成热词；声调不同的、本身是别的词的不动。

  ./build.sh && ./test_vad.py
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
SPEECH = os.path.join(HERE, "testdata", "earshot-1.wav")


def noise_wav(path, secs, amp):
    pcm = b"".join(struct.pack("<h", int(random.uniform(-amp, amp))) for _ in range(int(secs * 16000)))
    fmt = struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + fmt + b"data" + struct.pack("<I", len(pcm)) + pcm)


def dictate(wav, final_text, hotwords=(), stop_at=3.0):
    """按住、stop_at 秒后松开；假主控的终稿答 final_text，个人化组件的热词答 hotwords。返回 (上屏的字或 None, 最后的提示)。"""
    p = subprocess.Popen([BINARY], cwd=HERE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    lock = threading.Lock()

    def put(m):
        with lock:
            p.stdin.write(json.dumps(m, ensure_ascii=False) + "\n")
            p.stdin.flush()

    out, hint, got_hot = {}, [None], threading.Event()

    def read():
        for line in p.stdout:
            m = json.loads(line)
            if m.get("type") == "ask":
                prm = m.get("params", {})
                if m.get("to") == "personal":
                    put({"type": "reply", "id": m["id"], "result": {"words": list(hotwords)}})
                    got_hot.set()
                elif m.get("method") == "transcribe" and prm.get("want") in ("draft", "final"):
                    put({"type": "reply", "id": m["id"], "result": {"text": final_text}})
                else:
                    put({"type": "reply", "id": m["id"], "result": {}})
            elif m.get("type") == "show":
                hint[0] = m.get("hint")
            elif m.get("type") in ("commit", "end"):
                out["text"] = m.get("text")
                return

    threading.Thread(target=read, daemon=True).start()
    put({"type": "hello", "options": {"test_wav": wav, "tidy": False}})
    got_hot.wait(2)
    time.sleep(0.1)
    put({"type": "arm", "id": 1})
    put({"type": "start", "id": 1, "context": ""})
    time.sleep(stop_at)
    put({"type": "stop", "id": 1})
    for _ in range(80):
        if "text" in out:
            break
        time.sleep(0.1)
    p.kill()
    return out.get("text"), hint[0]


def main():
    if not os.path.exists(BINARY):
        sys.exit("先运行 ./build.sh")
    bad = 0

    def check(ok, name, detail=""):
        nonlocal bad
        bad += not ok
        print("通过" if ok else "不对", name, "" if ok else detail)

    got = [float(x) for x in subprocess.run([BINARY, "--vad-scores", SPEECH], cwd=HERE, capture_output=True, text=True, check=True).stdout.split()]
    ref = [float(x) for x in open(os.path.join(HERE, "testdata", "earshot-1.scores")).read().split()]
    diff = max(abs(a - b) for a, b in zip(got, ref)) if len(got) == len(ref) else None
    flips = sum((a >= 0.5) != (b >= 0.5) for a, b in zip(got, ref))
    check(diff is not None and diff < 0.02 and flips <= 2, "VAD 的分数和 earshot 对得上",
          f"→ {len(got)}/{len(ref)} 帧，最大差 {diff}，判断不同的 {flips} 帧")

    with tempfile.TemporaryDirectory() as tmp:
        text, _ = dictate(SPEECH, "测试一下")
        check(text == "测试一下", "真人说话上屏", f"→ {text!r}")

        loud = os.path.join(tmp, "loud.wav")
        noise_wav(loud, 3.5, 8000)
        text, hint = dictate(loud, "测试一下")
        check(not text and not hint, "响的噪声不算说话，不上屏也不提示", f"→ {text!r} 提示 {hint!r}")

        words = ["张伟", "GitHub", "王小明", "实验", "ChatGPT"]
        text, _ = dictate(SPEECH, "章伟说 git hub 和 Chat GPT 都好用，往小明家走，做个试验，githubber 不算", words)
        want = "张伟说GitHub和ChatGPT都好用，往小明家走，做个试验，githubber不算"
        check(text == want, "热词纠正", f"→ {text!r}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
