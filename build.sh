#!/bin/bash
# 构建 Antigravity Account Switcher.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Antigravity Switcher"
APP_DIR="build/${APP_NAME}.app"
BINARY="AntigravitySwitcher"

mkdir -p "${APP_DIR}/Contents/MacOS"

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Antigravity Switcher</string>
    <key>CFBundleDisplayName</key>
    <string>Antigravity Switcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.didi.antigravity-switcher</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>AntigravitySwitcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Antigravity multi-account menu bar switcher</string>
</dict>
</plist>
PLIST

echo "[1/4] 编译 Swift..."
swiftc -swift-version 5 -O \
    Sources/AntigravitySwitcher/main.swift \
    -o "${APP_DIR}/Contents/MacOS/${BINARY}" \
    -framework AppKit -framework UserNotifications -framework ServiceManagement

echo "[2/4] 复制图标..."
if [ -f CodexSwitcher-reference/AppIcon.icns ]; then
    cp CodexSwitcher-reference/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null || {
        mkdir -p "${APP_DIR}/Contents/Resources"
        cp CodexSwitcher-reference/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
    }
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
fi

echo "[3/4] 签名 (ad-hoc)..."
codesign --force --sign - "${APP_DIR}" 2>/dev/null || true

echo "[4/4] 完成: $(pwd)/${APP_DIR}"
echo "运行: open \"$(pwd)/${APP_DIR}\""
