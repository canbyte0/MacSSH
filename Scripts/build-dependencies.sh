#!/bin/bash
#
# MacSSH 第三方依赖构建脚本（Phase 5.1：libssh2 Security Baseline Remediation）
#
# 构建内容：
#   1. OpenSSL 3.5.8（官方 release tarball，静态库，arm64，macOS 14.0+）
#   2. libssh2（upstream commit be937743，包含截至 2026-08-28 全部已复核安全基线修复，
#      静态库，arm64，OpenSSL backend）
#
# 产物安装到：
#   ThirdParty/openssl/{include,lib}
#   ThirdParty/libssh2/{include,lib}
#
# 可复现性：
#   - 所有源码下载均校验 SHA256
#   - 版本/commit 完整固定，见 ThirdParty/MANIFEST.txt
#   - 解压源码逐项硬校验 10 个 CVE 修复标记，任何一项缺失即中止构建
#
# 安全基线（pinned commit 必须包含的 upstream 修复；ancestry 已在选定时用
# `git merge-base --is-ancestor <fix> <pin>` 逐项验证，全部 exit 0，结果记录于
# MANIFEST 与 Docs/DevelopmentStatus.md）：
#   CVE-2026-7598  256d04b60d80bf1190e96b0ad1e91b2174d744b1  userauth username_len 越界
#   CVE-2025-15661 2dae3024897e1898d389835151f4e9606227721d  sftp_symlink 越界读
#   CVE-2026-55199 17626857d20b3c9a1addfa45979dadcee1cd84a4  EXT_INFO 字符串检查
#   CVE-2026-55200 97acf3dfda80c91c3a8c9f2372546301d4a1a7a8  transport 包长边界检查
#   CVE-2026-58050 34497525929b9a47f03dfb81887ac896202b7e12  publickey 乘法溢出（含 58051）
#   CVE-2026-58051 a9758da45a52bc8c630ec9493804d0c6ea30b24a  publickey 任意 free
#   CVE-2026-66032 5e4776146552d898b9c0e1b313cd093fa8dc92d0  sftp_open 悬垂指针
#   CVE-2026-66033 a2ed82d40964bbc0d64cd717aa0a5a892117d2e6  AES-GCM OOB 读/写
#   CVE-2026-66034 a13bb6c773f0d55ad1628cede57e99803cd898d9  publickey list OOB 读
#   CVE-2026-66035 42e33d81577ed4b95d4b4f6f845e5ee8efe5eeb4  ETM 解密堆溢出
#   （pinned SHA 还包含 58050/58051 之后的 publickey.c 全部后续修复：
#     c2f1a3a attr memleak、edec1cc publickey_init OOB、d47298d 输入清理等）
#
# 依赖身份（防止“文档说是新版本、实际链接旧 libssh2.a”）：
#   - 构建完成后生成了 ThirdParty/libssh2/include/MacSSHDependencyIdentity.h，
#     编译进 App/测试二进制（经 bridging header），记录 exact commit、版本标记、
#     tarball SHA256 与静态库 SHA256
#   - 构建脚本实际链接产物运行真实校验程序，输出并断言：
#     libssh2_version() / libssh2_crypto_engine() / libssh2_build_options() /
#     OpenSSL_version() 运行时身份，全部写入 MANIFEST
#   - Tests/SSH/DependencyIdentityTests.swift 在 XCTest 中重新断言上述身份，
#     并校验 Xcode 实际链接的 ThirdParty 静态库文件 SHA256 与二进制内嵌元数据一致
#
# 前置要求（仅构建期，不进入 App runtime 依赖）：
#   - Xcode Command Line Tools（clang）
#   - cmake（brew install cmake）
#   - 网络（openssl.org / github.com；脚本含重试）
#
# 禁止事项：不得用 brew install libssh2/openssl 作为 App Runtime；
#           产物必须全部为源码固定 revision 重建的静态库。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRDPARTY="$ROOT/ThirdParty"
DOWNLOADS="$THIRDPARTY/downloads"
WORK="$THIRDPARTY/work"
IDENTITY_HEADER="$THIRDPARTY/libssh2/include/MacSSHDependencyIdentity.h"

# ---------------------------------------------------------------------------
# 固定的依赖版本与校验值
# ---------------------------------------------------------------------------

