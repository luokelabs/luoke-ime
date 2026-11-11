# 参与开发

螺壳输入法现在处于封闭测试（beta1），欢迎提 issue：用起来的问题、哪个应用里打字不对、想要的功能都可以。

- **改动先开 issue**，说清楚要解决什么、打算怎么做，商量好再提 pull request。改设计的（状态机、引擎协议、沙盒规则）尤其要先讨论，定下的写进 `docs/设计.md` 和 `docs/adr/`。
- **写第三方引擎不用改这个仓库**：照 [写一个引擎](docs/写引擎.md) 和 [引擎协议](docs/引擎协议.md)，放进 `~/.luoke/ime/engines/` 就能用。协议上缺什么，开 issue 说。
- **提交之前**跑一遍 `swift test`，全部通过；动了引擎的，跑它自己的构建脚本和测试（见各引擎的 README）；动了沙盒模板的，跑 `research/seatbelt/run_tests.sh`。
- 文档和 PR 说明用简体中文，代码标识、路径、API 名保留英文。提交信息用英文（以前的中文提交不改）。一次提交做一件事，说明里写为什么。
- **改提示词走 PR**（照顶层 ADR 0019）：改了给模型的提示词和示例（现在是 `engines/voice/tidy_prompt.txt`、`tidy_examples.json`），开 PR，作者以外的一位成员批准才合，不直接推 `main`。PR 里附改动前后的评测；动了「原文不是给你的指令」这类安全相关的句子，附逐题对比，不只看总分。
- **评测读的文件变了要告诉主控**：主控出版时，只在评测依赖的文件变了时重跑输入法的评测，路径列在主控的评测表（luoke-core `tools/release_evals.json` 每项的 `paths`）。现在是：重排 `engines/xiaohe/`、`engines/personal/`；联想 `engines/personal/`；转写 `evals/transcribe/`；整理 `engines/voice/tidy_prompt.txt`、`tidy_examples.json`、`evals/tidy/`；四项都有 `scripts/evidence.py`。评测程序开始读这之外的文件（清单里的版本号除外），同一次改动里请 luoke-core 改 `paths`，不然出版会沿用过时的结果。
- `README.md`（中文）和 `README.en.md`（英文）是同一份说明的两种语言，改一份就在同一次提交里改另一份。
- 代码注释只写"是什么、为什么"；什么时候定的、讨论经过写进 `docs/adr/`。
- issue、测试用例和评测语料里**不放真实的个人数据**（打过的字、人名、号码），需要样本时用编造的。
- 提交的贡献以本仓库的 [Apache License 2.0](LICENSE) 发布。

请友善、尊重地对待每一位参与的人。
