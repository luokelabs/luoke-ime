#!/usr/bin/env python3
"""螺壳输入法最小示例引擎：查一张全拼小表。协议见 docs/引擎协议.md。"""
import json
import sys

TABLE = {"ni": ["你", "呢", "泥"], "hao": ["好", "号"], "nihao": ["你好"], "wo": ["我", "握"], "women": ["我们"]}

for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("type") != "query":  # 不认识的消息一律忽略
        continue
    keys = msg["input"]
    candidates = [{"text": text, "consume": n}  # 从最长的前缀开始查，整句优先
                  for n in range(len(keys), 0, -1) for text in TABLE.get(keys[:n], [])]
    print(json.dumps({"type": "answer", "id": msg["id"], "candidates": candidates}, ensure_ascii=False), flush=True)
