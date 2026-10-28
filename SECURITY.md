# 安全问题

输入法看得到你打的每一个键，所以安全问题我们会优先处理。如果你发现螺壳输入法的安全问题，比如打的字会离开本机、引擎能绕过沙盒、安全输入时还在记录、能被别的程序或网页利用，请**不要在公开 issue 里写细节**，用 GitHub 的私密漏洞报告：

1. 打开本仓库的 **Security** 页；
2. 点 **Report a vulnerability**，写清楚影响哪个版本（螺壳「应用」里显示的输入法版本，或 `~/Library/Input Methods/LuokeIME.app` 的版本号）、macOS 版本、怎么复现、可能的影响。

本仓库还没公开时，报到顶层仓库 [luokelabs/luoke](https://github.com/luokelabs/luoke/security) 就行。我们会尽快回复，修好以后在发布说明里注明。

请不要在报告里附上真实打过的字、记忆内容或开发模式的记录；需要样本时用编造的数据。

---

If you find a security issue in Luoke IME (typed text leaving the Mac, an engine escaping its sandbox, recording during secure input, and so on), please report it privately via **Security → Report a vulnerability** on this repository, or on [luokelabs/luoke](https://github.com/luokelabs/luoke/security) while this repository is private. Please don't include real typed text or other personal data in reports.
