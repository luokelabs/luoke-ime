#!/bin/zsh
# 在测试机上跑一个组合：[SERVE=1] [INLINE=0] matrix.sh <bundle id> [textarea|input|editable] [用例.tsv]，打印每条用例的结果。
# SERVE=1 让测试页自己报告输入框状态（Chrome 要用）。
cd ${0:A:h}
mkdir -p results
{ echo "APP_ID=$1"; [[ -n "${2:-}" ]] && echo "PAGE=$2"; echo "CASES=${3:-xiaohe.tsv}"; [[ -n "${SERVE:-}" ]] && echo "SERVE=1"; } > results/run.env
rm -f results/done ~/.luoke/ime/data/xiaohe/memory.json
# INLINE=0：这一组照"拼音显示在候选窗里"跑（光标处没有显示串，查 Chromium、Electron 会不会把输入法接下的键再交给网页）。
# 先备份设置，跑完原样拷回
if [[ -n "${INLINE:-}" ]]; then
  cp -p ~/.luoke/ime/settings.json results/settings-before-matrix.json
  /usr/bin/python3 - "$INLINE" <<'PY'
import json, os, sys
p = os.path.expanduser("~/.luoke/ime/settings.json"); s = json.load(open(p))
s.setdefault("defaults", {})["inline"] = sys.argv[1] != "0"
for a in s.get("apps", {}).values(): a.pop("inline", None)
t = p + ".tmp"; json.dump(s, open(t, "w"), ensure_ascii=False, indent=1); os.replace(t, p)
PY
  sleep 2
fi
# 删掉记忆文件即可从干净的状态开始：引擎每次询问前会检查它。不要结束螺壳进程，Chrome 不会自动重连。
open -a Terminal run.command
for i in $(seq 1 300); do [[ -s results/done ]] && break; sleep 1; done
f=$(cat results/done); rm -f results/run.env ~/.luoke/ime/data/xiaohe/memory.json
[[ -n "${INLINE:-}" ]] && cp -p results/settings-before-matrix.json ~/.luoke/ime/settings.json
[[ -f "$f" ]] || { echo "没有结果：$(cat results/build.log results/e2e.stderr 2>/dev/null | tail -3)"; exit 1; }
/usr/bin/python3 - "$f" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if "case" in d:
        line = ("PASS " if d["ok"] else "FAIL ") + d["case"] + "  实际=" + repr(d["got"])
        for p in d["probes"]:
            line += f"\n      探针：光标处 {p['marked']} 字，候选窗{'有' if p['panel'] else '无'}，输入框 {p.get('field_frame')}，螺壳窗口 {p.get('panel_frames')}，内容 {p['text']!r}"
        print(line)
    elif d.get("phase") in ("done", "abort"):
        print(json.dumps(d, ensure_ascii=False))
PY
