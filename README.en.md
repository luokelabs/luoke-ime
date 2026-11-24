# Luoke IME (螺壳输入法)

[简体中文](README.md) | **English**

A Chinese input method for macOS. Candidates appear as fast as with Apple's built-in input method, then a small on-device model picks again based on what you have already written. What you type never leaves your Mac.

## What it is

Luoke IME is a component of [Luoke](https://github.com/luokelabs/luoke). The input method itself only captures keys, shows candidates, commits text and runs the sandbox. Which candidates to show is entirely up to **engines**. An engine is a separate child process that speaks JSON lines over stdin/stdout and runs in a Seatbelt sandbox that allows only what the engine declares. The smallest one is about a dozen lines. The model used for re-ranking and suggestions runs on your Mac inside Luoke (luoke-core), and the text you commit is written to Luoke Memory (luoke-mem) on the same Mac. For how the components fit together, see the [input method page in the system docs](https://luokelabs.github.io/luoke-atlas/#ime) (in Chinese).

Bundled engines:

- [Xiaohe Shuangpin](engines/xiaohe), [Ziranma Shuangpin](engines/ziranma) and [Quanpin](engines/quanpin): candidates come from Apple's converter and RIME (the rime-ice dictionary), then the on-device model re-ranks them word by word using the preceding text. On the author's own blog corpus (600 sentences), the first candidate is right about 90% of the time, against 78.8% for Apple's built-in Shuangpin ([source](engines/xiaohe/README.md)).
- Fuzzy pinyin: z = zh, s = sh, c = ch, an = ang, en = eng, in = ing. Off by default; turn groups on under General in settings.
- Typo correction (Shuangpin): when the keys can't be read as syllables, the engine tries fixing one nearby key (a neighbouring key, an extra or missing key, two keys swapped), lets the model pick by the preceding text, and puts the corrected sentence first, marked ✎ (✦ marks a word the model swapped in from context). Correctly typed keys are never changed. On the blog corpus with one random typo per sentence, the first candidate goes from 4.3% to 22.2% right ([source](engines/xiaohe/README.md)).
- [Personalization component](engines/personal): writes committed text to Luoke Memory, asks Luoke for model scores on behalf of the typing engines, and provides next-phrase suggestions.
- [Minimal example](examples/minimal): a lookup-table engine in about a dozen lines of Python. Start here to write a new engine.
- [Voice](engines/voice): hold right ⌥ to speak, release to commit (the key can be switched to right ⌘ or right ⌃). Recognition and tidying (dropping filler words, smoothing self-corrections, laying out lists and paragraphs) are done by Luoke on your Mac. Off by default; turn it on under General in Settings.

## Status

- **In closed beta** (beta1 ships input method 0.1.20; `main` is at 0.1.116).
- **Requirements**: a Mac with Apple silicon, macOS 26.2 or later. So far verified only on macOS 26 and 27.
- How fast the model runs depends on the chip. On Pro and Max chips it almost always finishes before you press space. Slower machines such as the M1 run fewer steps, and the first candidate is still more accurate than Apple's; see "slow machines" in the [Xiaohe engine README](engines/xiaohe/README.md). How the accuracy, speed and suggestion numbers were measured, and on which chips, is in [docs/评测.md](docs/评测.md) (in Chinese). Without Luoke, or when it is unavailable, typing works as usual with candidates from Apple and RIME only, without re-ranking or suggestions.
- Most candidates come from Apple's converter that ships with macOS (the private library `libmecabra`), called through non-public interfaces. A macOS update may break it. If that happens, Xiaohe, Ziranma and Quanpin turn themselves off and say why.

## How to use it

Download Luoke from [luoke.ai](https://luoke.ai) and turn on Luoke IME under Apps in Luoke. After installing, you add the input source once by hand in System Settings (Keyboard → Text Input → Input Sources → Edit…); Luoke walks you through it.

## Building from source

You need Xcode (Swift 6), `cmake` and `git`. The first build downloads the sources of librime and its dependencies, plus the rime-ice dictionary. These downloads happen only on the build machine; the input method makes no network connections at runtime.

```bash
swift build                                         # the shell and the luoke-ime command-line tool
swift test                                          # state machine and engine host tests (they start real child processes and sandboxes)
.build/debug/luoke-ime check examples/minimal       # check an engine: protocol, sandbox denials
.build/debug/luoke-ime try examples/minimal --keys 'nihaowo1{space}'
.build/debug/luoke-ime try examples/minimal         # interactive mode: type in the terminal
```

To install it as your input method:

```bash
scripts/install.sh
```

This builds everything, assembles the bundled engines, signs the app and installs it into `~/Library/Input Methods`. Without a Developer ID certificate it signs ad hoc. After the first install, add it by hand in System Settings under Keyboard → Text Input → Input Sources. Each engine also builds on its own: `engines/xiaohe/build.sh`, `engines/quanpin/build.sh`, and `engines/personal/build.sh` for the personalization component. The last one needs a checkout of [luoke-mem](https://github.com/luokelabs/luoke-mem) next to this repository. Packaging and signing details are in [docs/发布打包.md](docs/发布打包.md) (in Chinese).

## Writing an engine

Engines can be written in any language: read stdin, write stdout. Start with [docs/写引擎.md](docs/写引擎.md) and the [minimal example](examples/minimal); the full protocol is in [docs/引擎协议.md](docs/引擎协议.md) (both in Chinese). Put your own engine in `~/.luoke/ime/engines/<name>/` and switch to it from the input menu. Third-party engines can never use the network or the GPU, and can write only to their own data directory. The first time you enable one, it lists the permissions it wants and you confirm them.

## Data and privacy

- **The input method does not use the network.** It talks only to Luoke's Unix socket on your Mac (for scoring and suggestions), and engines run in sandboxes with no network access.
- **It learns from what you type, on by default.** Committed text is written to Luoke Memory on your Mac to make candidates and suggestions better. You are told the first time you use it, and you can turn it off under General in the input method's settings. Nothing is recorded during secure input such as password fields. You can also stop recording for a particular app, or pause all recording from the menu.
- **Where data lives:** the input method's own settings and engine data are in `~/.luoke/ime/`. For example, the words you picked over the first candidate are in `~/.luoke/ime/data/<engine>/memory.json`. What is written to Luoke Memory can be viewed, edited and deleted in Luoke (the 管理记忆 item in the input menu).
- When you first add the input source, macOS warns that the developer can read everything you type with it. macOS shows this for every third-party input method.

The design rationale is in ADRs [0005](docs/adr/0005-permissions-requested-when-an-engine-needs-them.md), [0006](docs/adr/0006-engines-run-in-a-sandbox.md), [0012](docs/adr/0012-third-party-engines-confirmed-and-offline.md) and [0013](docs/adr/0013-follow-the-machine-is-the-boundary.md).

## Documentation

The documents are in Chinese.

- [Design](docs/设计.md), [glossary](CONTEXT.md), [architecture decision records](docs/adr/)
- [Engine protocol](docs/引擎协议.md), [writing an engine](docs/写引擎.md)
- [Packaging](docs/发布打包.md), [redistribution and licenses](docs/再分发与许可.md)
- [Benchmarks](docs/评测.md): the published numbers and how they were measured; the benchmark tool is `engines/xiaohe/bench.py`, usage in the [Xiaohe engine README](engines/xiaohe/README.md)

## License

Copyright 2026 螺壳实验室 Luoke Labs. Released under the [Apache License 2.0](LICENSE). The name and icon are not licensed; see [NOTICE](NOTICE). Third-party components shipped in LuokeIME.app (the rime-ice dictionary under GPL-3.0-only, librime and others) carry their own licenses; see [licenses/](licenses/THIRD_PARTY_NOTICES.md).

To report a security issue, see [SECURITY.md](SECURITY.md). To contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).
