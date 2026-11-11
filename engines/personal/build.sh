#!/bin/zsh
# 个人化组件：把 luoke_mem 带进 vendor/，再跑组件的测试。vendor/ 只给测试和开发用、不进包：装好的组件用主控 Python 上的
# 那份 luoke_mem（personal.py 先导入它，导入不了才退到 vendor/）。取 luoke-mem 仓库里已经提交的版本，不取工作区里改到一半的。
#   LUOKE_MEM_REPO=<luoke-mem 仓库> ./build.sh    默认是和 luoke-ime 并排的 ../luoke-mem
set -euo pipefail
cd ${0:A:h}
repo=${LUOKE_MEM_REPO:-../../../luoke-mem}
rev=$(git -C "$repo" rev-parse --short HEAD)
rm -rf vendor
mkdir -p vendor
# 只带这三个：工具要用的接口都在里面，它们也不导入别的模块（luoke-mem DESIGN「版本和兼容」的约定）；
# learn、hub、ui、__main__ 是螺壳记忆 app 自己的，不进输入法。prompts/ 是提示词文件，memory.py 导入时读里面的
# labels.json（0.28.0 起有，之前的版本没有这个目录）
files=(luoke_mem/__init__.py luoke_mem/memory.py luoke_mem/sensitive.py)
[[ -n $(git -C "$repo" ls-tree -d HEAD luoke_mem/prompts) ]] && files+=(luoke_mem/prompts)
git -C "$repo" archive HEAD $files | tar -x -C vendor
print "luoke-mem $rev" > vendor/VERSION
python3 -c 'import sys; sys.path.insert(0, "vendor"); import luoke_mem; print("luoke_mem", luoke_mem.__version__)'
python3 -m unittest -q test_personal
