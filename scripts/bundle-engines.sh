#!/bin/zsh
# 把自带的引擎组装成随 LuokeIME.app 发布的样子（docs/发布打包.md）：
#   scripts/bundle-engines.sh <输出目录>        比如 <app>/Contents/Resources/engines
#
# - 小鹤：程序、rime_helper、雾凇词库（附 GPL 全文和上游提交号）、lib/librime.1.dylib（scripts/build-librime.sh 按 macOS 14
#   编的，依赖静态链在里面，lua 插件也合并进去）。
# - 全拼：自己的程序和 rime_helper，lib/ 和 vendor/ 链到小鹤的（同一份代码，不重复带 48 MB 的词库）。
# - 个人化组件：只有脚本，用主控的 Python 和主控带的 luoke_mem（engine.json 的 luoke-python）；不带本机打分（scorer.py）。
# 只组装、临时签名：install.sh 之后用 Developer ID 由内向外重签所有 Mach-O。
set -euo pipefail
root=${0:A:h:h}
out=${1:?用法：scripts/bundle-engines.sh <输出目录>}
x=$root/engines/xiaohe q=$root/engines/quanpin p=$root/engines/personal

"$x/build.sh" >/dev/null
"$q/build.sh" >/dev/null
# 个人化组件的测试：照并排的 luoke-mem 仓库带一份 luoke_mem 进 vendor/ 再跑（只给测试用，不进包：
# 包里的组件用主控带的那份 luoke_mem，luoke-mem 的约定）
"$p/build.sh" >/dev/null
[[ -f $x/vendor/rime-ice/double_pinyin_flypy.schema.yaml ]] || { print -u2 "没有雾凇词库：先跑 engines/xiaohe/build.sh"; exit 1; }

rm -rf "$out"
mkdir -p "$out/xiaohe" "$out/quanpin" "$out/personal"

# ---- 小鹤
cp "$x/engine.json" "$x/xiaohe" "$x/rime_helper" "$out/xiaohe/"
ditto "$x/vendor/rime-ice" "$out/xiaohe/vendor/rime-ice"
cp "$root/licenses/rime-ice/LICENSE" "$root/licenses/rime-ice/UPSTREAM" "$out/xiaohe/vendor/rime-ice/"

# librime：scripts/build-librime.sh 按旧系统编的那一份，依赖静态链在里面、lua 插件合并在里面，只有这一个动态库。
# rime_helper 按 rpath 找它：包里是 @loader_path/lib；开发时那条指向 vendor/ 的 rpath 删掉。
lib=$out/xiaohe/lib
mkdir -p "$lib"
cp "$root/vendor/librime/lib/librime.1.dylib" "$lib/librime.1.dylib"
chmod u+w "$lib/librime.1.dylib"
install_name_tool -delete_rpath "$root/vendor/librime/lib" "$out/xiaohe/rime_helper" 2>/dev/null || true
if otool -L "$out/xiaohe/rime_helper" "$lib/librime.1.dylib" | tail -n +2 | grep -vE '^\S|(/usr/lib|/System)/|@rpath/librime.1.dylib' | grep -q .; then
  print -u2 "rime_helper 或 librime 还引用了包外的动态库："; otool -L "$out/xiaohe/rime_helper" "$lib/librime.1.dylib" >&2; exit 1
fi

# ---- 全拼（和小鹤共用 lib/ 和词库）
cp "$q/engine.json" "$q/quanpin" "$out/quanpin/"
cp "$out/xiaohe/rime_helper" "$out/quanpin/rime_helper"
ln -s ../xiaohe/lib "$out/quanpin/lib"
ln -s ../xiaohe/vendor "$out/quanpin/vendor"

# ---- 个人化组件。发布版只经主控打分、没有本机退路：不带本机打分的 scorer.py，engine.json 去掉
# GPU 权限和本机模型的选项（personal.py 找不到 scorer.py 时，选项 scorer 写什么都只经主控）
cp "$p/personal.py" "$out/personal/"
python3 - "$p/engine.json" "$out/personal/engine.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
m["permissions"].pop("gpu", None)
m["options"]["data"].pop("model", None)
m["options"]["data"]["scorer"] = "hub"
json.dump(m, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
find "$out" -name __pycache__ -prune -exec rm -rf {} +

# 改过装载路径的 Mach-O 原来的签名就失效了，Apple Silicon 上会被直接杀掉：先临时签上，能直接跑（install.sh 再用 Developer ID 重签）
install_name_tool -delete_rpath "$root/vendor/librime/lib" "$out/quanpin/rime_helper" 2>/dev/null || true
for f in "$lib"/*.dylib "$out"/xiaohe/{xiaohe,rime_helper} "$out"/quanpin/{quanpin,rime_helper}; do
  codesign --force --sign - "$f" 2>/dev/null
done

print "自带引擎已组装：$out（$(du -sh "$out" | cut -f1)）"
