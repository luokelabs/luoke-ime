#!/bin/zsh
# 螺壳跨应用测试。要在图形会话里跑（ssh 里用 `open -a Terminal run.command` 启动，借用终端的辅助功能授权）。
# 测试期间不要碰键盘鼠标。   CASES=用例.tsv APP_ID=bundle id 可改。
cd ${0:A:h}
mkdir -p results
# 从 ssh 用 open 启动时环境变量传不进来：要换用例或应用，写进 results/run.env（例如 CASES=shift.tsv）
[[ -f results/run.env ]] && source results/run.env
rm -f results/done
swiftc -O -o results/e2e e2e.swift 2> results/build.log || { date > results/done; exit 1; }
out=results/$(date +%Y%m%d-%H%M%S)-${APP_ID:-com.apple.TextEdit}${PAGE:+-$PAGE}.jsonl
caffeinate -dimsu -w $$ &
echo "== 螺壳跨应用测试：别碰键盘鼠标 =="
# 浏览器：PAGE=textarea / input / editable 选测试页里的输入框
# SERVE=1：从本机小服务打开测试页，页面自己报告输入框状态（给不响应辅助功能查询的浏览器用）
doc=()
server=
if [[ -n "${PAGE:-}" && -n "${SERVE:-}" ]]; then
  rm -f results/page-state.json
  /usr/bin/python3 pageserver.py 8765 & server=$!
  sleep 1
  doc=("http://127.0.0.1:8765/page.html?run=$(date +%s)#$PAGE")
elif [[ -n "${PAGE:-}" ]]; then
  doc=("file://${0:A:h}/page.html#$PAGE")
fi
results/e2e ${CASES:-minimal.tsv} $out ${APP_ID:-com.apple.TextEdit} "${doc[@]}" 2> results/e2e.stderr
[[ -n "$server" ]] && kill $server
echo "== 完成：$out =="
echo $out > results/done
