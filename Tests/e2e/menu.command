#!/bin/zsh
# 输入法菜单和设置窗口的真机核对（menu.swift）。要在图形会话里跑：ssh 里用 `open -a Terminal menu.command`，屏幕要先解锁。
# 跑的时候别碰键盘鼠标。
cd ${0:A:h}
mkdir -p results
rm -f results/menu-done
swiftc -O -o results/menu menu.swift 2> results/menu-build.log || { date > results/menu-done; exit 1; }
doc=results/menu-doc.txt
print -n "" > $doc
out=results/$(date +%Y%m%d-%H%M%S)-menu.json
caffeinate -dimsu -w $$ &
results/menu $out $doc 2> results/menu.stderr
echo $out > results/menu-done
