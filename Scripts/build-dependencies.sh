#!/bin/bash
#
# MacSSH 第三方依赖构建脚本（Phase 5：SSH 基础连接）
#
# 构建内容：
#   1. OpenSSL 3.5.8（官方 release tarball，静态库，arm64，macOS 14.0+）
#   2. libssh2（upstream commit 256d04b6，包含 CVE-2026-7598 修复，静态库，arm64）
#
# 产物安装到：
#   ThirdParty/openssl/{include,lib}
#   ThirdParty/libssh2/{include,lib}
#
# 可复现性：
#   - 所有源码下载均校验 SHA256
#   - 版本/commit 完整固定，见 ThirdParty/MANIFEST.txt
#
# 前置要求（仅构建期，不进入 App runtime 依赖）：
#   - Xcode Command Line Tools（clang）
#   - cmake（brew install cmake）
#   - 网络（openssl.org / github.com；脚本含镜像 fallback）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRDPARTY="$ROOT/ThirdParty"
DOWNLOADS="$THIRDPARTY/downloads"
WORK="$THIRDPARTY/work"

# ---------------------------------------------------------------------------
# 固定的依赖版本与校验值
# ---------------------------------------------------------------------------

# libssh2：upstream commit，基于 1.11.2_DEV，包含 CVE-2026-7598 修复
# （userauth.c username_len bounds checking，PR #1858，GPG verified）
LIBSSH2_COMMIT="256d04b60d80bf1190e96b0ad1e91b2174d744b1"
LIBSSH2_TARBALL_SHA256="6b16b30d0437c4c13ec854011b654a79c5f23c22dc8ef26d6ac6d8754c7e9a24"

# OpenSSL 3.5 LTS：官方 release tarball
OPENSSL_VERSION="3.5.8"
OPENSSL_TARBALL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"

DEPLOYMENT_TARGET="14.0"
JOBS="$(sysctl -n hw.ncpu)"

echo "==> MacSSH dependency build"
echo "    libssh2 commit : $LIBSSH2_COMMIT"
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
    for url in "$@"; do
        echo "    downloading: $url"
        if curl -sSL --fail --connect-timeout 20 -o "$output" "$url"; then
            return 0
        fi
        echo "    source failed, trying next mirror..."
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
}

# ---------------------------------------------------------------------------
# 1. OpenSSL 3.5.8
# ---------------------------------------------------------------------------

OPENSSL_TARBALL="$DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz"

if [ ! -f "$OPENSSL_TARBALL" ]; then
    # 优先 openssl.org 官方源；失败时回退 GitHub 官方 release asset
    # （GitHub asset id 对应 openssl-3.5.8.tar.gz，其 digest 即上方 SHA256）
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

# ---------------------------------------------------------------------------
# 2. libssh2（含 CVE-2026-7598 修复）
# ---------------------------------------------------------------------------

LIBSSH2_TARBALL="$DOWNLOADS/libssh2-$LIBSSH2_COMMIT.tar.gz"

if [ ! -f "$LIBSSH2_TARBALL" ]; then
    fetch "$LIBSSH2_TARBALL" \
        "https://codeload.github.com/libssh2/libssh2/tar.gz/$LIBSSH2_COMMIT" \
        "https://github.com/libssh2/libssh2/archive/$LIBSSH2_COMMIT.tar.gz"
fi

verify_sha256 "$LIBSSH2_TARBALL" "$LIBSSH2_TARBALL_SHA256"

LIBSSH2_PREFIX="$THIRDPARTY/libssh2"

if [ ! -f "$LIBSSH2_PREFIX/lib/libssh2.a" ]; then
    echo "==> Building libssh2 ($LIBSSH2_COMMIT, arm64, static)"
    LIBSSH2_SRC="$WORK/libssh2-$LIBSSH2_COMMIT"
    rm -rf "$LIBSSH2_SRC"
    mkdir -p "$LIBSSH2_SRC"
    tar -xzf "$LIBSSH2_TARBALL" -C "$LIBSSH2_SRC" --strip-components=1

    # 硬性验证：快照必须包含 CVE-2026-7598 修复（userauth.c bounds checks）
    if ! grep -q "username_len out of bounds" "$LIBSSH2_SRC/src/userauth.c"; then
        echo "error: CVE-2026-7598 fix not found in libssh2 source" >&2
        exit 1
    fi
    echo "    CVE-2026-7598 fix present in source (userauth.c bounds checks)"

    rm -rf "$LIBSSH2_SRC/build"
    cmake -S "$LIBSSH2_SRC" -B "$LIBSSH2_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DBUILD_SHARED_LIBS=OFF \
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
    echo "==> libssh2 already built at $LIBSSH2_PREFIX"
fi

# ---------------------------------------------------------------------------
# 3. 产物清单
# ---------------------------------------------------------------------------

MANIFEST="$THIRDPARTY/MANIFEST.txt"
{
    echo "MacSSH third-party dependencies (arm64, macOS $DEPLOYMENT_TARGET+)"
    echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""
    echo "libssh2"
    echo "  source        : https://github.com/libssh2/libssh2"
    echo "  base version  : 1.11.2_DEV (post 1.11.1 development snapshot)"
    echo "  commit        : $LIBSSH2_COMMIT"
    echo "  tarball sha256: $LIBSSH2_TARBALL_SHA256"
    echo "  CVE-2026-7598 : FIXED (userauth.c username_len bounds checking, upstream PR #1858)"
    echo "  crypto backend: OpenSSL $OPENSSL_VERSION (static)"
    echo "  build         : cmake, Release, static, arm64"
    echo ""
    echo "OpenSSL"
    echo "  source        : https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz"
    echo "  version       : $OPENSSL_VERSION (3.5 LTS)"
    echo "  tarball sha256: $OPENSSL_TARBALL_SHA256"
    echo "  build         : ./Configure darwin64-arm64-cc no-shared no-tests no-apps no-docs no-legacy"
    echo ""
    echo "Artifacts"
    # 仅给非空行加缩进，避免生成含尾随空格的空白行。
    ls -l "$OPENSSL_PREFIX/lib" "$LIBSSH2_PREFIX/lib" | sed '/./s/^/  /'
} > "$MANIFEST"

echo ""
echo "==> Done. Manifest written to $MANIFEST"
