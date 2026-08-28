import CryptoKit
import Foundation
import XCTest

@testable import MacSSH

/// Phase 5.1 依赖身份验证。
///
/// 目的：证明“文档说是新版本”与“App 实际链接的静态库”完全一致，
/// 防止出现 MANIFEST 已更新、但 Xcode 仍链接旧 commit 构建的 `libssh2.a`。
///
/// 验证依据（三层相互印证）：
/// 1. `libssh2_version(0)` / `libssh2_crypto_engine()` / `libssh2_build_options()`：
///    App 二进制内实际链接的 libssh2 运行时输出；
/// 2. `MACSSH_*` build-generated 元数据：依赖构建脚本写入、经 bridging header
///    编译进 App/测试二进制的 pinned SHA、版本标记与静态库 SHA256；
/// 3. Xcode `LIBRARY_SEARCH_PATHS` 实际链接的 `ThirdParty` 静态库文件本身的 SHA256。
final class DependencyIdentityTests: XCTestCase {
    /// Phase 5.1 安全基线 pin。与 Scripts/build-dependencies.sh 的 LIBSSH2_COMMIT、
    /// ThirdParty/MANIFEST.txt 的 exact commit 必须一致。
    private let pinnedCommit = "be937743a85c4064a6399cee39e606672a401069"
    private let pinnedLibSSH2Version = "1.11.2_DEV"
    private let pinnedOpenSSLVersion = "3.5.8"

    private let expectedSourceRepository = "https://github.com/libssh2/libssh2"

    /// 上游安全基线默认关闭的旧算法（Phase 5.1 明确禁止重新打开）。
    private let disabledLegacyAlgorithmMarkers = [
        "MD5:off",
        "DSA:off",
        "RSA-SHA1:off",
        "KEX-SHA1:off",
        "MAC-SHA1:off",
        "BLOWFISH:off",
        "RC4:off",
        "CAST:off",
        "3DES:off",
    ]

    /// 由测试源文件位置推导项目根目录（本机开发/验收环境）。
    private var projectDirectory: String {
        let path = (#filePath as NSString).deletingLastPathComponent
        return ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    // MARK: - 二进制内嵌 build manifest 身份

    /// App 二进制内嵌的依赖身份必须等于 Phase 5.1 pinned commit。
    /// 若 App 链接了旧 libssh2.a 或构建产物陈旧，此处直接失败。
    func testBinaryEmbeddedIdentityMatchesPhase51PinnedBaseline() {
        XCTAssertEqual(
            MACSSH_LIBSSH2_COMMIT,
            pinnedCommit,
            "App 二进制内嵌的 libssh2 commit 不是 Phase 5.1 pin；"
                + "存在旧 commit 构建的静态库或陈旧构建产物"
        )
        XCTAssertEqual(MACSSH_LIBSSH2_SOURCE_REPO, expectedSourceRepository)
        XCTAssertEqual(MACSSH_LIBSSH2_VERSION, pinnedLibSSH2Version)
        XCTAssertEqual(MACSSH_OPENSSL_VERSION, pinnedOpenSSLVersion)
    }

    // MARK: - libssh2 运行时身份

    /// `libssh2_version(0)` 为 App 实际链接的 libssh2 运行时版本。
    func testLibSSH2RuntimeVersionMatchesPinnedIdentity() {
        let runtimeVersion = String(cString: libssh2_version(0))
        XCTAssertEqual(
            runtimeVersion,
            pinnedLibSSH2Version,
            "libssh2 runtime version 与 Phase 5.1 pin 不匹配"
        )
        XCTAssertEqual(
            runtimeVersion,
            MACSSH_LIBSSH2_VERSION,
            "libssh2 runtime version 与二进制内嵌 build manifest 不一致"
        )
    }

    /// `libssh2_crypto_engine()` 必须报告 OpenSSL backend。
    func testLibSSH2CryptoBackendIsOpenSSL() {
        XCTAssertEqual(
            libssh2_crypto_engine().rawValue,
            libssh2_openssl.rawValue,
            "libssh2 crypto backend 不是 OpenSSL"
        )
    }

    /// `libssh2_build_options()` 输出实际构建配置；旧算法必须保持 upstream 默认关闭。
    func testLibSSH2BuildOptionsKeepLegacyAlgorithmsDisabled() throws {
        let buildOptions = String(cString: libssh2_build_options())
        XCTAssertTrue(
            buildOptions.contains("crypto:OpenSSL"),
            "libssh2 build options 未报告 OpenSSL backend: \(buildOptions)"
        )
        for marker in disabledLegacyAlgorithmMarkers {
            XCTAssertTrue(
                buildOptions.contains(marker),
                "upstream 默认关闭的旧算法未保持关闭: 期望 \(marker)，实际 \(buildOptions)"
            )
        }
    }

    // MARK: - Xcode 实际链接的静态库与内嵌身份一致

    /// Xcode `LIBRARY_SEARCH_PATHS` 指向的 ThirdParty 静态库文件必须与
    /// 二进制内嵌的 SHA256 一致：任何“只改文档没换 binary”的情况在此失败。
    func testLinkedStaticArchivesMatchEmbeddedIdentity() throws {
        let libssh2Archive = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent("ThirdParty/libssh2/lib/libssh2.a")
        let libcryptoArchive = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent("ThirdParty/openssl/lib/libcrypto.a")
        let libsslArchive = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent("ThirdParty/openssl/lib/libssl.a")

        XCTAssertEqual(
            try sha256(of: libssh2Archive),
            MACSSH_LIBSSH2_ARCHIVE_SHA256,
            "ThirdParty/libssh2/lib/libssh2.a 与二进制内嵌 SHA256 不一致（Xcode 将链接到与依赖身份不符的静态库）"
        )
        XCTAssertEqual(
            try sha256(of: libcryptoArchive),
            MACSSH_OPENSSL_ARCHIVE_SHA256,
            "ThirdParty/openssl/lib/libcrypto.a 与二进制内嵌 SHA256 不一致"
        )
        XCTAssertEqual(
            try sha256(of: libsslArchive),
            MACSSH_LIBSSL_ARCHIVE_SHA256,
            "ThirdParty/openssl/lib/libssl.a 与二进制内嵌 SHA256 不一致"
        )
    }

    // MARK: - 身份输出（供测试日志与验收报告引用）

    /// 输出实际 runtime version、pinned SHA 与 OpenSSL 版本。
    func testPrintDependencyIdentitySummary() {
        let summary = """
        ---- MacSSH dependency identity (Phase 5.1) ----
        libssh2 runtime version : \(String(cString: libssh2_version(0)))
        libssh2 pinned commit   : \(MACSSH_LIBSSH2_COMMIT)
        libssh2 source repo     : \(MACSSH_LIBSSH2_SOURCE_REPO)
        libssh2 build options   : \(String(cString: libssh2_build_options()))
        OpenSSL pinned version  : \(MACSSH_OPENSSL_VERSION)
        dependencies built at   : \(MACSSH_DEPENDENCIES_BUILT_AT)
        --------------------------------------------------
        """
        print(summary)
        XCTAssertFalse(MACSSH_LIBSSH2_COMMIT.isEmpty)
    }

    // MARK: - Helpers

    private func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
