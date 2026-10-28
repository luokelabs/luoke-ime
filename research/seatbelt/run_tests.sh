#!/bin/zsh
# 螺壳输入法 Seatbelt 实验：非交互重跑全部检查。需要 Xcode 命令行工具（swiftc / clang）和 /usr/bin/python3。
#   ./run_tests.sh                          全部（含一次到 1.1.1.1:443 的真实 TCP connect，证明 "any" 档放行）
#   LUOKE_SBX_NO_EXTERNAL=1 ./run_tests.sh  完全不碰外部网络
# 退出码：有 FAIL 项为 1，否则 0。
cd "${0:A:h}" || exit 2
exec /usr/bin/python3 run_tests.py "$@"
