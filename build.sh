#!/bin/zsh
# 编译并打包 SitReminder.app（Apple 芯片 + Intel 通用版本）
#   ./build.sh            只编译
#   ./build.sh --install  编译后安装到 ~/Applications 并启动
#   ./build.sh --zip      编译后生成 dist/SitReminder-<版本>.zip
#   ./build.sh --dmg      编译后生成 dist/SitReminder-<版本>.dmg（含「应用程序」快捷方式）
#   ./build.sh --release  同时生成 zip 和 dmg
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SitReminder.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -parse-as-library -O -swift-version 5 \
    -target ${arch}-apple-macos13.0 \
    Sources/SitReminder.swift -o build/SitReminder-${arch}
done
lipo -create build/SitReminder-arm64 build/SitReminder-x86_64 -output "$APP/Contents/MacOS/SitReminder"
rm build/SitReminder-arm64 build/SitReminder-x86_64

cp Info.plist "$APP/Contents/Info.plist"

# 图标
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
swift make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Built: $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x SitReminder 2>/dev/null || true
  sleep 1
  rm -rf ~/Applications/SitReminder.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/SitReminder.app
  echo "Installed: ~/Applications/SitReminder.app"
fi

if [[ "${1:-}" == "--zip" || "${1:-}" == "--release" ]]; then
  mkdir -p dist
  rm -f "dist/SitReminder-$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/SitReminder-$VERSION.zip"
  echo "ZIP: $PWD/dist/SitReminder-$VERSION.zip"
fi

if [[ "${1:-}" == "--dmg" || "${1:-}" == "--release" ]]; then
  STAGE=build/dmg
  rm -rf "$STAGE" && mkdir -p "$STAGE" dist
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "dist/SitReminder-$VERSION.dmg"
  hdiutil create -volname SitReminder -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov \
    "dist/SitReminder-$VERSION.dmg" >/dev/null
  echo "DMG: $PWD/dist/SitReminder-$VERSION.dmg"
fi
