#!/bin/zsh
# 构建螺壳输入法（壳 + 自带的小鹤、自然码、全拼、个人化组件，见 docs/发布打包.md）、签名、装进 ~/Library/Input Methods 并注册。
#
#   scripts/install.sh                 构建、组装、签名、安装、注册
#   LUOKE_SKIP_BUILD=1 …               用已有的 release 构建
#   LUOKE_SIGN_IDENTITY="…" …          指定签名证书（默认用 Developer ID，找不到就临时签名）
#   LUOKE_NOTARIZE=1 …                 签名带时间戳，提交苹果公证并 staple，过了才装（钥匙串里的 notarytool 条目，
#                                      默认 luoke.ai，LUOKE_NOTARY_PROFILE 可改；要能连上苹果）
#   LUOKE_NO_REGISTER=1 …              只装文件，不注册（比如在没有图形会话的 ssh 里）
#   LUOKE_OUT=<目录> …                 只组装、签名到这个目录，不安装
#
# 自带的引擎在 LuokeIME.app/Contents/Resources/engines；~/.luoke/ime/engines 里同名的引擎会盖过它们（开发时用），
# 用完记得挪走，不然一直用的是那份旧的。
set -euo pipefail

root=${0:A:h:h}
bundle_name="LuokeIME.app"
dest_dir="$HOME/Library/Input Methods"
dest="$dest_dir/$bundle_name"

if [[ -z "${LUOKE_SKIP_BUILD:-}" ]]; then
  swift build --package-path "$root" -c release --product LuokeIME
  swift build --package-path "$root" -c release --product luoke-ime
fi
bin=$(swift build --package-path "$root" -c release --show-bin-path)

# 组装用的这份放在 *.noindex 里、结束时注销：不然 Spotlight 会把它登记进 LaunchServices，按 bundle id 找输入法时可能落到它
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
tmp=$(mktemp -d)
stage="$tmp/stage.noindex"
mkdir -p "$stage"
app="$stage/$bundle_name"
trap '"$lsregister" -u "$app" 2>/dev/null; rm -rf "$tmp"' EXIT
c="$app/Contents"
mkdir -p "$c/MacOS" "$c/Resources"
ditto "$root/Resources/App/Info.plist" "$c/Info.plist"
ditto "$root/Resources/App/zh-Hans.lproj" "$c/Resources/zh-Hans.lproj"
ditto "$root/Resources/App/en.lproj" "$c/Resources/en.lproj"
ditto "$root/Resources/App/Guide" "$c/Resources/Guide"   # 添加引导里图文教程的截图
ditto "$root/Resources/App/luoke-accessory.json" "$c/Resources/luoke-accessory.json"   # 给主控的配件清单（luoke-core V1 §8）
ditto "$bin/LuokeIME" "$c/MacOS/LuokeIME"
ditto "$bin/luoke-ime" "$c/MacOS/luoke-ime"
swift "$root/scripts/make-icon.swift" "$c/Resources/MenuIcon.pdf"   # 菜单栏的小图标：方框里一个"螺"的模板图
# app 图标（Finder、系统设置里看到的）：从 Resources/App/AppIcon.png（1024×1024，换 logo 就换这张）生成 .icns
iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"
for px in 16 32 128 256 512; do
  sips -z $px $px "$root/Resources/App/AppIcon.png" --out "$iconset/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$root/Resources/App/AppIcon.png" --out "$iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$c/Resources/AppIcon.icns"
"$root/scripts/bundle-engines.sh" "$c/Resources/engines"
ditto "$root/licenses" "$c/Resources/licenses"   # 第三方许可（THIRD_PARTY_NOTICES.md）
cp "$root/LICENSE" "$root/NOTICE" "$c/Resources/"   # 螺壳输入法自己的许可（Apache-2.0）和署名

# 包里每个 Mach-O 的最低系统版本不能高于 Info.plist 写的：不指定部署目标就是本机的系统版本（引擎和库都中过招，
# 在 macOS 27 上编成要求 27，装到 26 上起不来）
minos=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$c/Info.plist")
too_new=$(find "$app" -type f \( -perm -u+x -o -name '*.dylib' \) | while read -r f; do
  file -b "$f" | grep -q Mach-O || continue
  v=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')
  # 用 if 不用 &&：最后一个文件没问题时 && 让整个循环以 1 结束，set -e 下脚本一声不吭就退出了
  if [[ -n $v && $(printf '%s\n%s\n' "$v" "$minos" | sort -V | tail -1) != "$minos" ]]; then print -r -- "$v ${f#$app/}"; fi
done)
if [[ -n $too_new ]]; then print -u2 "这些程序要求的系统比 LSMinimumSystemVersion $minos 新："; print -u2 -- "$too_new"; exit 1; fi

