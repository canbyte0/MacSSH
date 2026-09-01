#!/bin/bash
#
# MacSSH Phase 11 大文件可靠性脚本（私钥路径，不触碰 Keychain 密码）
#
# 用途：
#   - 重建测试私钥（无 Passphrase ed25519，公钥以标记块加入 authorized_keys）
#   - 重建传输夹具（唯一目录 + upload / readonly + 交接文件，
#     交接文件路径与 Phase 10 一致：/tmp/macssh_phase10_fixture_path）
#   - 运行 SFTPLargeFileTests（1 GB 上传/下载三方 SHA256、1 GB ×3 循环、
#     1 GB 双会话串行（全局并发 1）、10 GB 上传/下载 + 峰值 RSS 采样有界）
#
# 前置：
#   1. 系统设置 → 通用 → 共享 → 远程登录 已开启（本机 sshd）
#   2. 磁盘可用空间：10 GB 用例需要 ≥36 GB；不足时该用例自动 skip
#      （测试内磁盘预检，绝不把磁盘写满）
#
# 用法：
#   run-phase11-largefile.sh        # 构建并运行
#   run-phase11-largefile.sh -n     # 跳过构建复用现有产物
#
# 退出时自动清理：标记块、测试密钥、夹具、交接文件与大文件临时目录。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_BUILD=0
if [[ "${1:-}" == "-n" ]]; then
    SKIP_BUILD=1
fi

TEST_LOG="/tmp/macssh-phase11-largefile-tests.log"
TEST_BUILD_LOG="/tmp/macssh-phase11-largefile-build.log"

PHASE6_KEY_NOPASS="/tmp/macssh_phase6_ed25519"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AK_BEGIN="# macssh-phase11-largefile-begin"
AK_END="# macssh-phase11-largefile-end"

PHASE10_FIXTURE_PATH_FILE="/tmp/macssh_phase10_fixture_path"
PHASE11_FIXTURE_ROOT="/tmp/macssh-phase11-large-$(uuidgen | tr '[:upper:]' '[:lower:]')"

cleanup_keys() {
    if [[ -f "$AUTHORIZED_KEYS" ]]; then
        sed -i '' "/$AK_BEGIN/,/$AK_END/d" "$AUTHORIZED_KEYS" 2>/dev/null || true
    fi
    rm -f "$PHASE6_KEY_NOPASS" "$PHASE6_KEY_NOPASS.pub" 2>/dev/null || true
}

cleanup_fixture() {
    if [[ -d "$PHASE11_FIXTURE_ROOT" ]]; then
        chmod -R u+rwx "$PHASE11_FIXTURE_ROOT" 2>/dev/null || true
        rm -rf "$PHASE11_FIXTURE_ROOT"
    fi
    rm -f "$PHASE10_FIXTURE_PATH_FILE" 2>/dev/null || true
    rm -rf "$TMPDIR/macssh-p11-large-tests" 2>/dev/null || true
}

cleanup_all() {
    # 保留脚本最终退出码——绝不把测试失败掩盖成 0。
    local rc=$?
    trap - EXIT
    set +e
    cleanup_keys
    cleanup_fixture
    exit "$rc"
}
trap cleanup_all EXIT

if ! nc -z -w 2 127.0.0.1 22 2>/dev/null; then
    echo "错误：127.0.0.1:22 未开放（系统设置 → 通用 → 共享 → 远程登录）。" >&2
    exit 1
fi

# 清理可能由异常中断遗留的同名测试密钥与夹具。
cleanup_keys
if [[ -f "$PHASE10_FIXTURE_PATH_FILE" ]]; then
    STALE_FIXTURE="$(cat "$PHASE10_FIXTURE_PATH_FILE" 2>/dev/null || true)"
    if [[ -n "$STALE_FIXTURE" && -d "$STALE_FIXTURE" ]]; then
        chmod -R u+rwx "$STALE_FIXTURE" 2>/dev/null || true
        rm -rf "$STALE_FIXTURE"
    fi
    rm -f "$PHASE10_FIXTURE_PATH_FILE"
fi

echo "==> 磁盘可用空间（10 GB 用例需 ≥36 GB，不足自动 skip）"
df -g "$TMPDIR" | tail -1 || true

echo "==> 生成测试私钥并授权"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$PHASE6_KEY_NOPASS" -N "" -C "macssh-phase11-largefile" -q
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
{
    echo "$AK_BEGIN"
    cat "$PHASE6_KEY_NOPASS.pub"
    echo "$AK_END"
} >> "$AUTHORIZED_KEYS"

echo "==> 创建 Phase 11 传输夹具：$PHASE11_FIXTURE_ROOT"
mkdir -p "$PHASE11_FIXTURE_ROOT/upload" \
         "$PHASE11_FIXTURE_ROOT/readonly"
printf 'phase11-fixture' > "$PHASE11_FIXTURE_ROOT/readme.txt"
chmod 555 "$PHASE11_FIXTURE_ROOT/readonly"
printf '%s' "$PHASE11_FIXTURE_ROOT" > "$PHASE10_FIXTURE_PATH_FILE"

if [[ "$SKIP_BUILD" == 0 ]]; then
    echo "==> 构建测试产物"
    xcodebuild build-for-testing \
        -project MacSSH.xcodeproj \
        -scheme MacSSH \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath /tmp/macssh-dd \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        > "$TEST_BUILD_LOG" 2>&1 || { echo "构建失败，日志：$TEST_BUILD_LOG" >&2; exit 1; }
    if ! grep -q "TEST BUILD SUCCEEDED" "$TEST_BUILD_LOG"; then
        echo "构建未成功，日志：$TEST_BUILD_LOG" >&2
        exit 1
    fi
fi

echo "==> 运行大文件测试（SFTPLargeFileTests）"
status=0
xcodebuild test-without-building \
    -project MacSSH.xcodeproj \
    -scheme MacSSH \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/macssh-dd \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -only-testing:MacSSHTests/SFTPLargeFileTests \
    > "$TEST_LOG" 2>&1 || status=$?

echo ""
echo "==> 用例结果汇总"
grep -E "Test Case '.*' (passed|failed|skipped)" "$TEST_LOG" \
    | sed -E "s/^Test Case '-\[MacSSHTests\.[^ ]+ ([^]]+)\]' (passed|failed|skipped).*/\2  \1/" | sort
if grep -qE "Test Case '.*' failed" "$TEST_LOG"; then
    status=1
fi

echo ""
if [[ "$status" == 0 ]]; then
    echo "==> 大文件测试全部通过 ✓（日志：${TEST_LOG}）"
else
    echo "==> 大文件测试存在失败 ✗（日志：${TEST_LOG}）"
fi
exit "$status"
