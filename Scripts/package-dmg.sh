#!/bin/bash
#
# MacSSH DMG Packaging (Phase 12A / 12B)
#
# 职责：staging（MacSSH.app + Applications 符号链接）→ hdiutil 生成 DMG
#       → 签名 DMG。
#
# 签名模式（自动探测，可用第 2 参数或 MACSSH_DMG_SIGN_MODE 覆盖）：
#   developer-id  : 若 Keychain 存在 'Developer ID Application' 证书，
#                   用其 + secure timestamp 签名（Phase 12B 正式分发）。
#   ad-hoc        : 无 Developer ID 证书时的一等模式（Phase 12A 本地/内部测试）。
#                   DMG 以 ad-hoc 签名，**不**视为降级或 preflight。
#
# 不保存任何证书私钥/密码。不执行 xattr -d（不掩盖 quarantine）。
#
# 用法：bash Scripts/package-dmg.sh <path-to-MacSSH.app> [developer-id|ad-hoc]
# 产物：dist/MacSSH-<version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:-}"
MODE_ARG="${2:-${MACSSH_DMG_SIGN_MODE:-}}"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "ERROR: 用法: bash Scripts/package-dmg.sh <path-to-MacSSH.app> [developer-id|ad-hoc]" >&2
    exit 2
fi

APP_ABS="$(cd "$APP" && pwd)"
APP_NAME="$(basename "$APP_ABS")"          # MacSSH.app
VERSION="$("/usr/libexec/PlistBuddy" -c "Print CFBundleShortVersionString" "$APP_ABS/Contents/Info.plist")"
VOLUME_NAME="MacSSH"
DMG_NAME="MacSSH-${VERSION}.dmg"
DIST="$ROOT/dist"
STAGING="$DIST/dmg-staging"
DMG_PATH="$DIST/$DMG_NAME"

# ── 签名模式探测 ─────────────────────────────────────────────
HAS_DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application" || true)"
if [ -n "$MODE_ARG" ]; then
    MODE="$MODE_ARG"
elif [ "$HAS_DEVID" -gt 0 ]; then
    MODE="developer-id"
else
    MODE="ad-hoc"
fi

echo "==> Prepare DMG staging (version $VERSION, sign mode: $MODE)"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# 拷贝 .app（保留签名与 ticket）。
cp -R "$APP_ABS" "$STAGING/$APP_NAME"
# Applications 快捷方式（用户拖拽安装）。
ln -s /Applications "$STAGING/Applications"

echo "==> hdiutil create UDBZ DMG"
# 先卸载可能残留的同名卷（不报错）。
hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDBZ \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG 未生成: $DMG_PATH" >&2
    exit 1
fi

echo "==> Sign DMG ($MODE)"
case "$MODE" in
    developer-id)
        if [ "$HAS_DEVID" -eq 0 ]; then
            echo "ERROR: 请求 developer-id 模式但未找到 Developer ID 证书。" >&2
            exit 2
        fi
        codesign --sign "Developer ID Application" --timestamp "$DMG_PATH"
        echo "Developer ID DMG signed (Phase 12B path)."
        ;;
    ad-hoc)
        # Phase 12A 一等模式：本地/内部测试分发。无 Apple Developer ID。
        codesign --sign - "$DMG_PATH"
        echo "Ad-hoc DMG signed (Phase 12A: local/internal testing; not notarized)."
        ;;
    *)
        echo "ERROR: 未知签名模式 '$MODE'（应为 developer-id|ad-hoc）" >&2
        exit 2
        ;;
esac

echo ""
echo "==> DMG summary"
echo "dmg:      $DMG_PATH"
echo "size:     $(du -sh "$DMG_PATH" | cut -f1)"
echo "volume:   $VOLUME_NAME"
hdiutil imageinfo "$DMG_PATH" | grep -E "^    Format:|Class Name:" | head -2
echo "signing:  $MODE"

# 清理临时 staging（DMG 已生成）。
rm -rf "$STAGING"

echo ""
if [ "$MODE" = "developer-id" ]; then
    echo "Done. Next: bash Scripts/notarize.sh \"$DMG_PATH\"  (Phase 12B)"
else
    echo "Done. Next: bash Scripts/verify-release.sh \"$DMG_PATH\"  (ad-hoc mode)"
fi
