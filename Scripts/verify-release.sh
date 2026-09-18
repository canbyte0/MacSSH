#!/bin/bash
#
# MacSSH Release Verification (Phase 12A / 12B)
#
# 双模式校验（自动探测，可用第 2 参数覆盖）：
#   developer-id : 完整校验（codesign strict / Developer ID authority /
#                secure timestamp / Hardened Runtime runtime flag /
#                empty entitlement allowlist / app-sandbox absent /
#                get-task-allow absent / system-only runtime linkage /
#                minimum macOS / stapler / enforced spctl
#                Notarized Developer ID）—— Phase 12B。
#   ad-hoc       : 本地/内部测试校验（architecture / bundle id / version /
#                empty entitlement allowlist / app-sandbox absent /
#                get-task-allow absent / Hardened Runtime runtime flag /
#                system-only runtime linkage / dependency identity / app launch /
#                DMG mount）—— Phase 12A。**不**要求 Developer ID Authority /
#                secure timestamp / notary Accepted / stapler / Gatekeeper
#                Notarized（无 Apple Developer Program 时这些永失败）。
#
# 不执行 xattr -d。不修改系统 Gatekeeper。
#
# 用法：bash Scripts/verify-release.sh <MacSSH.app|MacSSH-*.dmg> [developer-id|ad-hoc]
# 退出码：0 = 全部 PASS；非 0 = 存在失败项（计划书八十六：不吞失败）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-}"
MODE_ARG="${2:-}"
if [ -z "$TARGET" ]; then
    echo "ERROR: 用法: bash Scripts/verify-release.sh <MacSSH.app|MacSSH-*.dmg> [developer-id|ad-hoc]" >&2
    exit 2
fi
TARGET_ABS="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

PASS=0
FAIL=0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS: $name"; PASS=$((PASS+1))
    else
        echo "FAIL: $name" >&2; FAIL=$((FAIL+1))
    fi
}

# 解析 .app：若是 DMG，挂载取内嵌 .app。
APP="$TARGET_ABS"
MOUNT=""
if [[ "$TARGET_ABS" == *.dmg ]]; then
    echo "==> Mounting DMG to inspect embedded app"
    MOUNT="$(hdiutil attach "$TARGET_ABS" -nobrowse -noautoopen -mountpoint /tmp/macssh-verify-$$ 2>/dev/null | grep -o '/Volumes/.*' | tail -1 | xargs -I{} echo {} || echo /tmp/macssh-verify-$$)"
    # 上面 grep 可能拿不到，回退用 mountpoint 输出。
    MOUNT="$(hdiutil info | grep -A2 "/tmp/macssh-verify-\$$" | grep '/Volumes\|/tmp/macssh-verify' | tail -1 | sed 's/^[[:space:]]*//' || true)"
    APP="$MOUNT/MacSSH.app"
fi

if [ ! -d "$APP" ]; then
    # 回退：直接在标准挂载点查找。
    for v in /Volumes/MacSSH /tmp/macssh-verify-*; do
        if [ -d "$v/MacSSH.app" ]; then APP="$v/MacSSH.app"; MOUNT="$v"; break; fi
    done
fi
if [ ! -d "$APP" ]; then
    echo "ERROR: 未找到 .app（DMG 挂载失败？）: $APP" >&2
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    exit 2
fi

BIN="$APP/Contents/MacOS/MacSSH"
INFO="$APP/Contents/Info.plist"

# ── 模式探测 ─────────────────────────────────────────────────
if [ -n "$MODE_ARG" ]; then
    MODE="$MODE_ARG"
else
    # 先完整捕获输出，避免在 pipefail 下由 grep -q 提前结束管道造成假阴性。
    AUTO_IDENTITY_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
    if [[ "$AUTO_IDENTITY_INFO" == *"Authority=Developer ID Application"* ]]; then
        MODE="developer-id"
    else
        MODE="ad-hoc"
    fi
fi
case "$MODE" in
    developer-id|ad-hoc) ;;
    *)
        echo "ERROR: 无效验证模式 '$MODE'（仅允许 developer-id|ad-hoc）。" >&2
        exit 2
        ;;
esac
if [ ! -x "$BIN" ] || [ ! -f "$INFO" ]; then
    echo "ERROR: App 缺少可执行文件或 Info.plist: $APP" >&2
    exit 2
