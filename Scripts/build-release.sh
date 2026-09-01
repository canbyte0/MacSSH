#!/bin/bash
#
# MacSSH Release Archive & Developer ID Export (Phase 12)
#
# 职责：clean → xcodebuild archive → export Developer ID signed .app
#       （Hardened Runtime + secure timestamp + 无 get-task-allow）。
#
# 凭据：不保存任何证书私钥 / 密码。仅引用本机 Keychain 中已存在的
#       Developer ID Application 证书；Team ID 经环境变量传入。
#
# 前置（人工一次性配置）：
#   1) Keychain 已含 "Developer ID Application: <name> (<TEAM_ID>)" 证书+私钥
#      （security find-identity -v -p codesigning 可见）
#   2) export MACSSH_DEVELOPMENT_TEAM="<TEAM_ID>"
#
# 用法：
#   MACSSH_DEVELOPMENT_TEAM=XXXXXX bash Scripts/build-release.sh
#
# 产物：dist/MacSSH.xcarchive、dist/export/MacSSH.app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── 凭据 / 证书前置检查（计划书 二十一 / 一百一十四：不伪造，缺失即停）───────
if [ -z "${MACSSH_DEVELOPMENT_TEAM:-}" ]; then
    echo "ERROR: MACSSH_DEVELOPMENT_TEAM 未设置。" >&2
    echo "请在 Keychain 确认存在 'Developer ID Application' 证书后，" >&2
    echo "执行：export MACSSH_DEVELOPMENT_TEAM=\"<TEAM_ID>\"" >&2
    echo "Team ID 见 Apple Developer > Membership，或：" >&2
    echo "  security find-identity -v -p codesigning | grep 'Developer ID Application'" >&2
    exit 2
fi

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "ERROR: Keychain 未找到 'Developer ID Application' 签名证书。" >&2
    echo "Phase 12 正式签名需要 Developer ID Application 证书（计划书 十九 / 二十一）。" >&2
    echo "请通过 Apple Developer Program 申请并安装该证书后重试。" >&2
    exit 2
fi

TEAM="$MACSSH_DEVELOPMENT_TEAM"
DIST="$ROOT/dist"
ARCHIVE="$DIST/MacSSH.xcarchive"
EXPORT_DIR="$DIST/export"

echo "==> Clean dist/"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> xcodebuild archive (Release arm64, Developer ID, Hardened Runtime)"
# -destination generic/platform=macOS 生成可分发 arm64 archive（非仅本机）。
xcodebuild archive \
    -project MacSSH.xcodeproj \
    -scheme MacSSH \
    -configuration Release \
    -destination 'generic/platform=macOS,arch=arm64' \
    -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    2>&1 | tee "$DIST/build-release-archive.log" | tail -3

if [ ! -d "$ARCHIVE" ]; then
    echo "ERROR: archive 未生成: $ARCHIVE" >&2
    exit 1
fi

echo ""
echo "==> Export Developer ID distribution .app"
# 注入 teamID 到导出选项（不写凭据，仅 Team ID 公开标识）。
EXPORT_OPTS_TMP="$DIST/ExportOptions.runtime.plist"
sed "s/<\/dict>/<key>teamID<\/key><string>${TEAM}<\/string><\/dict>/" \
    "$ROOT/Scripts/ExportOptions.plist" > "$EXPORT_OPTS_TMP"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTS_TMP" \
    -exportPath "$EXPORT_DIR" \
    2>&1 | tee "$DIST/build-release-export.log" | tail -3

APP="$EXPORT_DIR/MacSSH.app"
if [ ! -d "$APP" ]; then
    echo "ERROR: 导出 .app 未生成: $APP" >&2
    exit 1
fi

echo ""
echo "==> Archive/Export summary"
echo "archive: $ARCHIVE"
echo "app:     $APP"
file "$APP/Contents/MacOS/MacSSH"
echo "size:    $(du -sh "$APP" | cut -f1)"

# dSYM 保存（计划书 七十八）：从 archive 提取，不进 DMG。
DSYM_SOURCE="$ARCHIVE/dSYMs"
if [ -d "$DSYM_SOURCE" ]; then
    cp -R "$DSYM_SOURCE" "$DIST/dSYMs"
    echo "dSYM:   $DIST/dSYMs (saved for crash symbolication)"
fi

echo ""
echo "Done. Next: bash Scripts/package-dmg.sh \"$APP\""
