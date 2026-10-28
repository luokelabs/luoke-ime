#!/bin/zsh
# 编译全拼引擎：和小鹤双拼共用 ../xiaohe 的代码（以 --scheme quanpin 运行），把运行要用的东西都放进这个文件夹。
#   RIME_ICE=<已有的雾凇词库目录> ./build.sh    用本机已有的词库，不下载（默认先找 ../xiaohe/vendor/rime-ice）
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
cd $here
src=../xiaohe
export MACOSX_DEPLOYMENT_TARGET=14.0   # 同小鹤
lib=$root/vendor/librime
[[ -f $lib/lib/librime.1.dylib ]] || $root/scripts/build-librime.sh
swiftc -O -target arm64-apple-macos$MACOSX_DEPLOYMENT_TARGET -o quanpin $src/*.swift
cc -O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -o rime_helper $src/rime_helper.c -I$lib/include -L$lib/lib -lrime \
  -Wl,-rpath,@loader_path/lib -Wl,-rpath,$lib/lib
# 和小鹤那份的版本对不上就重新拷（小鹤那边按 UPSTREAM 记的提交取）
if [[ -z "${RIME_ICE:-}" && -f $src/vendor/rime-ice.rev && "$(cat vendor/rime-ice.rev 2>/dev/null)" != "$(cat $src/vendor/rime-ice.rev)" ]]; then
  rm -rf vendor/rime-ice vendor/rime-ice.rev
fi
if [[ ! -f vendor/rime-ice/rime_ice.schema.yaml ]]; then
  mkdir -p vendor
  if [[ -n "${RIME_ICE:-}" ]]; then rsync -a --exclude .git "$RIME_ICE/" vendor/rime-ice/
  elif [[ -f $src/vendor/rime-ice/rime_ice.schema.yaml ]]; then
    rsync -a --exclude .git $src/vendor/rime-ice/ vendor/rime-ice/
    [[ -f $src/vendor/rime-ice.rev ]] && cp $src/vendor/rime-ice.rev vendor/rime-ice.rev
  else $src/build.sh >/dev/null && rsync -a $src/vendor/rime-ice/ vendor/rime-ice/ && cp $src/vendor/rime-ice.rev vendor/rime-ice.rev; fi
fi
./quanpin --scheme quanpin --selftest