fi
echo "==> Verification mode: $MODE  ($APP)"
echo ""

echo "=== 1. codesign strict verify ==="
if CODESIGN_STRICT_OUTPUT="$(codesign --verify --strict --verbose=4 "$APP" 2>&1)"; then
    printf '%s\n' "$CODESIGN_STRICT_OUTPUT" | tail -2
    echo "PASS: codesign --verify --strict"; PASS=$((PASS+1))
else
    printf '%s\n' "$CODESIGN_STRICT_OUTPUT" | tail -2 >&2
    echo "FAIL: codesign --verify --strict" >&2; FAIL=$((FAIL+1))
fi

echo "=== 2. Signing identity ==="
IDENTITY_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
printf '%s\n' "$IDENTITY_INFO" | grep -E "Signature=|Authority=|TeamIdentifier=" | head -4 || true

if [ "$MODE" = "developer-id" ]; then
    if [[ "$IDENTITY_INFO" == *"Authority=Developer ID Application"* ]]; then
        echo "PASS: Authority=Developer ID Application"; PASS=$((PASS+1))
    else
        echo "FAIL: Authority=Developer ID Application" >&2; FAIL=$((FAIL+1))
    fi
    echo "=== 3. Secure timestamp (developer-id only) ==="
    DEVELOPER_CODESIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
    if [[ "$DEVELOPER_CODESIGN_INFO" == *$'\nTimestamp='* || "$DEVELOPER_CODESIGN_INFO" == Timestamp=* ]]; then
        echo "PASS: secure Timestamp present"; PASS=$((PASS+1))
        printf '%s\n' "$DEVELOPER_CODESIGN_INFO" | grep "^Timestamp=" | head -1 || true
    else
        echo "FAIL: secure Timestamp absent" >&2; FAIL=$((FAIL+1))
    fi
    echo "=== 4. stapler validate (developer-id only) ==="
    if [[ "$TARGET_ABS" == *.dmg ]]; then
        if xcrun stapler validate "$TARGET_ABS"; then
            echo "PASS: stapler validate DMG"; PASS=$((PASS+1))
        else
            echo "FAIL: stapler validate DMG" >&2; FAIL=$((FAIL+1))
        fi
    fi
    echo "=== 5. Gatekeeper assessment (developer-id: expect Notarized Developer ID) ==="
    # LC_ALL=C 固定 source/origin 诊断语言；退出码与分类分别构成硬门禁。
    if GATEKEEPER_OUTPUT="$(LC_ALL=C spctl -vvv --assess --type exec "$APP" 2>&1)"; then
        GATEKEEPER_STATUS=0
    else
        GATEKEEPER_STATUS=$?
    fi
    printf '%s\n' "$GATEKEEPER_OUTPUT"
    if [ "$GATEKEEPER_STATUS" -eq 0 ]; then
        echo "PASS: Gatekeeper spctl assessment exit=0"; PASS=$((PASS+1))
    else
        echo "FAIL: Gatekeeper spctl assessment exit=$GATEKEEPER_STATUS" >&2; FAIL=$((FAIL+1))
    fi
    if [[ "$GATEKEEPER_OUTPUT" == *"source=Notarized Developer ID"* ]] &&
       [[ "$GATEKEEPER_OUTPUT" == *"origin=Developer ID Application:"* ]]; then
        echo "PASS: Gatekeeper source=Notarized Developer ID with Developer ID Application origin"; PASS=$((PASS+1))
    else
        echo "FAIL: Gatekeeper requires source=Notarized Developer ID and Developer ID Application origin" >&2
        FAIL=$((FAIL+1))
    fi
else
    echo "=== 2-5. (skipped in ad-hoc mode: no Developer ID / notary / stapler / Gatekeeper Notarized) ==="
    echo "This build is ad-hoc signed and not notarized."
    echo "macOS Gatekeeper may warn or block it when obtained through quarantine-enabled distribution channels."
fi

