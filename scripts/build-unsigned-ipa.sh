#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT/ios"
BUNDLE_ID="com.aurora.music"
SCHEME="AuroraMusic"
CONFIG="Release"

cd "$IOS_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen：brew install xcodegen" >&2
  exit 1
fi

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 编译（无签名）"
xcodebuild \
  -project AuroraMusic.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath build \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  build

APP="build/Build/Products/Release-iphoneos/AuroraMusic.app"
test -d "$APP" || { echo "未找到 $APP" >&2; exit 1; }

echo "==> 打包无签名 IPA"
rm -rf Payload "$APP/_CodeSignature" "$APP/embedded.mobileprovision"
mkdir -p Payload
cp -R "$APP" Payload/

if command -v ldid >/dev/null 2>&1; then
  ldid -S"Payload/AuroraMusic.app" && echo "==> ldid 伪签名完成"
else
  echo "!! 未安装 ldid，包未伪签名。安装 AppSync 时请在设备上用 ldid 处理：ldid -S AuroraMusic.app"
fi

VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
OUT="$ROOT/dist/AuroraMusic-${VERSION}-unsigned.ipa"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
# -X 让 zip 忽略额外属性
zip -qryX "$OUT" Payload
rm -rf Payload

echo "==> 完成: $OUT"
shasum -a 256 "$OUT" || sha256sum "$OUT"
echo "bundle id: $BUNDLE_ID | 最低系统: iOS 16.0"
