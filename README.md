# 螺壳输入法

**简体中文** | [English](README.en.md)

一个 macOS 中文输入法：候选和苹果自带的一样快地出来，再由本机的小模型按你前面写的内容重新挑一遍；打的字不离开你的电脑。

> **Luoke IME** is a minimal macOS Chinese input method (Xiaohe Shuangpin and Quanpin). Candidates come up instantly from Apple's converter and RIME, then a small on-device model re-ranks them by what you have already written and suggests what comes next. Nothing you type leaves your Mac. Full English version: [README.en.md](README.en.md).

## 它是什么

螺壳输入法是[螺壳](https://github.com/luokelabs/luoke)的一个组件。输入法本身只管捕捉按键、显示候选、上屏和沙盒，出什么候选全部交给**引擎**。引擎是独立的子进程，经标准输入输出说 JSON 行，跑在按声明放行的 Seatbelt 沙盒里，最小的只有十几行。打分和联想用的模型由螺壳（luoke-core）在本机跑，你上屏的字写进本机的螺壳记忆（luoke-mem）。各组件怎么分工，见[系统文档里的输入法一页](https://luokelabs.github.io/luoke-atlas/#ime)。

自带的引擎：

- [小鹤双拼](engines/xiaohe)、[全拼](engines/quanpin)：苹果的转换引擎和 RIME（雾凇词库）出候选，本机模型按前文逐词重排。在作者自己的博客语料（600 句）上，首选准确率约 90%，苹果自带的双拼是 78.8%（[出处](engines/xiaohe/README.md)）。
- [个人化组件](engines/personal)：把上屏写进螺壳记忆、替小鹤和全拼向螺壳要模型打分、给联想。
- [最小示例](examples/minimal)：十几行的 Python 查表引擎，写新引擎从这里开始。

## 现状

- **封闭测试中**（beta1，输入法 0.1.20；`main` 上是 0.1.23）。
- **系统要求**：Apple 芯片的 Mac，macOS 26 起。目前只在 macOS 26、27 上验证过。
- 模型跑得多快看芯片：Pro、Max 芯片上几乎总能在按空格之前选好。M1 这类较慢的机器会少算几步，首选仍比苹果自带的准，详见[小鹤引擎的「慢的机器」](engines/xiaohe/README.md)。准确率、速度和联想的数字怎么测的、在哪类芯片上测的，见[评测](docs/评测.md)。螺壳没装或不可用时照常打字，候选就是苹果和 RIME 的，没有重排和联想。
- 出候选的主力是 macOS 自带的苹果转换引擎（私有库 `libmecabra`），调用了它的非公开接口。系统升级后可能失效，失效时小鹤、全拼会停用并说明原因。

## 怎么用

到 [luoke.ai](https://luoke.ai) 下载螺壳，在螺壳的「应用」里开启螺壳输入法。装好后要在系统设置里手动添加一次输入源，螺壳会一步步带你做。

## 从源码构建

要 Xcode（Swift 6）、`cmake` 和 `git`。第一次构建会从网上下载 librime 及其依赖的源码和雾凇词库，只在构建的机器上下载，输入法运行时不联网。

```bash
swift build                                         # 壳和命令行版 luoke-ime
swift test                                          # 状态机和引擎宿主的测试（会真的起子进程和沙盒）
.build/debug/luoke-ime check examples/minimal       # 检查一个引擎：协议、沙盒拦截
.build/debug/luoke-ime try examples/minimal --keys 'nihaowo1{space}'
.build/debug/luoke-ime try examples/minimal         # 交互模式，在终端里试打
```

装进本机的输入法：

```bash
scripts/install.sh
```

这一步会构建、组装自带的引擎、签名，然后装进 `~/Library/Input Methods`。没有 Developer ID 证书就用临时签名。第一次装好后要在系统设置的「键盘」里手动添加输入源。各引擎单独构建：`engines/xiaohe/build.sh`、`engines/quanpin/build.sh`，个人化组件 `engines/personal/build.sh`（要和本仓库并排放一份 [luoke-mem](https://github.com/luokelabs/luoke-mem)）。打包和签名的细节见[发布打包](docs/发布打包.md)。

## 写一个引擎

引擎可以用任何语言写，读标准输入、写标准输出就行。从[写一个引擎](docs/写引擎.md)和[最小示例](examples/minimal)开始，协议全文在[引擎协议](docs/引擎协议.md)。自己写的引擎放进 `~/.luoke/ime/engines/<名字>/`，在输入法菜单里切换。第三方引擎永远不能联网、不能用 GPU、只能写它自己的数据目录；第一次启用时会列出它要的权限，由你确认。

## 数据和隐私

- **输入法不联网**。输入法本体只连本机螺壳的 Unix socket（打分和联想），引擎都跑在不许联网的沙盒里。
- **从你打的字里学，默认开着**：上屏的字写进本机的螺壳记忆，让候选和联想更准。第一次用时会提示；在输入法设置的「通用」里可以关。密码框这类安全输入时什么都不记；也可以按应用禁止记录，或者在菜单里暂停所有记录。
- **数据放在哪**：输入法自己的设置和引擎的数据在 `~/.luoke/ime/`，比如你改选过的词在 `~/.luoke/ime/data/<引擎>/memory.json`。写进螺壳记忆的内容在螺壳里能看、能改、能删（输入法菜单的「管理记忆」）。
- 第一次添加时，macOS 会提示「开发者能读取你用这个输入源输入的一切」，这是系统对所有第三方输入法都会说的话。

设计上的依据见 [ADR 0005](docs/adr/0005-permissions-requested-when-an-engine-needs-them.md)、[0006](docs/adr/0006-engines-run-in-a-sandbox.md)、[0012](docs/adr/0012-third-party-engines-confirmed-and-offline.md)、[0013](docs/adr/0013-follow-the-machine-is-the-boundary.md)。

## 文档

- [设计文档](docs/设计.md)、[术语](CONTEXT.md)、[设计决定记录](docs/adr/)
- [引擎协议](docs/引擎协议.md)、[写一个引擎](docs/写引擎.md)
- [发布打包](docs/发布打包.md)、[再分发与许可](docs/再分发与许可.md)
- [评测](docs/评测.md)：对外引用的数字和测法；评测程序 `engines/xiaohe/bench.py`，用法见[小鹤引擎](engines/xiaohe/README.md)

## 许可

Copyright 2026 螺壳实验室 Luoke Labs。以 [Apache License 2.0](LICENSE) 发布；名称和图标不随许可授予，见 [NOTICE](NOTICE)。随 LuokeIME.app 发布的第三方组件（雾凇拼音词库 GPL-3.0-only、librime 等）各有自己的许可，见 [licenses/](licenses/THIRD_PARTY_NOTICES.md)。

报告安全问题见 [SECURITY.md](SECURITY.md)，参与开发见 [CONTRIBUTING.md](CONTRIBUTING.md)。
