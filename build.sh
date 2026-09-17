#!/bin/bash
# 构建 Antigravity Account Switcher.app (SwiftUI + Popover 现代化版本)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Antigravity Switcher"
APP_DIR="build/${APP_NAME}.app"
BINARY="AntigravitySwitcher"

mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

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
    <string>1.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleExecutable</key>
    <string>AntigravitySwitcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Antigravity multi-account switcher with SwiftUI Popover</string>
</dict>
</plist>
PLIST

echo "[1/4] 编译 SwiftUI + AppKit 源码..."
swiftc -swift-version 5 -O \
    Sources/AntigravitySwitcher/Models.swift \
    Sources/AntigravitySwitcher/AuthManager.swift \
    Sources/AntigravitySwitcher/QuotaClient.swift \
    Sources/AntigravitySwitcher/AppState.swift \
    Sources/AntigravitySwitcher/Views/Components.swift \
    Sources/AntigravitySwitcher/Views/AccountCardView.swift \
    Sources/AntigravitySwitcher/Views/MainPageView.swift \
    Sources/AntigravitySwitcher/Views/ManageAccountsView.swift \
    Sources/AntigravitySwitcher/Views/SettingsView.swift \
    Sources/AntigravitySwitcher/Views/PopoverRootView.swift \
    Sources/AntigravitySwitcher/main.swift \
    -o "${APP_DIR}/Contents/MacOS/${BINARY}" \
    -framework AppKit -framework SwiftUI -framework UserNotifications -framework ServiceManagement -framework Combine

echo "[2/4] 安装高品质反重力 App 图标..."
if [ -f Sources/Resources/AppIcon.icns ]; then
    cp Sources/Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
elif [ -f AppIcon.icns ]; then
    cp AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

echo "[3/4] 签名 (ad-hoc)..."
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true

echo "[4/4] 安装到 /Applications..."
# 如果系统中正在运行旧的 Antigravity Switcher，安全终止以便覆盖升级
killall AntigravitySwitcher 2>/dev/null || pkill -9 -f AntigravitySwitcher 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/${APP_NAME}.app" 2>/dev/null || true
cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"

echo "=================================================="
echo "✅ 构建与安装完成！"
echo "本地产物: $(pwd)/${APP_DIR}"
echo "系统安装: /Applications/${APP_NAME}.app"
echo "正在启动新版本..."
open "/Applications/${APP_NAME}.app"