echo "=== 6. Hardened Runtime runtime flag ==="
# codesign -dvv 输出形如：CodeDirectory v=20500 ... flags=0x10002(adhoc,runtime) ...
# 注意：在 set -o pipefail 下，`codesign ... | grep -q` 会因 grep -q 提前关闭管道
# 触发 SIGPIPE 让 codesign 非零退出，使整个管道失败（假阴性）。
# 因此先捕获到变量再 grep，避免 pipefail 干扰。
CODESIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$CODESIGN_INFO" == *"flags="*"runtime"* ]]; then
    echo "PASS: Hardened Runtime (runtime flag)"; PASS=$((PASS+1))
    printf '%s\n' "$CODESIGN_INFO" | grep "CodeDirectory" | head -1 || true
else
    echo "FAIL: Hardened Runtime runtime flag absent" >&2; FAIL=$((FAIL+1))
fi

echo "=== 7. Effective entitlements (exact empty allowlist) ==="
# codesign 负责提取，plutil 验证 plist，xmllint 以 XPath 检查顶层字典键。
# 不能只用字符串 grep：必须区分空字典、已知禁止键和任意未知键。
ENTITLEMENTS_XML=""
ENTITLEMENTS_VALID=NO
if ENTITLEMENTS_XML="$(codesign --display --entitlements - --xml "$APP" 2>/dev/null)" &&
   plutil -lint - <<< "$ENTITLEMENTS_XML" >/dev/null 2>&1; then
    ENTITLEMENTS_ROOT="$(xmllint --xpath 'name(/plist/*[1])' - <<< "$ENTITLEMENTS_XML" 2>/dev/null || true)"
    if [ "$ENTITLEMENTS_ROOT" = "dict" ]; then
        ENTITLEMENTS_VALID=YES
    fi
fi

if [ "$ENTITLEMENTS_VALID" = "YES" ]; then
    echo "PASS: effective entitlements parsed as plist dictionary"; PASS=$((PASS+1))
else
    echo "FAIL: effective entitlements could not be parsed as plist dictionary" >&2; FAIL=$((FAIL+1))
fi

if [ "$ENTITLEMENTS_VALID" = "YES" ]; then
    SANDBOX_PRESENT="$(xmllint --xpath "boolean(/plist/dict/key[text()='com.apple.security.app-sandbox'])" - <<< "$ENTITLEMENTS_XML")"
    if [ "$SANDBOX_PRESENT" = "false" ]; then
        echo "PASS: com.apple.security.app-sandbox absent"; PASS=$((PASS+1))
    else
        echo "FAIL: com.apple.security.app-sandbox must be absent" >&2; FAIL=$((FAIL+1))
    fi

    GET_TASK_ALLOW_PRESENT="$(xmllint --xpath "boolean(/plist/dict/key[text()='com.apple.security.get-task-allow'])" - <<< "$ENTITLEMENTS_XML")"
    if [ "$GET_TASK_ALLOW_PRESENT" = "false" ]; then
        echo "PASS: get-task-allow absent"; PASS=$((PASS+1))
    else
        echo "FAIL: get-task-allow present" >&2; FAIL=$((FAIL+1))
    fi

    ENTITLEMENT_KEY_COUNT="$(xmllint --xpath 'count(/plist/dict/key)' - <<< "$ENTITLEMENTS_XML")"
    if [ "$ENTITLEMENT_KEY_COUNT" = "0" ]; then
        echo "PASS: effective entitlement key count=0 (exact empty allowlist)"; PASS=$((PASS+1))
    else
        UNEXPECTED_ENTITLEMENT_KEYS="$(xmllint --xpath '/plist/dict/key/text()' - <<< "$ENTITLEMENTS_XML" 2>/dev/null || true)"
        echo "FAIL: effective entitlement key count=$ENTITLEMENT_KEY_COUNT (expected 0)" >&2
        echo "Unexpected entitlement keys: ${UNEXPECTED_ENTITLEMENT_KEYS:-unavailable}" >&2
        FAIL=$((FAIL+1))
    fi
else
    echo "FAIL: com.apple.security.app-sandbox absence not verifiable" >&2; FAIL=$((FAIL+1))
    echo "FAIL: get-task-allow absence not verifiable" >&2; FAIL=$((FAIL+1))
    echo "FAIL: exact empty entitlement allowlist not verifiable" >&2; FAIL=$((FAIL+1))
fi

