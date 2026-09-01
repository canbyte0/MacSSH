#!/bin/bash
#
# MacSSH Notarization & Stapling (Phase 12)
#
# 职责：notarytool submit (--keychain-profile) --wait → 取日志 → stapler staple。
#
# 凭据：仅引用本机 Keychain profile 名 "MacSSH-notary"，不写 Apple ID 密码 /
#       app-specific password / API private key 内容（计划书 五十一 / 五十二）。
#
# 前置（人工一次性配置）：
#   xcrun notarytool store-credentials "MacSSH-notary"
#   （在 Terminal 中交互完成 Apple 认证，凭据只存本机 Keychain）
#
# 用法：bash Scripts/notarize.sh <path-to-MacSSH-<version>.dmg>

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DMG="${1:-}"
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
    echo "ERROR: 用法: bash Scripts/notarize.sh <path-to-MacSSH-<version>.dmg>" >&2
    exit 2
fi

PROFILE="MacSSH-notary"

# ── 凭据前置检查（计划书 五十三：不问密码，提示人工 store-credentials）───────
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "ERROR: Keychain profile \"$PROFILE\" 未配置。" >&2
    echo "请在 Terminal 中执行（不要在 Codex 内完成）：" >&2
    echo "  xcrun notarytool store-credentials \"$PROFILE\"" >&2
    echo "按提示输入 Apple ID / app-specific password / 2FA，凭据只存本机 Keychain。" >&2
    exit 2
fi

DMG_ABS="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
SUBMIT_LOG="$ROOT/dist/notary-submit.log"

echo "==> notarytool submit ($PROFILE, --wait)"
# 计划书 八十七：禁止 || true 吞失败。--wait 阻塞至终态。
SUBMIT_OUTPUT="$ROOT/dist/notary-submit-output.txt"
xcrun notarytool submit "$DMG_ABS" \
    --keychain-profile "$PROFILE" \
    --wait 2>&1 | tee "$SUBMIT_OUTPUT"

# 解析 submission id 与 status。
SUBMISSION_ID="$(grep -i 'id:' "$SUBMIT_OUTPUT" | head -1 | sed 's/.*id: *//I; s/ *$//' || true)"
STATUS="$(grep -i 'status:' "$SUBMIT_OUTPUT" | tail -1 | sed 's/.*status: *//I; s/ *$//' || true)"

echo ""
echo "Submission ID: ${SUBMISSION_ID:-unknown}"
echo "Status:        ${STATUS:-unknown}"

# 计划书 五十五：必须 Accepted，不能只 Uploaded。
if [ -z "$STATUS" ] || [ "$STATUS" != "Accepted" ]; then
    echo "ERROR: Notarization 未通过（status=${STATUS:-empty}）。" >&2
    echo "计划书 五十六：retrieve log → diagnose → fix → rebuild → resign → resubmit。" >&2
    if [ -n "$SUBMISSION_ID" ]; then
        echo "==> Retrieving notary log for diagnosis"
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" \
            > "$ROOT/dist/notary-log.json" 2>&1 || true
        echo "Log saved: dist/notary-log.json"
    fi
    exit 1
fi

# 计划书 五十七：即使 Accepted 也查日志警告。
if [ -n "$SUBMISSION_ID" ]; then
    echo "==> Retrieving notary log (check warnings)"
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" \
        > "$ROOT/dist/notary-log.json" 2>&1 || true
    WARN_COUNT="$(grep -ic 'severity.*warning\|".*warning' "$ROOT/dist/notary-log.json" 2>/dev/null || echo 0)"
    echo "Notary log warnings: $WARN_COUNT"
fi

echo "==> stapler staple"
xcrun stapler staple "$DMG_ABS"
if [ $? -ne 0 ]; then
    echo "ERROR: stapler staple 失败。" >&2
    exit 1
fi

echo "==> stapler validate"
xcrun stapler validate "$DMG_ABS"

echo ""
echo "Done. Next: bash Scripts/verify-release.sh \"$DMG_ABS\""
