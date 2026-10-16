#!/bin/bash
set -e

APP_NAME="LiteTab"
BUNDLE_ID="com.wenruifeng.LiteTab"
BUILD_DIR="./build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo "🔨 正在编译 ${APP_NAME}..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# 复制资源
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# 编译 Swift 源码
swiftc -O -o "${APP_DIR}/Contents/MacOS/${APP_NAME}" \
    main.swift \
    -framework Cocoa \
    -framework Carbon \
    -framework SwiftUI \
    -framework ServiceManagement

# 稳定 Designated Requirement 签名 (防止重建后 TCC 屏幕录制权限失效)
echo "🔏 正在执行 Designated Requirement 签名..."
codesign -f -s - --timestamp=none -r "=designated => identifier \"${BUNDLE_ID}\"" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
codesign -f -s - --timestamp=none -r "=designated => identifier \"${BUNDLE_ID}\"" "${APP_DIR}"

echo "✅ 构建完成: ${APP_DIR}"

if [ "$1" == "install" ]; then
    echo "📦 正在安装至 /Applications..."
    pkill -x "${APP_NAME}" || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_DIR}" /Applications/
    echo "🚀 启动 ${APP_NAME}..."
    open "/Applications/${APP_NAME}.app"
    echo "🎉 安装并启动成功！"
fi
