#!/bin/bash
#
# MacSSH App 构建脚本（Phase 5）
#
# 用途：在系统 Terminal.app 中运行本脚本，完成 Debug/Release clean build。
# 背景：TRAE 沙箱会拦截 Xcode metal 工具链探测，无法在代理沙箱内完成
#       含 SwiftTerm（Metal Shader）的构建；需在正常 shell 中执行。
#
# 产物与日志写入 /tmp，供代理读取分析：
#   /tmp/macssh-build-debug.log    Debug 完整构建日志
#   /tmp/macssh-build-release.log  Release 完整构建日志
#   /tmp/macssh-dd                 Debug DerivedData
#   /tmp/macssh-dd-rel             Release DerivedData
#
# 前置：Scripts/build-dependencies.sh 已运行（ThirdParty 依赖已构建）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMMON_ARGS=(
    -project MacSSH.xcodeproj
    -scheme MacSSH
    -destination 'platform=macOS,arch=arm64'
    -skipPackagePluginValidation
    -skipMacroValidation
)

echo "==> MacSSH clean build (Debug arm64)"
rm -rf /tmp/macssh-dd
xcodebuild "${COMMON_ARGS[@]}" -configuration Debug \
    -derivedDataPath /tmp/macssh-dd build 2>&1 | tee /tmp/macssh-build-debug.log | tail -3

echo ""
echo "==> MacSSH clean build (Release arm64)"
rm -rf /tmp/macssh-dd-rel
xcodebuild "${COMMON_ARGS[@]}" -configuration Release \
    -derivedDataPath /tmp/macssh-dd-rel build 2>&1 | tee /tmp/macssh-build-release.log | tail -3

echo ""
echo "==> Build summary"
DEBUG_APP=/tmp/macssh-dd/Build/Products/Debug/MacSSH.app
RELEASE_APP=/tmp/macssh-dd-rel/Build/Products/Release/MacSSH.app

for APP in "$DEBUG_APP" "$RELEASE_APP"; do
    if [ -d "$APP" ]; then
        echo "OK: $APP"
        file "$APP/Contents/MacOS/MacSSH"
        codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -1
    else
        echo "MISSING: $APP"
        exit 1
    fi
done

echo ""
echo "==> Warning check (project code only)"
echo "Debug warnings:   $(grep -c 'warning:' /tmp/macssh-build-debug.log || true)"
echo "Release warnings: $(grep -c 'warning:' /tmp/macssh-build-release.log || true)"

echo ""
echo "Done. Logs: /tmp/macssh-build-debug.log /tmp/macssh-build-release.log"
