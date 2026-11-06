#!/bin/zsh
# 编译并组装 NotchHub.app（本地签名）。用法：./build.sh [--install]
set -e
cd "${0:A:h}"
mkdir -p build
# src/private/ 不进仓库：放只属于本机的代码和 local.env（可设置 BUNDLE_ID）。
LOCAL_FLAGS=(); LOCAL_SOURCES=(); BUNDLE_ID=""
if [[ -d src/private ]]; then
  LOCAL_FLAGS=(-D NOTCHHUB_LOCAL)
  LOCAL_SOURCES=(src/private/*.swift)
  [[ -f src/private/local.env ]] && source src/private/local.env
fi
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework Security -framework IOKit \
  -framework ServiceManagement -framework Combine \
  $LOCAL_FLAGS src/*.swift src/shared/*.swift $LOCAL_SOURCES -o build/NotchHub
build/NotchHub --self-test
# 可选依赖：统计 DSH 的 token 用量时需要，装不上也不影响其他功能。
if [[ ! -d resources/vendor/zstandard ]]; then
  /usr/bin/python3 -m pip install --quiet --target resources/vendor zstandard || echo "提示：zstandard 未安装，将跳过 DSH 的 token 统计"
fi
APP=build/NotchHub.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp Info.plist $APP/Contents/
[[ -n "$BUNDLE_ID" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" $APP/Contents/Info.plist
cp build/NotchHub $APP/Contents/MacOS/
cp -R resources/ $APP/Contents/Resources/
codesign --force --deep --sign - $APP
codesign --verify --deep $APP
echo "已生成 $APP"
if [[ "$1" == "--install" ]]; then
  pkill -x NotchHub 2>/dev/null || true
  sleep 0.5
  rm -rf ~/Applications/NotchHub.app
  ditto $APP ~/Applications/NotchHub.app
  open ~/Applications/NotchHub.app
  echo "已安装到 ~/Applications/NotchHub.app 并启动"
fi
