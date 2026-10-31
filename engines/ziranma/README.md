# 自然码双拼引擎

螺壳输入法的打字引擎，和[小鹤双拼](../xiaohe)共用一份代码（`../xiaohe/*.swift`，以 `--scheme ziranma` 运行）。候选来源、模型重排、记忆、emoji 和英文单词都和小鹤一样，见那边的说明。模型在[个人化组件](../personal)里，经壳转问它打分。

不同的只有键位：每个音节两个键，声母和小鹤一样（zh、ch、sh 是 v、i、u），零声母也一样（aa、ah、ee、eg、oo，其余照拼，比如 ai、an、ou）；韵母按自然码：

| 键 | 韵母 | 键 | 韵母 | 键 | 韵母 |
|---|---|---|---|---|---|
| q | iu | h | ang | l | ai |
| w | ia ua | j | an | z | ei |
| r | uan | k | ao | x | ie |
| t | ue ve | y | ing uai | c | iao |
| p | un | s | ong iong | v | ui ü |
| d | iang uang | f | en | b | ou |
| g | eng | m | ian | n | in |

o 兼作 uo。键位表在 `../xiaohe/Ziranma.swift`；RIME 那路用雾凇自带的自然码方案 `double_pinyin`。

博客语料 600 条（按键从小鹤换成自然码，`--typing 0`，M5 Max、macOS 27）：苹果和 RIME 先给的首选 78.8%，模型重排后 89.8%，和小鹤一样（交给苹果和模型的都是同样的全拼音节）。

```bash
./build.sh                       # 编译（用 ../xiaohe 的代码）、拷词库、自检
luoke-ime check .
# 语料的按键一列是小鹤的：把这一列逐行交给 --from-xiaohe（标准输入一行一串小鹤按键，输出自然码按键）换好再测
../xiaohe/bench.py 自然码语料.tsv --engine . --typing 0
```
