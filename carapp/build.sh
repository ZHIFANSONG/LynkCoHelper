#!/bin/bash
# 构建 CarCtrl.app 并不签名打成 IPA
# 用法：./build.sh [--sign]
#   --sign  额外做 ad-hoc 签名（codesign --force --sign -），便于 zsign 等工具重签
set -e

SDK=/opt/theos/sdks/iPhoneOS18.5.sdk
DEPLOY=16.0
OUT=out
APP=build/CarCtrl.app
SRC=src

rm -rf build "$OUT"
mkdir -p "$APP" "$OUT"

echo "== 1/5 编译 Swift =="
swiftc -sdk "$SDK" \
  -target arm64-apple-ios$DEPLOY \
  -O \
  -module-name CarCtrl \
  -emit-executable \
  -o "$APP/CarCtrl" \
  -framework SwiftUI \
  -framework UIKit \
  -framework SceneKit \
  -framework CoreGraphics \
  -framework MapKit \
  -framework CoreLocation \
  -framework Foundation \
  "$SRC"/AppMain.swift \
  "$SRC"/ContentView.swift \
  "$SRC"/Design.swift \
  "$SRC"/ModelLoader.swift \
  "$SRC"/EnergyView.swift \
  "$SRC"/FindCarView.swift \
  "$SRC"/SettingsView.swift \
  "$SRC"/Models.swift \
  "$SRC"/Api.swift \
  "$SRC"/Crypto.swift

file "$APP/CarCtrl"
lipo -info "$APP/CarCtrl" || true

echo "== 2/5 拷贝资源 =="
cp "$SRC"/Info.plist "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
cp res/cardata.bin "$APP/cardata.bin"
cp res/carparts.json "$APP/carparts.json"
if [ -d res/cartex ]; then
  mkdir -p "$APP/cartex"
  cp res/cartex/* "$APP/cartex/"
fi
if [ -d res/icons ]; then
  cp res/icons/*.png "$APP"/
fi
if [ -f res/AppIcon.png ]; then
  cp res/AppIcon.png "$APP/AppIcon.png"
fi

echo "== 3/5 校验 Info.plist =="
plutil -lint "$APP/Info.plist"

echo "== 4/5 可选签名 =="
if [ "$1" = "--sign" ]; then
  codesign --force --sign - --timestamp=none "$APP" || true
  codesign -dv "$APP" 2>&1 | head -5 || true
else
  echo "跳过签名（用户自行处理）"
fi

echo "== 5/5 打包 IPA =="
rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP" build/Payload/
( cd build && zip -qry "../$OUT/CarCtrl.ipa" Payload )

ls -lh "$OUT/CarCtrl.ipa"
echo "== 完成 =="
unzip -l "$OUT/CarCtrl.ipa" | head -12
