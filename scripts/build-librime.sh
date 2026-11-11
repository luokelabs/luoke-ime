#!/bin/zsh
# 按旧系统从源码编 librime（照鼠须管的做法）：依赖（glog、leveldb、marisa、opencc、yaml-cpp）静态链进一个 librime.1.dylib，
# lua 插件也合并进去。Homebrew 只有为当前系统编的预编译包（在 macOS 27 上编的就要求 27），装到 26 上加载不了。
#
#   scripts/build-librime.sh            编到 vendor/librime/（include/、lib/librime.1.dylib），已经有就跳过
#   LUOKE_REBUILD=1 scripts/build-librime.sh   重编
#
# 版本钉住，和之前用的 Homebrew 那份一样：librime 1.17.0、librime-lua ec52e48、boost 1.89.0（只用头文件）。
# 源码下载到 vendor/librime-src/（不进仓库）。部署目标 macOS 14（和 LuokeIME.app 的 LSMinimumSystemVersion 一样）。
set -euo pipefail
root=${0:A:h:h}
out=$root/vendor/librime
src=$root/vendor/librime-src
export MACOSX_DEPLOYMENT_TARGET=14.0
LIBRIME_TAG=1.17.0
LUA_PLUGIN_COMMIT=ec52e48ea18f11af37717a01c337f853215cf70b

# 编好的那份记着是按哪一版编的（$out/.luoke-version）：和这里钉住的对不上就连源码一起重来，
# 免得包里的库和许可里写的版本不符
want="librime $LIBRIME_TAG lua $LUA_PLUGIN_COMMIT nopaths"
if [[ -f $out/lib/librime.1.dylib && -z ${LUOKE_REBUILD:-} && "$(cat $out/.luoke-version 2>/dev/null)" == "$want" ]]; then
  print "librime 已经编好：$out（重编用 LUOKE_REBUILD=1）"; exit 0
fi
# 编不了就先停：别把旧的删了才发现（出版机上没有 cmake，要把编好的 vendor/librime 连 .luoke-version 一起放过去）
command -v cmake >/dev/null || { print -u2 "vendor/librime 不是这一版（要的是：$want），这台机器没有 cmake，重编不了"; exit 1; }
if [[ "$(cat $src/.luoke-version 2>/dev/null)" != "$want" ]]; then rm -rf "$src"; fi
rm -rf "$out"
mkdir -p "$src"
print $want > $src/.luoke-version
if [[ ! -d $src/librime ]]; then
  git clone -q --depth 1 --branch $LIBRIME_TAG --recurse-submodules --shallow-submodules https://github.com/rime/librime.git "$src/librime"
fi
cd "$src/librime"
if [[ ! -d plugins/lua ]]; then
  git clone -q https://github.com/hchunhui/librime-lua.git plugins/lua
  git -C plugins/lua checkout -q $LUA_PLUGIN_COMMIT
  (cd plugins/lua && [[ -f action-install.sh ]] && bash ./action-install.sh) || true   # 拉 lua 的源码到插件的 thirdparty/
fi
[[ -d deps/boost-1.89.0/boost ]] || bash ./install-boost.sh >/dev/null   # 下载、核对哈希、只装头文件（boost_libs 为空不编库）
export BOOST_ROOT=$src/librime/deps/boost-1.89.0
[[ -d $BOOST_ROOT/boost ]] || { print -u2 "boost 头文件没就位：$BOOST_ROOT"; exit 1; }

# 库里不带编译机的路径（用户名、目录）：源码路径（glog 的日志、断言里的 __FILE__）换成相对的；opencc 编进去的
# 安装目录（PKGDATADIR，-D 在 CXXFLAGS 前面，这里 -U 掉）不要，librime 给 opencc 的都是绝对路径，用不上它
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$root/=" CXXFLAGS="${CXXFLAGS:-} -ffile-prefix-map=$root/= -UPKGDATADIR"
[[ -f lib/libglog.a ]] || make deps >/dev/null   # glog、leveldb、marisa、opencc、yaml-cpp 编成静态库，装进 librime 的 include/、lib/
# 不经 Makefile 的 merged-plugins：要多传几个参数。不在 Homebrew 里找任何东西（它的库都是按本机系统编的），不要 gflags（只给命令行工具用）
rm -rf build
cmake . -Bbuild -DCMAKE_BUILD_TYPE=Release -DBUILD_MERGED_PLUGINS=ON -DENABLE_EXTERNAL_PLUGINS=OFF -DBUILD_TEST=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_Gflags=ON -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DCMAKE_IGNORE_PATH=/opt/homebrew/lib \
  -DBoost_NO_BOOST_CMAKE=TRUE -DBOOST_ROOT="$BOOST_ROOT" -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET >/dev/null
cmake --build build >/dev/null
rm -rf "$out"
mkdir -p "$out/lib" "$out/include"
cp build/lib/librime.1.dylib "$out/lib/" 2>/dev/null || cp "$(find build -name 'librime.1*.dylib' -type f | head -1)" "$out/lib/librime.1.dylib"
cp src/rime_api.h src/rime_api_deprecated.h src/rime_api_stdbool.h src/rime_levers_api.h "$out/include/" 2>/dev/null || cp src/rime_api*.h "$out/include/"
install_name_tool -id "@rpath/librime.1.dylib" "$out/lib/librime.1.dylib"
ln -sf librime.1.dylib "$out/lib/librime.dylib"   # 给链接器的 -lrime   # 引擎按 rpath 找：包里是 @loader_path/lib，开发时是这里
print -r -- "librime $LIBRIME_TAG ($(git rev-parse --short HEAD))，librime-lua $(git -C plugins/lua rev-parse --short HEAD)，boost 1.89.0，部署目标 $MACOSX_DEPLOYMENT_TARGET" > "$out/VERSION"
print "librime 已编好：$out"
otool -L "$out/lib/librime.1.dylib"
if otool -L "$out/lib/librime.1.dylib" | tail -n +2 | grep -vE '(/usr/lib|/System)/|@rpath/librime' | grep -q .; then
  print -u2 "librime 还引用了系统以外的动态库"; exit 1
fi
print $want > $out/.luoke-version   # 编成功了才记，下次对得上就跳过
