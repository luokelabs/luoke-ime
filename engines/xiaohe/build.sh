#!/bin/zsh
# 编译小鹤双拼引擎：Swift 主程序 + RIME 辅助进程（链 scripts/build-librime.sh 按旧系统编的 librime）；第一次会下载雾凇词库（GPL-3.0，不进仓库）。
#   RIME_ICE=<已有的雾凇词库目录> ./build.sh    用本机已有的词库，不下载
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
cd $here
# 部署目标 macOS 14（和 LuokeIME.app 一样）：不写就是本机的系统版本，装到更老的系统上起不来
export MACOSX_DEPLOYMENT_TARGET=14.0
lib=$root/vendor/librime
$root/scripts/build-librime.sh   # 编好的版本对得上就跳过
swiftc -O -target arm64-apple-macos$MACOSX_DEPLOYMENT_TARGET -o xiaohe *.swift
cc -O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -o rime_helper rime_helper.c -I$lib/include -L$lib/lib -lrime \
  -Wl,-rpath,@loader_path/lib -Wl,-rpath,$lib/lib
# 带的雾凇必须是 licenses/rime-ice/UPSTREAM 记的那一版（GPL 的源码对应）：vendor/rime-ice.rev 记着现在这份是哪一版，
# 对不上（钉住的提交改了上游版本、或者是老的没记版本的那份）就删掉重取
rev=$(sed -n 's/^提交：\([0-9a-f]\{40\}\).*/\1/p' $root/licenses/rime-ice/UPSTREAM)
[[ -n $rev ]] || { print -u2 "licenses/rime-ice/UPSTREAM 里没有提交号"; exit 1; }
if [[ -z "${RIME_ICE:-}" && "$(cat vendor/rime-ice.rev 2>/dev/null)" != "$rev" ]]; then rm -rf vendor/rime-ice vendor/rime-ice.rev; fi
if [[ ! -f vendor/rime-ice/double_pinyin_flypy.schema.yaml ]]; then
  mkdir -p vendor
  if [[ -n "${RIME_ICE:-}" ]]; then rsync -a --exclude .git "$RIME_ICE/" vendor/rime-ice/   # 用本机已有的：版本自己负责，不记
  else
    git init -q vendor/rime-ice
    git -C vendor/rime-ice fetch -q --depth 1 https://github.com/iDvel/rime-ice.git $rev
    git -C vendor/rime-ice checkout -q FETCH_HEAD
    rm -rf vendor/rime-ice/{.git,.github,.gitignore,LICENSE,others,build,README.md,AGENTS.md,custom_phrase.txt}  # LICENSE 打包时从 licenses/ 带
    print $rev > vendor/rime-ice.rev
  fi
fi
./xiaohe --selftest
