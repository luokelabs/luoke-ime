#!/bin/zsh
# 在图形会话里注册螺壳输入源（ssh 会话里注册不进用户的输入源列表）。
cd ${0:A:h}
mkdir -p results
"$HOME/Library/Input Methods/LuokeIME.app/Contents/MacOS/LuokeIME" --register > results/register.log 2>&1
echo "exit=$?" >> results/register.log
