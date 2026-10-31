#!/bin/zsh
# 卸载螺壳输入法（开发用；主控卸载时不走这里）：停用输入源、结束进程、删除安装包。引擎和数据（~/.luoke/ime）保留。
set -euo pipefail
dest="$HOME/Library/Input Methods/LuokeIME.app"
[[ -x "$dest/Contents/MacOS/LuokeIME" ]] && "$dest/Contents/MacOS/LuokeIME" --disable || true
# macOS 26 起，用户在系统设置里添加过的第三方输入法，停用调用不一定能把它从列表里拿掉（luokelabs/luoke-core#14）：
# 删包之前看一眼用户同意过的列表，还在就提醒去系统设置里移除，不然留下一个失效的输入源
if /usr/bin/defaults read com.apple.inputsources AppleEnabledThirdPartyInputSources 2>/dev/null | grep -q 'ai.luoke.inputmethod.Luoke'; then
  still=1
else
  still=0
fi
# 只结束装好的那份螺壳：按可执行文件的路径找进程号，不按名字（别的副本、开发版不碰）
pids=$(pgrep -f "^$dest/Contents/MacOS/LuokeIME( |\$)" || true)
[[ -n $pids ]] && { kill ${=pids} 2>/dev/null || true; }
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$dest" 2>/dev/null || true
rm -rf "$dest" "$dest.previous"
# 输入法自己的引擎临时目录（空的）和单实例的锁文件；开发实例的在 <根目录>-tmp，不碰
tmp="${TMPDIR:-/tmp}"
rm -rf "${tmp%/}/luoke-ime" "${tmp%/}/ai.luoke.inputmethod.Luoke.lock"
print "已卸载。引擎和数据还在 ~/.luoke/ime，不需要的话手动删除。"
if (( still )); then
  print "螺壳还在系统设置的输入法列表里：请到 系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… 里选中它、按 − 移除。"
fi