identity="${LUOKE_SIGN_IDENTITY:-Developer ID Application: Huanqing Lou (NJQ5W3T9K5)}"
notarize=${LUOKE_NOTARIZE:-}
timestamp=--timestamp=none
[[ -n "$notarize" ]] && timestamp=--timestamp   # 公证要求可信时间戳
signed=0
if [[ "$identity" != "-" ]] && security find-identity -v -p codesigning | grep -qF "$identity"; then
  # 由内向外：自带引擎里的每个 Mach-O（不跟随自然码、全拼链到小鹤的 lib/），再签壳的两个程序和整个 .app
  inner=("${(@f)$(find "$c/Resources/engines" -type f -perm -u+x -o -type f -name '*.dylib' | while read -r f; do
    if file -b "$f" | grep -q Mach-O; then print -r -- "$f"; fi; done)}")
  if codesign --force --options runtime $timestamp --sign "$identity" "${inner[@]}" >/dev/null 2>&1 &&
     codesign --force --options runtime $timestamp --entitlements "$root/Resources/App/entitlements.plist" \
       --sign "$identity" "$c/MacOS/luoke-ime" "$app" >/dev/null 2>&1; then
    signed=1
  else
    print -u2 "用「$identity」签名失败（ssh 会话里钥匙串可能是锁着的）"
  fi
fi
if (( ! signed )); then
  [[ -n "$notarize" ]] && { print -u2 "要公证就得用 Developer ID 签名，停下"; exit 1; }
  print -u2 "改用临时签名"
  codesign --force --deep --sign - "$app" >/dev/null
fi
codesign --verify --deep --strict "$app"

# 冒烟检查：能离屏画出候选窗。跑 SwiftPM 编出的那个光秃秃的可执行文件，不跑包里的：从临时目录跑一次包，它就以
# ai.luoke.inputmethod.Luoke 向 LaunchServices 登记了（.noindex 挡不住），正在用的输入法可能被系统认到这份临时副本上
#（换装后螺壳曾从输入法菜单里没了，原因没坐实，这是嫌疑之一）。光秃秃的可执行文件没有 bundle id，登记的是 (null)。
"$bin/LuokeIME" --render-panel "$stage/panel.png"

if [[ -n "$notarize" ]]; then
  profile="${LUOKE_NOTARY_PROFILE:-luoke.ai}"
  zip="$tmp/LuokeIME.zip"
  ditto -c -k --norsrc --noextattr --keepParent "$app" "$zip"   # 不带扩展属性：不然 zip 里会有 ._xxx 的 AppleDouble 文件
  print "提交公证（$profile），要等几分钟…"
  xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait > "$tmp/notarize.log" 2>&1 || true
  tail -3 "$tmp/notarize.log"
  if ! grep -q "status: Accepted" "$tmp/notarize.log"; then
    id=$(grep -m1 "  id: " "$tmp/notarize.log" | awk '{print $2}')
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --keychain-profile "$profile" 2>&1 | head -40
    else  # 没提交上：多半是读不到钥匙串里的凭据（锁屏时读不到）。等解锁再试，别重新存凭据
      cat "$tmp/notarize.log" >&2
      print -u2 "没能提交公证：钥匙串里的 $profile 读不到（Mac 锁屏时就读不到），解锁后再试"
    fi
    print -u2 "公证没通过，没有安装"; exit 1
  fi
  xcrun stapler staple "$app" | tail -1
  spctl -a -vv -t exec "$app" 2>&1 | tail -2
fi

if [[ -n "${LUOKE_OUT:-}" ]]; then
  mkdir -p "$LUOKE_OUT"
  rm -rf "$LUOKE_OUT/$bundle_name"
  ditto "$app" "$LUOKE_OUT/$bundle_name"
  # 输出的这份也注销：Finder 打开过这个文件夹就会把它登记进 LaunchServices（.noindex 只挡 Spotlight），按 bundle id 找螺壳时
  # 可能落到它（开发机上 build.noindex/release 里的四份都被登记过）。之后有人在 Finder 里看它，还得再注销。
  "$lsregister" -u "$LUOKE_OUT/$bundle_name" 2>/dev/null || true
  print "已组装：$LUOKE_OUT/$bundle_name"
  exit 0
