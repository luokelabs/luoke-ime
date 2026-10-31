#!/bin/zsh
# 把 main 同步到公开仓库的第一步：在 public 分支上加一个提交，树就是 main 的树（会话文件 CLAUDE.md、STATUS.md
# 不进 git，本来就不在树里），然后扫一遍泄漏。只在本地建提交，不推；推之前要先问负责人（顶层 ADR 0017）。
#   scripts/public-sync.sh [<提交，默认 main>]
# 额外要扫的词（机器名、人名这类不能写进公开树的）一行一个放在 $LUOKE_PUBLIC_SCAN（默认 ~/.luoke/public-scan.txt）。
set -euo pipefail
cd ${0:A:h:h}
src=${1:-main}
git fetch -q origin public
git rev-parse -q --verify public >/dev/null || git branch public origin/public
[[ $(git rev-parse public) == $(git rev-parse origin/public) ]] || { print "本地 public 和 origin/public 不一致，先对齐" >&2; exit 1 }
tree=$(git rev-parse "$src^{tree}")
[[ $tree == $(git rev-parse "public^{tree}") ]] && { print "public 已经和 $src 一样，不用同步"; exit 0 }

# 扫泄漏：个人邮箱、本机路径（文档示例里的用户名 me 不算）、对负责人的旧称、会话文件、额外的词
bad=0
scan() { if git -c core.quotePath=false grep -nI "$@" $tree -- . ; then bad=1; fi }
scan -E -e '[A-Za-z0-9._%+-]+@(gmail|qq|163|126|outlook|hotmail|icloud|me)\.com'
scan -P -e '/Users/(?!me/)[A-Za-z0-9_-]+'
scan -F -e '主''人'   # 分两段写，这个脚本自己才扫不到
for f in CLAUDE.md STATUS.md; do git cat-file -e "$tree:$f" 2>/dev/null && { print "树里有会话文件 $f"; bad=1 }; done
extra=${LUOKE_PUBLIC_SCAN:-$HOME/.luoke/public-scan.txt}
[[ -f $extra ]] && scan -F -i -f $extra
(( bad )) && { print "\n扫到上面这些，先在 main 上改掉再同步" >&2; exit 1 }

msg="同步到私有仓库 main 的 $(git rev-parse --short $src)"   # 私有的提交信息可能带内部内容，不抄过来
c=$(GIT_AUTHOR_NAME="Luoke Labs" GIT_AUTHOR_EMAIL=zhixian@luoke.ai GIT_COMMITTER_NAME="Luoke Labs" GIT_COMMITTER_EMAIL=zhixian@luoke.ai \
  git commit-tree $tree -p public -m "$msg")
git branch -f public $c
print "public 上加了 $c（$(git diff --shortstat origin/public $c)）"
print "问过负责人以后："
print "  git push origin public && git push https://github.com/luokelabs/luoke-ime.git public:main"
