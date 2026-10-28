#!/bin/zsh
# 个人化组件：把 luoke_mem 带进 vendor/。自己带一份，不依赖螺壳记忆装在哪、是什么版本（luoke-mem DESIGN「版本和兼容」：
# 版本不同也能共用一个记忆文件）。取 luoke-mem 仓库里已经提交的版本，不取工作区里改到一半的。
#   LUOKE_MEM_REPO=<luoke-mem 仓库> ./build.sh    默认是和 luoke-ime 并排的 ../luoke-mem
set -euo pipefail
cd ${0:A:h}
repo=${LUOKE_MEM_REPO:-../../../luoke-mem}
rev=$(git -C "$repo" rev-parse --short HEAD)
rm -rf vendor
mkdir -p vendor
# 只带这三个：工具要用的接口都在里面，它们也不导入别的模块（luoke-mem DESIGN「版本和兼容」的约定）；
# learn、hub、ui、__main__ 是螺壳记忆 app 自己的，不进输入法
git -C "$repo" archive HEAD luoke_mem/__init__.py luoke_mem/memory.py luoke_mem/sensitive.py | tar -x -C vendor
print "luoke-mem $rev" > vendor/VERSION
python3 -c 'import sys; sys.path.insert(0, "vendor"); import luoke_mem; print("luoke_mem", luoke_mem.__version__)'
python3 -m unittest -q test_personal
