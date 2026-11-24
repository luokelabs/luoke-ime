# 第三方组件

螺壳输入法（LuokeIME.app）本身以 Apache-2.0 发布。随它一起发布的自带引擎（`Contents/Resources/engines/`）里有下面这些第三方组件，各自的许可原文在同名的文件夹里。查证见 `docs/再分发与许可.md`。

| 组件 | 版本 | 许可 | 在哪 | 上游 |
|---|---|---|---|---|
| 雾凇拼音（rime-ice） | 提交 da1fbe6（2026-10-05） | GPL-3.0-only | `engines/xiaohe/vendor/rime-ice`（全拼链到这里），原样带上，对应源码就是这些文件本身，见 `rime-ice/UPSTREAM` | https://github.com/iDvel/rime-ice |
| librime | 1.17.0（33e7814） | BSD-3-Clause | `engines/xiaohe/lib/librime.1.dylib`（下面几项都静态链在它里面） | https://github.com/rime/librime |
| librime-lua | ec52e48 | BSD-3-Clause | 合并在 librime.1.dylib 里 | https://github.com/hchunhui/librime-lua |
| Lua | 5.4.9 | MIT | 同上（librime-lua 自带的源码） | https://www.lua.org |
| glog | 0.7.1 | BSD-3-Clause | 同上 | https://github.com/google/glog |
| LevelDB | 1.23 | BSD-3-Clause | 同上 | https://github.com/google/leveldb |
| marisa-trie | 0.3.1 | BSD-2-Clause（与 LGPL-2.1-or-later 二选一，这里取 BSD） | 同上 | https://github.com/s-yata/marisa-trie |
| OpenCC | 1.1.9 | Apache-2.0 | 同上 | https://github.com/BYVoid/OpenCC |
| yaml-cpp | 2f86d13（2025-04-29） | MIT | 同上 | https://github.com/jbeder/yaml-cpp |
| earshot | 1.2.2 | MIT OR Apache-2.0（两份原文都在 `licenses/earshot`） | `engines/voice/earshot.bin`（权重原样）；做法照搬写成 Swift，在语音引擎 `engines/voice/voice` 里 | https://github.com/pykeio/earshot |
| Boost（只用头文件） | 1.89.0 | BSL-1.0 | 编进 librime 的模板代码 | https://www.boost.org |

librime 和这些依赖由 `scripts/build-librime.sh` 从源码编（部署目标 macOS 14，版本照 librime 1.17.0 的子模块），没有改动源码。

不随输入法发布、但运行时会用到的：苹果的转换引擎（macOS 自带的私有库 `/usr/lib/libmecabra.dylib`，调用了非公开接口，系统升级后可能失效）；个人化组件用螺壳主控带的 Python（主控自己附它的许可）。