echo "=== 8. Runtime linkage (system-path allowlist) ==="
LINKAGE_OK=YES
if OTOOL_OUTPUT="$(otool -L "$BIN" 2>&1)"; then
    # 只丢弃首行可执行文件标题，并去除版本注释，保留完整依赖路径字段。
    DEPENDENCY_PATHS="$(printf '%s\n' "$OTOOL_OUTPUT" | sed -E '1d; s/^[[:space:]]*//; s/[[:space:]]+\(compatibility version.*$//; /^[[:space:]]*$/d')"
    if [ -z "$DEPENDENCY_PATHS" ]; then
        echo "FAIL: otool produced no dependency paths" >&2
        LINKAGE_OK=NO
    else
        while IFS= read -r DEPENDENCY_PATH; do
            case "$DEPENDENCY_PATH" in
                /System/Library/*|/usr/lib/*) ;;
                *)
                    echo "Unexpected dependency path: $DEPENDENCY_PATH" >&2
                    LINKAGE_OK=NO
                    ;;
            esac
        done <<< "$DEPENDENCY_PATHS"
    fi
else
    echo "FAIL: otool -L could not inspect $BIN" >&2
    LINKAGE_OK=NO
fi
if [ "$LINKAGE_OK" = "YES" ]; then
    echo "PASS: every runtime dependency uses /System/Library/ or /usr/lib/"; PASS=$((PASS+1))
else
    echo "FAIL: runtime linkage contains non-system or unparseable dependency paths" >&2; FAIL=$((FAIL+1))
fi

echo "=== 9. Architecture (arm64) ==="
FILE_INFO="$(file "$BIN")"
echo "$FILE_INFO"
if [[ "$FILE_INFO" == *"arm64"* ]]; then
    echo "PASS: arm64"; PASS=$((PASS+1))
else
    echo "FAIL: 非 arm64" >&2; FAIL=$((FAIL+1))
fi

echo "=== 10. Bundle version ==="
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO")"
BLD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO")"
BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INFO")"
NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$INFO")"
MIN="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$INFO" 2>/dev/null || echo unknown)"
echo "version=$VER build=$BLD id=$BID name=$NAME min=$MIN"
check "CFBundleShortVersionString=1.1.0" test "$VER" = "1.1.0"
check "CFBundleVersion=2" test "$BLD" = "2"
check "CFBundleIdentifier=com.macssh.MacSSH" test "$BID" = "com.macssh.MacSSH"
check "CFBundleDisplayName=MacSSH" test "$NAME" = "MacSSH"
check "LSMinimumSystemVersion=14.0" test "$MIN" = "14.0"

echo "=== 11. App launch (smoke: process starts) ==="
# 启动 .app，等 5 秒确认进程存活，然后退出（不做 UI 交互）。
"$BIN" >/tmp/macssh-launch.log 2>&1 &
LAUNCH_PID=$!
sleep 5
if kill -0 "$LAUNCH_PID" 2>/dev/null; then
    echo "PASS: app launched (pid $LAUNCH_PID alive after 5s)"; PASS=$((PASS+1))
    kill "$LAUNCH_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$LAUNCH_PID" 2>/dev/null || true
else
    echo "FAIL: app did not stay running 5s" >&2; FAIL=$((FAIL+1))
fi

echo "=== 12. DMG mount & contents ==="
if [[ "$TARGET_ABS" == *.dmg ]]; then
    if [ -d "$APP" ] && [ -L "$MOUNT/Applications" ]; then
        echo "PASS: DMG contains MacSSH.app + Applications symlink"; PASS=$((PASS+1))
        ls -la "$MOUNT" | grep -E "MacSSH.app|Applications ->" | head -3
    else
        echo "FAIL: DMG 缺少 MacSSH.app 或 Applications 符号链接" >&2; FAIL=$((FAIL+1))
    fi
else
    echo "INFO: 目标为 .app（非 DMG），跳过 DMG 内容校验"
fi

echo "=== 13. App size ==="
echo "size: $(du -sh "$APP" | cut -f1)"

[ -n "$MOUNT" ] && [[ "$MOUNT" == /tmp/* || "$MOUNT" == /Volumes/* ]] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true

echo ""
echo "==============================="
echo "PASS: $PASS   FAIL: $FAIL   (mode: $MODE)"
echo "==============================="
if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAIL ($FAIL 项未通过)" >&2
    exit 1
fi
echo "RESULT: ALL PASS (mode: $MODE)"