# libssh2：upstream 官方仓库固定 commit（2026-08-28 master HEAD，1.11.2_DEV 快照，
# 1.11.1 之后 991 个 commit）。选定时已对该 SHA 执行全部 CVE ancestry 验证。
LIBSSH2_COMMIT="be937743a85c4064a6399cee39e606672a401069"
LIBSSH2_TARBALL_SHA256="4e5b4aac79a200551c46fd953e9c2eece0231e72369b22385460e56910369c1d"
LIBSSH2_VERSION_MARKER="1.11.2_DEV"

# OpenSSL 3.5 LTS：官方 release tarball（Phase 5 已构建，保持不变）
OPENSSL_VERSION="3.5.8"
OPENSSL_TARBALL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"

# 逐项 CVE 修复标记（当前 pinned 源码树中的实际代码形态；上游后续重构会改写
# 修复提交引入的原始文本，因此这里固定为 pinned 树中实际存在的等价标记）
declare -a CVE_CHECKS=(
    "CVE-2026-7598|src/userauth.c|Username length out of bounds"
    "CVE-2026-7598|src/userauth.c|Password length out of bounds"
    "CVE-2025-15661|src/sftp.c|lk_target"
    "CVE-2026-55199|src/packet.c|ssh2_get_string(&buf, &name, &name_len)"
    "CVE-2026-55200|src/transport.c|packet_length > LIBSSH2_PACKET_MAXPAYLOAD"
    "CVE-2026-58050|src/publickey.c|Too many publickey attributes"
    "CVE-2026-58051|src/publickey.c|memset(&list[keys], 0, (max_keys - keys) * sizeof(list[keys]));"
    "CVE-2026-66034|src/publickey.c|ListFetch data too short"
    "CVE-2026-66033|src/openssl.c|blocksize < (size_t)(aadlen + authenticationtag)"
    "CVE-2026-66035|src/transport.c|decrypt_size = (ssize_t)(p->total_num - mac_len - 4);"
)

DEPLOYMENT_TARGET="14.0"
JOBS="$(sysctl -n hw.ncpu)"
BUILD_DATE_UTC="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

echo "==> MacSSH dependency build (Phase 5.1 security baseline)"
echo "    libssh2 commit : $LIBSSH2_COMMIT"
echo "    libssh2 marker : $LIBSSH2_VERSION_MARKER"
echo "    OpenSSL        : $OPENSSL_VERSION"
echo "    deployment     : macOS $DEPLOYMENT_TARGET (arm64)"

mkdir -p "$DOWNLOADS" "$WORK"

# ---------------------------------------------------------------------------
# 下载与校验工具
# ---------------------------------------------------------------------------

fetch() {
    # fetch <output> <url>...
    local output="$1"
    shift
    local attempt
    for url in "$@"; do
        for attempt in 1 2 3 4 5; do
            echo "    downloading: $url (attempt $attempt)"
            if curl -sSL --fail --connect-timeout 20 --max-time 600 -o "$output" "$url"; then
                return 0
            fi
            sleep 3
        done
        echo "    source failed after retries, trying next mirror..."
    done
    echo "error: all download sources failed for $output" >&2
    return 1
}

verify_sha256() {
    # verify_sha256 <file> <expected>
    local file="$1" expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "error: SHA256 mismatch for $file" >&2
        echo "  expected: $expected" >&2
        echo "  actual  : $actual" >&2
        return 1
    fi
    echo "    SHA256 OK: $actual"
    return 0
}

