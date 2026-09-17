#!/bin/bash
# 自动打包生成 DMG 与 ZIP 产物
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.1.0"
APP_NAME="Antigravity Switcher"
BUILD_DIR="build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_PATH="${BUILD_DIR}/Antigravity-Switcher-v${VERSION}.dmg"
ZIP_PATH="${BUILD_DIR}/Antigravity-Switcher-v${VERSION}-macOS.zip"

echo "=== [1/4] 编译最新应用构建 ==="
./build.sh

echo "=== [2/4] 准备 DMG 制作目录 ==="
rm -rf "${DMG_DIR}" "${DMG_PATH}" "${ZIP_PATH}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_PATH}" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

echo "=== [3/4] 制作 DMG 镜像 ==="
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}"

echo "=== [4/4] 制作 ZIP 归档包 ==="
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "=========================================="
echo "✅ 打包完成！发布包清单："
ls -lh "${DMG_PATH}" "${ZIP_PATH}"
