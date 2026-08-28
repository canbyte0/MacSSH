#!/bin/bash
#
# MacSSH Phase 5 SSH 连接真实测试脚本
#
# 前置要求：
#   1. 系统设置 → 通用 → 共享 → 远程登录 已开启（本机 sshd 作为测试服务器）
#   2. 运行时在 macOS Keychain 的安全提示中输入本机账户密码
#
# 用法：
#   cd ~/msl_code/Ter && bash Scripts/run-ssh-tests.sh
#
# 产物日志：
#   /tmp/macssh-ssh-tests.log（XCTest 完整输出）
#
# 说明：
#   - 密码由 security 命令直接安全输入并写入测试专用 Keychain item，
#     不经过环境变量、命令行参数、源码或日志，脚本退出时自动清理。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 固定 UUID 仅是测试 Keychain account，不含任何 Secret。
TEST_CREDENTIAL_ID="7d54a5bf-3032-4db2-9267-a643fe75c229"
TEST_CREDENTIAL_SERVICE="com.macssh.MacSSH.credentials.ssh-password"
TEST_APP_EXECUTABLE="/tmp/macssh-dd/Build/Products/Debug/MacSSH.app/Contents/MacOS/MacSSH"
TEST_BUILD_LOG="/tmp/macssh-ssh-test-build.log"
TEST_LOG="/tmp/macssh-ssh-tests.log"

# 无论测试成功、失败或被中断，都尽力删除测试专用 Keychain item。
cleanup_test_credential() {
    security delete-generic-password \
        -a "$TEST_CREDENTIAL_ID" \
        -s "$TEST_CREDENTIAL_SERVICE" \
        >/dev/null 2>&1 || true
}
trap cleanup_test_credential EXIT

echo "==> MacSSH Phase 5 SSH connection tests"
echo ""

# 检查本机 sshd
if ! nc -z -w 2 127.0.0.1 22 2>/dev/null; then
    echo "错误：127.0.0.1:22 未开放。" >&2
    echo "请在 系统设置 → 通用 → 共享 → 远程登录 中开启后重试。" >&2
    exit 1
fi
echo "本机 sshd (127.0.0.1:22) 可达 ✓"
echo ""

echo "==> 构建测试产物"
xcodebuild build-for-testing \
    -project MacSSH.xcodeproj \
    -scheme MacSSH \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/macssh-dd \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    2>&1 | tee "$TEST_BUILD_LOG" | grep -E "BUILD|warning:|error:" | tail -60

if [[ ! -x "$TEST_APP_EXECUTABLE" ]]; then
    echo "错误：测试 Host App 不存在：$TEST_APP_EXECUTABLE" >&2
    exit 1
fi

# 清理可能由异常中断遗留的同名测试 item。
cleanup_test_credential

echo ""
echo "==> 创建临时测试凭据"
echo "请在接下来的 Keychain 安全提示中输入本机账户密码（输入不回显）："
security add-generic-password \
    -a "$TEST_CREDENTIAL_ID" \
    -s "$TEST_CREDENTIAL_SERVICE" \
    -l "MacSSH Phase 5 Temporary SSH Test Credential" \
    -T "$TEST_APP_EXECUTABLE" \
    -w

echo ""
echo "==> 运行 SSHConnectionTests（测试 A-I + 20 次循环 + 30 秒空闲 CPU，约 2-3 分钟）"
echo "    同时运行 CredentialServiceTests 作为 Phase 4 回归"
xcodebuild test-without-building \
    -project MacSSH.xcodeproj \
    -scheme MacSSH \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/macssh-dd \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    2>&1 | tee "$TEST_LOG" | grep -E "Test Case|Test Suite|passed|failed|error:|Skip" | tail -60

cleanup_test_credential

echo ""
echo "==> 完成。测试专用 Keychain 凭据已删除。"
echo "    构建日志：$TEST_BUILD_LOG"
echo "    测试日志：$TEST_LOG"