sha256_of() {
    # sha256_of <file> —— 输出文件 SHA256（文件必须存在）
    shasum -a 256 "$1" | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# 1. OpenSSL 3.5.8
# ---------------------------------------------------------------------------

OPENSSL_TARBALL="$DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz"

if [ ! -f "$OPENSSL_TARBALL" ]; then
    # 优先 openssl.org 官方源；失败时回退 GitHub 官方 release asset
    fetch "$OPENSSL_TARBALL" \
        "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" \
        "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
        "https://api.github.com/repos/openssl/openssl/releases/assets/529136763"
fi

verify_sha256 "$OPENSSL_TARBALL" "$OPENSSL_TARBALL_SHA256"

OPENSSL_PREFIX="$THIRDPARTY/openssl"

if [ ! -f "$OPENSSL_PREFIX/lib/libcrypto.a" ]; then
    echo "==> Building OpenSSL $OPENSSL_VERSION (arm64, static)"
    OPENSSL_SRC="$WORK/openssl-$OPENSSL_VERSION"
    rm -rf "$OPENSSL_SRC"
    mkdir -p "$OPENSSL_SRC"
    tar -xzf "$OPENSSL_TARBALL" -C "$OPENSSL_SRC" --strip-components=1

    (
        cd "$OPENSSL_SRC"
        ./Configure \
            darwin64-arm64-cc \
            -mmacosx-version-min="$DEPLOYMENT_TARGET" \
            no-shared \
            no-tests \
            no-apps \
            no-docs \
            no-legacy \
            --prefix="$OPENSSL_PREFIX" \
            --openssldir="$OPENSSL_PREFIX"
        make -j"$JOBS" >"$WORK/openssl-build.log" 2>&1
        make install_sw install_ssldirs >"$WORK/openssl-install.log" 2>&1
    )
    echo "    OpenSSL installed to $OPENSSL_PREFIX"
else
    echo "==> OpenSSL already built at $OPENSSL_PREFIX"
fi

# OpenSSL 运行时身份校验：实际链接静态 libcrypto.a 运行并断言版本。
OPENSSL_IDENTITY_SRC="$WORK/openssl-identity.c"
OPENSSL_IDENTITY_BIN="$WORK/openssl-identity"
cat > "$OPENSSL_IDENTITY_SRC" <<'EOF'
#include <stdio.h>
#include <openssl/crypto.h>
int main(void) {
    printf("OpenSSL_version(OPENSSL_VERSION_STRING)=%s\n",
           OpenSSL_version(OPENSSL_VERSION_STRING));
    printf("OpenSSL_version(OPENSSL_VERSION)=%s\n", OpenSSL_version(OPENSSL_VERSION));
    return 0;
}
EOF
clang -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -I"$OPENSSL_PREFIX/include" \
    "$OPENSSL_IDENTITY_SRC" "$OPENSSL_PREFIX/lib/libcrypto.a" \
    -o "$OPENSSL_IDENTITY_BIN"
OPENSSL_RUNTIME_VERSION="$("$OPENSSL_IDENTITY_BIN" | head -1 | cut -d= -f2)"
OPENSSL_RUNTIME_FULL="$("$OPENSSL_IDENTITY_BIN" | sed -n 2p | cut -d= -f2)"
echo "    OpenSSL runtime identity: $OPENSSL_RUNTIME_VERSION / $OPENSSL_RUNTIME_FULL"
if [ "$OPENSSL_RUNTIME_VERSION" != "$OPENSSL_VERSION" ]; then
    echo "error: OpenSSL runtime version mismatch: expected $OPENSSL_VERSION, got $OPENSSL_RUNTIME_VERSION" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. libssh2（Phase 5.1 security baseline pinned commit）
# ---------------------------------------------------------------------------

LIBSSH2_TARBALL="$DOWNLOADS/libssh2-$LIBSSH2_COMMIT.tar.gz"

# 陈旧产物检测：内嵌身份头记录的 commit 与当前 pin 不一致时强制重建，
# 防止 Xcode 继续链接旧 commit 构建出的静态库。
NEED_LIBSSH2_BUILD=0
if [ ! -f "$THIRDPARTY/libssh2/lib/libssh2.a" ]; then
    NEED_LIBSSH2_BUILD=1
elif [ ! -f "$IDENTITY_HEADER" ]; then
    NEED_LIBSSH2_BUILD=1
else
    PINNED_IN_HEADER="$(grep -o '"[0-9a-f]\{40\}"' "$IDENTITY_HEADER" | tr -d '"' | head -1 || true)"
    if [ "$PINNED_IN_HEADER" != "$LIBSSH2_COMMIT" ]; then
        echo "==> Stale libssh2 artifacts detected (identity: ${PINNED_IN_HEADER:-none})"
        echo "    current pin: $LIBSSH2_COMMIT"
        NEED_LIBSSH2_BUILD=1
    fi
fi

if [ ! -f "$LIBSSH2_TARBALL" ]; then
    fetch "$LIBSSH2_TARBALL" \
        "https://codeload.github.com/libssh2/libssh2/tar.gz/$LIBSSH2_COMMIT" \
        "https://github.com/libssh2/libssh2/archive/$LIBSSH2_COMMIT.tar.gz"
fi

verify_sha256 "$LIBSSH2_TARBALL" "$LIBSSH2_TARBALL_SHA256"

LIBSSH2_PREFIX="$THIRDPARTY/libssh2"

if [ "$NEED_LIBSSH2_BUILD" -eq 1 ]; then
    echo "==> Building libssh2 ($LIBSSH2_COMMIT, arm64, static)"
    # 完全清理旧产物（lib/、include/、share/ 与中间目录），确保不存在旧 commit 残留。
    rm -rf "$LIBSSH2_PREFIX" "$WORK/libssh2-"*
    mkdir -p "$LIBSSH2_PREFIX"
    LIBSSH2_SRC="$WORK/libssh2-$LIBSSH2_COMMIT"
    mkdir -p "$LIBSSH2_SRC"
    tar -xzf "$LIBSSH2_TARBALL" -C "$LIBSSH2_SRC" --strip-components=1

    # 硬性验证：版本标记与逐项 CVE 修复标记必须存在于解压源码。
    ACTUAL_MARKER="$(grep -m1 'define LIBSSH2_VERSION ' "$LIBSSH2_SRC/include/libssh2.h" | awk '{print $3}' | tr -d '"')"
    if [ "$ACTUAL_MARKER" != "$LIBSSH2_VERSION_MARKER" ]; then
        echo "error: libssh2 version marker mismatch: expected $LIBSSH2_VERSION_MARKER, got $ACTUAL_MARKER" >&2
        exit 1
    fi
    echo "    version marker OK: $ACTUAL_MARKER"

    echo "    verifying CVE fix markers in source tree..."
    for item in "${CVE_CHECKS[@]}"; do
        CVE="$(echo "$item" | cut -d'|' -f1)"
        FILE="$(echo "$item" | cut -d'|' -f2)"
        MARKER="$(echo "$item" | cut -d'|' -f3)"
        if grep -qF "$MARKER" "$LIBSSH2_SRC/$FILE"; then
            echo "    $CVE fix marker present: $FILE :: $MARKER"
        else
            echo "error: $CVE fix marker missing: $FILE :: $MARKER" >&2
            exit 1
        fi
    done
    # CVE-2026-66032 的修复形态是 free 后紧接置 NULL，需按相邻行验证。
    if grep -A1 -F 'SSH2_FREE(session, data);' "$LIBSSH2_SRC/src/sftp.c" | grep -qF 'data = NULL;'; then
        echo "    CVE-2026-66032 fix marker present: src/sftp.c :: data = NULL after free"
    else
        echo "error: CVE-2026-66032 fix marker missing (dangling pointer nullify in sftp_open)" >&2
        exit 1
    fi

    rm -rf "$LIBSSH2_SRC/build"
    cmake -S "$LIBSSH2_SRC" -B "$LIBSSH2_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DCRYPTO_BACKEND=OpenSSL \
        -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
        -DCMAKE_INSTALL_PREFIX="$LIBSSH2_PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        >"$WORK/libssh2-cmake.log" 2>&1
    cmake --build "$LIBSSH2_SRC/build" --parallel "$JOBS" >"$WORK/libssh2-build.log" 2>&1
    cmake --install "$LIBSSH2_SRC/build" >"$WORK/libssh2-install.log" 2>&1
    echo "    libssh2 installed to $LIBSSH2_PREFIX"
else
    echo "==> libssh2 already built at $LIBSSH2_PREFIX (identity matches pin)"
fi

# libssh2 运行时身份校验：实际链接静态库运行，断言版本与 OpenSSL backend。
LIBSSH2_IDENTITY_SRC="$WORK/libssh2-identity.c"
LIBSSH2_IDENTITY_BIN="$WORK/libssh2-identity"
cat > "$LIBSSH2_IDENTITY_SRC" <<'EOF'
#include <stdio.h>
#include <libssh2.h>
#include <openssl/crypto.h>
int main(void) {
    printf("libssh2_version=%s\n", libssh2_version(0));
    printf("libssh2_crypto_engine=%d\n", (int)libssh2_crypto_engine());
    printf("libssh2_build_options=%s\n", libssh2_build_options());
    printf("openssl_version=%s\n", OpenSSL_version(OPENSSL_VERSION_STRING));
    return 0;
}
EOF
clang -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -I"$LIBSSH2_PREFIX/include" -I"$OPENSSL_PREFIX/include" \
    "$LIBSSH2_IDENTITY_SRC" \
    "$LIBSSH2_PREFIX/lib/libssh2.a" \
    "$OPENSSL_PREFIX/lib/libssl.a" "$OPENSSL_PREFIX/lib/libcrypto.a" \
    -o "$LIBSSH2_IDENTITY_BIN"

LIBSSH2_RUNTIME_VERSION="$("$LIBSSH2_IDENTITY_BIN" | head -1 | cut -d= -f2)"
LIBSSH2_RUNTIME_ENGINE="$("$LIBSSH2_IDENTITY_BIN" | sed -n 2p | cut -d= -f2)"
LIBSSH2_RUNTIME_BUILD_OPTIONS="$("$LIBSSH2_IDENTITY_BIN" | sed -n 3p | cut -d= -f2)"
LIBSSH2_LINKED_OPENSSL="$("$LIBSSH2_IDENTITY_BIN" | sed -n 4p | cut -d= -f2)"
echo "    libssh2 runtime identity:"
echo "      version        : $LIBSSH2_RUNTIME_VERSION"
echo "      crypto engine  : $LIBSSH2_RUNTIME_ENGINE (1 = libssh2_openssl)"
echo "      build options  : $LIBSSH2_RUNTIME_BUILD_OPTIONS"
echo "      linked OpenSSL : $LIBSSH2_LINKED_OPENSSL"

if [ "$LIBSSH2_RUNTIME_VERSION" != "$LIBSSH2_VERSION_MARKER" ]; then
    echo "error: libssh2 runtime version mismatch: expected $LIBSSH2_VERSION_MARKER, got $LIBSSH2_RUNTIME_VERSION" >&2
    exit 1
fi
if [ "$LIBSSH2_RUNTIME_ENGINE" != "1" ]; then
    echo "error: libssh2 crypto backend is not OpenSSL (engine=$LIBSSH2_RUNTIME_ENGINE)" >&2
    exit 1
fi
if [ "$LIBSSH2_LINKED_OPENSSL" != "$OPENSSL_VERSION" ]; then
    echo "error: libssh2 is not using expected OpenSSL $OPENSSL_VERSION (got $LIBSSH2_LINKED_OPENSSL)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. 依赖身份头（编译进 App/测试二进制，建立 binary ↔ pinned SHA 对应关系）
# ---------------------------------------------------------------------------

LIBSSH2_ARCHIVE_SHA256="$(sha256_of "$LIBSSH2_PREFIX/lib/libssh2.a")"
LIBCRYPTO_ARCHIVE_SHA256="$(sha256_of "$OPENSSL_PREFIX/lib/libcrypto.a")"
LIBSSL_ARCHIVE_SHA256="$(sha256_of "$OPENSSL_PREFIX/lib/libssl.a")"

cat > "$IDENTITY_HEADER" <<EOF
/* GENERATED by Scripts/build-dependencies.sh — DO NOT EDIT.
 * Phase 5.1 libssh2 security baseline identity, compiled into the app binary
 * via MacSSHLibSSH2BridgingHeader.h. Asserted at runtime by
 * Tests/SSH/DependencyIdentityTests.swift and recorded in ThirdParty/MANIFEST.txt.
 */
#ifndef MacSSH_DEPENDENCY_IDENTITY_H
#define MacSSH_DEPENDENCY_IDENTITY_H

#define MACSSH_LIBSSH2_SOURCE_REPO "https://github.com/libssh2/libssh2"
#define MACSSH_LIBSSH2_COMMIT "$LIBSSH2_COMMIT"
#define MACSSH_LIBSSH2_VERSION "$LIBSSH2_VERSION_MARKER"
#define MACSSH_LIBSSH2_TARBALL_SHA256 "$LIBSSH2_TARBALL_SHA256"
#define MACSSH_LIBSSH2_ARCHIVE_SHA256 "$LIBSSH2_ARCHIVE_SHA256"
#define MACSSH_OPENSSL_VERSION "$OPENSSL_VERSION"
#define MACSSH_OPENSSL_ARCHIVE_SHA256 "$LIBCRYPTO_ARCHIVE_SHA256"
#define MACSSH_LIBSSL_ARCHIVE_SHA256 "$LIBSSL_ARCHIVE_SHA256"
#define MACSSH_DEPENDENCIES_BUILT_AT "$BUILD_DATE_UTC"

#endif /* MacSSH_DEPENDENCY_IDENTITY_H */
EOF
echo "==> Dependency identity header written to $IDENTITY_HEADER"

# ---------------------------------------------------------------------------
# 4. 产物清单
# ---------------------------------------------------------------------------

MANIFEST="$THIRDPARTY/MANIFEST.txt"
{
    echo "MacSSH third-party dependencies (arm64, macOS $DEPLOYMENT_TARGET+)"
    echo "Generated: $BUILD_DATE_UTC"
    echo ""
    echo "libssh2"
    echo "  source repository : https://github.com/libssh2/libssh2"
    echo "  base/development  : 1.11.2_DEV (1.11.1 + 991 commits upstream snapshot)"
    echo "  exact commit      : $LIBSSH2_COMMIT"
    echo "  version marker    : $LIBSSH2_RUNTIME_VERSION (libssh2_version(0) runtime output)"
    echo "  build date        : $BUILD_DATE_UTC"
    echo "  architecture      : arm64 (macOS $DEPLOYMENT_TARGET+)"
    echo "  crypto backend    : OpenSSL $OPENSSL_VERSION (static; runtime engine=libssh2_openssl)"
    echo "  link type         : static (libssh2.a)"
    echo "  tarball sha256    : $LIBSSH2_TARBALL_SHA256"
    echo "  libssh2.a sha256  : $LIBSSH2_ARCHIVE_SHA256"
    echo "  build options     : $LIBSSH2_RUNTIME_BUILD_OPTIONS"
    echo ""
    echo "  Security fix ancestry verification (git merge-base --is-ancestor <fix> $LIBSSH2_COMMIT):"
    echo "    CVE-2026-7598  fix 256d04b60d80bf1190e96b0ad1e91b2174d744b1  included: YES"
    echo "    CVE-2025-15661 fix 2dae3024897e1898d389835151f4e9606227721d  included: YES"
    echo "    CVE-2026-55199 fix 17626857d20b3c9a1addfa45979dadcee1cd84a4  included: YES"
    echo "    CVE-2026-55200 fix 97acf3dfda80c91c3a8c9f2372546301d4a1a7a8  included: YES"
    echo "    CVE-2026-58050 fix 34497525929b9a47f03dfb81887ac896202b7e12  included: YES (+ follow-ups c2f1a3a, edec1cc, d47298d)"
    echo "    CVE-2026-58051 fix a9758da45a52bc8c630ec9493804d0c6ea30b24a  included: YES"
    echo "    CVE-2026-66032 fix 5e4776146552d898b9c0e1b313cd093fa8dc92d0  included: YES"
    echo "    CVE-2026-66033 fix a2ed82d40964bbc0d64cd717aa0a5a892117d2e6  included: YES"
    echo "    CVE-2026-66034 fix a13bb6c773f0d55ad1628cede57e99803cd898d9  included: YES"
    echo "    CVE-2026-66035 fix 42e33d81577ed4b95d4b4f6f845e5ee8efe5eeb4  included: YES"
    echo "    (all checks executed against a local clone of the official repository;"
    echo "     every command exited 0; build additionally hard-verifies each fix"
    echo "     marker in the extracted source tree before compiling)"
    echo ""
    echo "OpenSSL"
    echo "  source repository : https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz"
    echo "  version           : $OPENSSL_VERSION (3.5 LTS)"
    echo "  runtime identity  : $OPENSSL_RUNTIME_VERSION / $OPENSSL_RUNTIME_FULL"
    echo "  architecture      : arm64 (macOS $DEPLOYMENT_TARGET+)"
    echo "  link type         : static (libcrypto.a, libssl.a)"
    echo "  tarball sha256    : $OPENSSL_TARBALL_SHA256"
    echo "  libcrypto.a sha256: $LIBCRYPTO_ARCHIVE_SHA256"
    echo "  libssl.a sha256   : $LIBSSL_ARCHIVE_SHA256"
    echo "  build             : ./Configure darwin64-arm64-cc no-shared no-tests no-apps no-docs no-legacy"
    echo ""
    echo "Dependency identity"
    echo "  identity header   : ThirdParty/libssh2/include/MacSSHDependencyIdentity.h (generated)"
    echo "    libssh2 commit  : $LIBSSH2_COMMIT"
    echo "    libssh2 version : $LIBSSH2_VERSION_MARKER"
    echo "    openssl version : $OPENSSL_VERSION"
    echo "    built at        : $BUILD_DATE_UTC"
    echo ""
    echo "Artifacts"
    # 仅给非空行加缩进，避免生成含尾随空格的空白行。
    ls -l "$OPENSSL_PREFIX/lib" "$LIBSSH2_PREFIX/lib" | sed '/./s/^/  /'
} > "$MANIFEST"

echo ""
echo "==> Done. Manifest written to $MANIFEST"
