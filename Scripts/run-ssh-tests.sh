#!/bin/bash
#
# MacSSH Phase 5 / Phase 6 / Phase 7 / Phase 8 SSH 连接与会话真实测试脚本
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
#   - Phase 6：生成测试专用私钥（ed25519 无/有 Passphrase、未授权 ed25519、RSA、ECDSA）
#     并把需授权的公钥临时加入 ~/.ssh/authorized_keys（带标记块），脚本退出时移除
#     标记块并删除测试密钥；Passphrase 运行时随机生成，写入 600 权限临时文件由
#     testU 读取后立即删除（经真实 CredentialService→KeychainService 保存），
#     不写入 Git，不进入任何日志（testM 使用随机错误 Passphrase）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 固定 UUID 仅是测试 Keychain account，不含任何 Secret。
TEST_CREDENTIAL_ID="7d54a5bf-3032-4db2-9267-a643fe75c229"
TEST_CREDENTIAL_SERVICE="com.macssh.MacSSH.credentials.ssh-password"
TEST_APP_EXECUTABLE="/tmp/macssh-dd/Build/Products/Debug/MacSSH.app/Contents/MacOS/MacSSH"
TEST_BUILD_LOG="/tmp/macssh-ssh-test-build.log"
TEST_LOG="/tmp/macssh-ssh-tests.log"

# Phase 6 测试私钥（运行时生成，退出删除）。
PHASE6_KEY_NOPASS="/tmp/macssh_phase6_ed25519"
PHASE6_KEY_PASS="/tmp/macssh_phase6_ed25519_pass"
# 带 Passphrase 私钥的随机 Passphrase（600 权限临时文件；测试读取后即删，不进任何日志）。
PHASE6_PASSPHRASE_FILE="/tmp/macssh_phase6_ed25519_pass.secret"
# Phase 7 Remote Terminal 带 Passphrase 用例（RemoteTerminalTests.testT）的独立副本：
# SSHConnectionTests.testU 读取原始 .secret 后会立即删除该文件，副本保证两个测试互不影响。
PHASE6_PASSPHRASE_FILE_P7="/tmp/macssh_phase6_ed25519_pass.secret.p7"
# 未加入 authorized_keys 的私钥（testT：错误 Private Key）。
PHASE6_KEY_UNAUTHORIZED="/tmp/macssh_phase6_ed25519_unauthorized"
# RSA / ECDSA 测试私钥（testV / testW：真实 Key Type 验证）。
PHASE6_KEY_RSA="/tmp/macssh_phase6_rsa"
PHASE6_KEY_ECDSA="/tmp/macssh_phase6_ecdsa"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AK_BEGIN="# macssh-phase6-test-begin"
AK_END="# macssh-phase6-test-end"

cleanup_test_credential() {
    security delete-generic-password \
        -a "$TEST_CREDENTIAL_ID" \
        -s "$TEST_CREDENTIAL_SERVICE" \
        >/dev/null 2>&1 || true
}

cleanup_phase6_keys() {
    # 移除 authorized_keys 中本脚本写入的标记块（仅删除块内行，不影响其他条目）。
    if [[ -f "$AUTHORIZED_KEYS" ]]; then
        sed -i '' "/$AK_BEGIN/,/$AK_END/d" "$AUTHORIZED_KEYS" 2>/dev/null || true
    fi
    rm -f "$PHASE6_KEY_NOPASS" "$PHASE6_KEY_NOPASS.pub" \
          "$PHASE6_KEY_PASS" "$PHASE6_KEY_PASS.pub" \
          "$PHASE6_PASSPHRASE_FILE" \
          "$PHASE6_PASSPHRASE_FILE_P7" \
          "$PHASE6_KEY_UNAUTHORIZED" "$PHASE6_KEY_UNAUTHORIZED.pub" \
          "$PHASE6_KEY_RSA" "$PHASE6_KEY_RSA.pub" \
          "$PHASE6_KEY_ECDSA" "$PHASE6_KEY_ECDSA.pub" \
          2>/dev/null || true
}

cleanup_all() {
    cleanup_test_credential
    cleanup_phase6_keys
}
trap cleanup_all EXIT

echo "==> MacSSH Phase 5 / Phase 6 / Phase 7 / Phase 8 SSH connection & session tests"
echo ""

# 检查本机 sshd
if ! nc -z -w 2 127.0.0.1 22 2>/dev/null; then
    echo "错误：127.0.0.1:22 未开放。" >&2
    echo "请在 系统设置 → 通用 → 共享 → 远程登录 中开启后重试。" >&2
    exit 1
fi
echo "本机 sshd (127.0.0.1:22) 可达 ✓"
echo ""