fi

mkdir -p "$dest_dir"
# 换装：先把新包复制到同一个磁盘上的暂存处，再两次改名换上，空档只有几毫秒；换好以后只向 LaunchServices 登记新包，
# 不再请求启用（见下面的 --register）。菜单里没了螺壳的那次：系统的输入法菜单在换装时重读了输入源列表、之后一直没再读，
# 系统设置里删掉再加回来它才重读（设置文件前后一字不差）。
swap="$HOME/Library/Caches/ai.luoke.inputmethod.install.noindex"
rm -rf "$swap"
mkdir -p "$swap/new" "$swap/old"
# 中途失败也不留下同 bundle id 的副本：注销、删掉暂存处
cleanup_swap() { for d in "$swap/new/$bundle_name" "$swap/old/$bundle_name"; do [[ -e $d ]] && "$lsregister" -u "$d" 2>/dev/null; done; rm -rf "$swap"; }
if ! ditto "$app" "$swap/new/$bundle_name"; then cleanup_swap; print -u2 "安装失败：复制不到暂存处，原来的版本没动"; exit 1; fi
# 同一个 bundle id 的别的副本（比如卸载时移进废纸篓的旧包）还登记在 LaunchServices 里时，新装的这份可能切不过去、
# 菜单里是灰的（luokelabs/luoke-ime#15）：放新包之前，装好位置以外的一律注销（先放后注销不管用，系统的绑定不跟着变）
"$lsregister" -dump 2>/dev/null | awk '/^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); p = $0 }
  /^identifier: *ai\.luoke\.inputmethod\.Luoke$/ { print p }' | while IFS= read -r other; do
  [[ "$other" == "$dest" ]] && continue
  print "注销同 bundle id 的另一份：$other"
  "$lsregister" -u "$other" 2>/dev/null || true
done
# 只结束装好的那份螺壳：按可执行文件的路径找进程号，不按名字（别的副本、开发版不碰）
old_pids=$(pgrep -f "^$dest/Contents/MacOS/LuokeIME( |\$)" || true)
[[ -e "$dest" ]] && mv "$dest" "$swap/old/$bundle_name"
if ! mv "$swap/new/$bundle_name" "$dest"; then
  [[ -e "$swap/old/$bundle_name" ]] && mv "$swap/old/$bundle_name" "$dest"
  cleanup_swap
  print -u2 "安装失败，已恢复原来的版本"; exit 1
fi
"$lsregister" -f "$dest"
[[ -e "$swap/old/$bundle_name" ]] && { "$lsregister" -u "$swap/old/$bundle_name" 2>/dev/null || true; }
[[ -n $old_pids ]] && { kill ${=old_pids} 2>/dev/null || true; }   # 系统下次要用时从新包里拉起
rm -rf "$swap"

# 螺壳的目录只有自己能进：~/.luoke 旁边是记忆，~/.luoke/ime 里有开发模式的按键记录
[[ -d "$HOME/.luoke" ]] || mkdir -m 700 "$HOME/.luoke"
[[ -d "$HOME/.luoke/ime" ]] || mkdir -m 700 "$HOME/.luoke/ime"
chmod go-rwx "$HOME/.luoke/ime"
engines="$HOME/.luoke/ime/engines"
mkdir -p "$engines"
for e in xiaohe ziranma quanpin personal; do
  [[ -e "$engines/$e" ]] && print "注意：$engines/$e 会盖过包里自带的 $e（开发用；不需要了就挪走）"
done

if [[ -z "${LUOKE_NO_REGISTER:-}" ]]; then
  "$dest/Contents/MacOS/LuokeIME" --register
fi
print "螺壳已安装：$dest"
print "第一次安装需要你在系统设置里手动添加一次（macOS 26 起，第三方输入法只能由用户确认启用）："
print "  系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… → + → 简体中文 → 螺壳（英文系统里叫 Luoke 螺壳）"
print "  如果列表里没有：先完全退出系统设置（⌘Q）再打开——它只在打开时读一次输入源列表。"
print "以后重装不用再添加。"
