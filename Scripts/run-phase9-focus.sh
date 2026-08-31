#!/bin/bash
#
# MacSSH Phase 9 P1 整改聚焦验证脚本（私钥路径，不触碰 Keychain 密码）
#
# 用途：
#   - 重建测试私钥（无 Passphrase ed25519，公钥以标记块加入 authorized_keys）
#   - 重建 Phase 9 SFTP 夹具（唯一目录 + 交接文件）
#   - 运行聚焦测试套件：SFTPSessionTests（含 P1 竞态测试 N / O / P，各连续 10 次）
#     / SFTPServiceTests（含第二轮整改确定性竞态测试 M，连续 5 次）
#     / RemotePathTests / SessionManagerTests.testAB（P2：连接中提前切 Files
#     后认证成功补创建 SFTP 运行时）
#
# 前置：
#   1. 系统设置 → 通用 → 共享 → 远程登录 已开启（本机 sshd）
#   2. 已执行过 build-for-testing（本脚本默认构建；-n 跳过构建复用现有产物）
#
# 退出时自动清理：标记块、测试密钥、夹具与交接文件。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_BUILD=0
if [[ "${1:-}" == "-n" ]]; then
    SKIP_BUILD=1
fi

TEST_LOG="/tmp/macssh-phase9-focus-tests.log"
TEST_BUILD_LOG="/tmp/macssh-phase9-focus-build.log"

PHASE6_KEY_NOPASS="/tmp/macssh_phase6_ed25519"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
AK_BEGIN="# macssh-phase9-focus-begin"
AK_END="# macssh-phase9-focus-end"

PHASE9_FIXTURE_PATH_FILE="/tmp/macssh_phase9_fixture_path"
PHASE9_FIXTURE_ROOT="/tmp/macssh-phase9-$(uuidgen | tr '[:upper:]' '[:lower:]')"

cleanup_keys() {
    if [[ -f "$AUTHORIZED_KEYS" ]]; then
        sed -i '' "/$AK_BEGIN/,/$AK_END/d" "$AUTHORIZED_KEYS" 2>/dev/null || true
    fi
    rm -f "$PHASE6_KEY_NOPASS" "$PHASE6_KEY_NOPASS.pub" 2>/dev/null || true
}

cleanup_fixture() {
    if [[ -d "$PHASE9_FIXTURE_ROOT" ]]; then
        chmod -R u+rwx "$PHASE9_FIXTURE_ROOT" 2>/dev/null || true
        rm -rf "$PHASE9_FIXTURE_ROOT"
    fi
    rm -f "$PHASE9_FIXTURE_PATH_FILE" 2>/dev/null || true
}

cleanup_all() {
    # P2 整改：保留脚本最终退出码——绝不把测试失败掩盖成 0。
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
if [[ -f "$PHASE9_FIXTURE_PATH_FILE" ]]; then
    STALE_FIXTURE="$(cat "$PHASE9_FIXTURE_PATH_FILE" 2>/dev/null || true)"
    if [[ -n "$STALE_FIXTURE" && "$STALE_FIXTURE" == /tmp/macssh-phase9-* && -d "$STALE_FIXTURE" ]]; then
        chmod -R u+rwx "$STALE_FIXTURE" 2>/dev/null || true
        rm -rf "$STALE_FIXTURE"
    fi
    rm -f "$PHASE9_FIXTURE_PATH_FILE"
fi

echo "==> 生成测试私钥并授权"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$PHASE6_KEY_NOPASS" -N "" -C "macssh-phase9-focus" -q
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
{
    echo "$AK_BEGIN"
    cat "$PHASE6_KEY_NOPASS.pub"
    echo "$AK_END"
} >> "$AUTHORIZED_KEYS"

echo "==> 创建 Phase 9 SFTP 夹具：$PHASE9_FIXTURE_ROOT"
mkdir -p "$PHASE9_FIXTURE_ROOT/dir-a" \
         "$PHASE9_FIXTURE_ROOT/dir-b" \
         "$PHASE9_FIXTURE_ROOT/empty" \
         "$PHASE9_FIXTURE_ROOT/restricted" \
         "$PHASE9_FIXTURE_ROOT/big"
printf 'phase9-fixture-content' > "$PHASE9_FIXTURE_ROOT/file.txt"
printf 'zhongwen' > "$PHASE9_FIXTURE_ROOT/中文.txt"
printf 'emoji' > "$PHASE9_FIXTURE_ROOT/emoji-😀.txt"
printf 'space' > "$PHASE9_FIXTURE_ROOT/hello world.txt"
printf 'hidden' > "$PHASE9_FIXTURE_ROOT/.hidden"
printf 'nested' > "$PHASE9_FIXTURE_ROOT/dir-a/nested.txt"
ln -s file.txt "$PHASE9_FIXTURE_ROOT/symlink"
PHASE9_LONG_NAME="$(printf 'n%.0s' $(seq 1 200)).txt"
printf 'long' > "$PHASE9_FIXTURE_ROOT/$PHASE9_LONG_NAME"
chmod 000 "$PHASE9_FIXTURE_ROOT/restricted"
seq -f "$PHASE9_FIXTURE_ROOT/big/f-%04g.txt" 1 1000 | xargs touch
printf '%s' "$PHASE9_FIXTURE_ROOT" > "$PHASE9_FIXTURE_PATH_FILE"

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

echo "==> 运行聚焦测试（SFTPSessionTests / SFTPServiceTests / RemotePathTests / SessionManagerTests.testAB）"
status=0
xcodebuild test-without-building \
    -project MacSSH.xcodeproj \
    -scheme MacSSH \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/macssh-dd \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -only-testing:MacSSHTests/SFTPSessionTests \
    -only-testing:MacSSHTests/SFTPServiceTests \
    -only-testing:MacSSHTests/RemotePathTests \
    -only-testing:MacSSHTests/SessionManagerTests/testAB_FilesPaneSelectedDuringConnectGetsSFTPServiceAfterAuth \
    > "$TEST_LOG" 2>&1 || status=$?

echo ""
echo "==> 用例结果汇总"
grep -E "Test Case '.*' (passed|failed)" "$TEST_LOG" | sed -E "s/^Test Case '-\[MacSSHTests\.([^ ]+) ([^]]+)\]' (passed|failed).*/\3  \1.\2/" | sort | uniq -c | sort -rn | head -5
grep -E "Test Case '.*' (passed|failed)" "$TEST_LOG" | sed -E "s/^Test Case '-\[MacSSHTests\.[^ ]+ ([^]]+)\]' (passed|failed).*/\2 \1/" | sort
if grep -qE "Test Case '.*' failed" "$TEST_LOG"; then
    status=1
fi

echo ""
if [[ "$status" == 0 ]]; then
    echo "==> 聚焦测试全部通过 ✓（日志：${TEST_LOG}）"
else
    echo "==> 聚焦测试存在失败 ✗（日志：${TEST_LOG}）"
fi
exit "$status"