# 清理可能由异常中断遗留的同名测试 item / 测试密钥。
cleanup_test_credential
cleanup_phase6_keys

echo "==> 生成 Phase 6 测试专用私钥（ed25519 无/有 Passphrase、未授权 ed25519、RSA、ECDSA）"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
# 无 Passphrase 密钥：testL / testN / testQ / 20 次循环 / 空闲 CPU 使用，公钥加入 authorized_keys。
ssh-keygen -t ed25519 -f "$PHASE6_KEY_NOPASS" -N "" -C "macssh-phase6-test-nopass" -q
# 有 Passphrase 密钥：testM（错误 Passphrase）与 testU（正确 Passphrase）使用。
# Passphrase 运行时随机生成；写入 600 权限临时文件供 testU 读取（经真实
# CredentialService→KeychainService 保存），测试读取后立即删除，不进入任何日志。
PHASE6_PASSPHRASE="$(openssl rand -base64 18)"
ssh-keygen -t ed25519 -f "$PHASE6_KEY_PASS" -N "$PHASE6_PASSPHRASE" -C "macssh-phase6-test-pass" -q
printf '%s' "$PHASE6_PASSPHRASE" > "$PHASE6_PASSPHRASE_FILE"
chmod 600 "$PHASE6_PASSPHRASE_FILE"
printf '%s' "$PHASE6_PASSPHRASE" > "$PHASE6_PASSPHRASE_FILE_P7"
chmod 600 "$PHASE6_PASSPHRASE_FILE_P7"
unset PHASE6_PASSPHRASE
# 未授权密钥：testT 使用（正确格式但不在 authorized_keys），公钥不授权。
ssh-keygen -t ed25519 -f "$PHASE6_KEY_UNAUTHORIZED" -N "" -C "macssh-phase6-test-unauthorized" -q
# RSA / ECDSA 密钥：testV / testW 真实 Key Type 验证，公钥加入 authorized_keys。
ssh-keygen -t rsa -b 2048 -f "$PHASE6_KEY_RSA" -N "" -C "macssh-phase6-test-rsa" -q
ssh-keygen -t ecdsa -f "$PHASE6_KEY_ECDSA" -N "" -C "macssh-phase6-test-ecdsa" -q

# 把需要授权的测试公钥以标记块形式追加到 authorized_keys
# （无 Passphrase ed25519、有 Passphrase ed25519、RSA、ECDSA；未授权密钥不在其中）。
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
{
    echo "$AK_BEGIN"
    cat "$PHASE6_KEY_NOPASS.pub"
    cat "$PHASE6_KEY_PASS.pub"
    cat "$PHASE6_KEY_RSA.pub"
    cat "$PHASE6_KEY_ECDSA.pub"
    echo "$AK_END"
} >> "$AUTHORIZED_KEYS"
echo "Phase 6 测试公钥已临时加入 authorized_keys（退出时移除标记块；未授权测试密钥不加入）✓"
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

echo ""
echo "==> 创建临时测试凭据"
echo "请在接下来的 Keychain 安全提示中输入本机账户密码（输入不回显）："
security add-generic-password \
    -a "$TEST_CREDENTIAL_ID" \
    -s "$TEST_CREDENTIAL_SERVICE" \
    -l "MacSSH Phase 5/6 Temporary SSH Test Credential" \
    -T "$TEST_APP_EXECUTABLE" \
    -w

echo ""
echo "==> 运行 SSHConnectionTests（Phase 5 A-I + Phase 6 J-W + 持久化失败注入 + 20 次循环 + 空闲 CPU）"
echo "    同时运行 RemoteTerminalTests（Phase 7 Shell Channel/PTY/Resize/EOF/大输出/空闲 CPU/20 轮循环 + top/nano/htop 全屏 + 打开立即关闭 / close-reopen-disconnect / 双 disconnect EAGAIN 并发）"
echo "    以及 SessionManagerTests（Phase 8 多 Session 生命周期 / 同 Host 多会话独立 / close-while-connecting / double close + disconnect / reconnect 竞态）"
echo "    以及 KnownHostServiceTests / HostEditorValidationTests / CredentialServiceTests / DependencyIdentityTests"
xcodebuild test-without-building \
    -project MacSSH.xcodeproj \
    -scheme MacSSH \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/macssh-dd \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    2>&1 | tee "$TEST_LOG" | grep -E "Test Case|Test Suite|passed|failed|error:|Skip" | tail -80

cleanup_test_credential

echo ""
echo "==> 完成。测试专用 Keychain 凭据与 Phase 6 测试密钥已清理。"
echo "    构建日志：$TEST_BUILD_LOG"
echo "    测试日志：$TEST_LOG"
