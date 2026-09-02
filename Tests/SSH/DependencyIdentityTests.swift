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

    // MARK: - SwiftTerm fork identity（MacSSH 1.1 Phase 5）

    /// Phase 5 SwiftTerm 依赖身份 pin。SwiftTerm 不再直接引用上游
    /// `migueldeicaza/SwiftTerm`，也不使用本地 `ThirdParty/SwiftTerm-fork`
    /// 作为生产依赖来源。生产依赖是一个 MacSSH 维护的、发布到 GitHub 的远端
    /// fork（remote SwiftPM source-control 依赖），其上有一个用于 VS16
    /// preserve-base-width 兼容的原子 patch。这些值必须与 ThirdParty/MANIFEST.txt、
    /// Package.resolved 一致。
    private let swiftTermUpstreamBase = "464df5207fc2432e16c9a23abe538187196daf5f"
    private let swiftTermUpstreamTag = "v1.19.0"
    private let swiftTermForkRepositoryURL = "https://github.com/canbyte0/SwiftTerm.git"
    private let swiftTermForkPatchBranch = "macssh-vs16-preserve-base-width"
    private let swiftTermPatchRevision = "8a5187fe8182bac3a01f2b82d2621993de5886be"

    /// Package.resolved 的文件路径（与 Xcode 工作区共享的 resolved 文件）。
    private var packageResolvedURL: URL {
        URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent("MacSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    }

    /// 解析 Package.resolved JSON。
    private func loadPackageResolved() throws -> [String: Any] {
        let data = try Data(contentsOf: packageResolvedURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // swiftlint:disable:next force_cast
        return object ?? [:]
    }

    /// 在 Package.resolved 的 pins 中查找指定 identity 的条目。
    private func pin(forIdentity identity: String, in root: [String: Any]) -> [String: Any]? {
        guard let pins = root["pins"] as? [[String: Any]] else { return nil }
        for pin in pins where (pin["identity"] as? String) == identity {
            return pin
        }
        return nil
    }

    /// Package.resolved 必须把 SwiftTerm 锁定到 Phase 5 的 MacSSH 远端 fork patch
    /// revision（remoteSourceControl），而不是本地路径或上游 base。SwiftPM identity
    /// 由 Package.swift 的 `name:` 推导；远端 fork 的 identity 形如 "swiftterm"。
    func testPackageResolvedLocksSwiftTermToPhase5RemoteForkRevision() throws {
        let root = try loadPackageResolved()
        // 远端 fork 的 Package.swift name 仍为 "SwiftTerm"，SwiftPM identity = "swiftterm"。
        // 本轮已从 localSourceControl("swiftterm-fork") 切换到 remoteSourceControl。
        let pin = try XCTUnwrap(pin(forIdentity: "swiftterm", in: root),
                                "Package.resolved 未包含 swiftterm remoteSourceControl pin")
        XCTAssertEqual(pin["kind"] as? String, "remoteSourceControl",
                       "SwiftTerm 依赖必须是 remoteSourceControl（MacSSH 远端 fork）")
        let state = try XCTUnwrap(pin["state"] as? [String: Any])
        XCTAssertEqual(
            state["revision"] as? String,
            swiftTermPatchRevision,
            "Package.resolved 锁定的 SwiftTerm revision 不是 Phase 5 patch commit"
        )
        // location 必须指向 GitHub 上的 MacSSH 维护 fork，而非本地路径或上游仓库。
        let location = try XCTUnwrap(pin["location"] as? String)
        XCTAssertEqual(location, swiftTermForkRepositoryURL,
                       "SwiftTerm dependency location 不是 MacSSH fork 远端 URL：\(location)")
    }

    /// Package.resolved 不得引用上游 `migueldeicaza/SwiftTerm.git`
    /// 作为生产依赖，也不得保留本地路径 `localSourceControl` 残留。
    func testPackageResolvedHasNoLocalForkOrUpstreamRemoteReference() throws {
        let root = try loadPackageResolved()
        // 不得残留 localSourceControl pin。
        if let pins = root["pins"] as? [[String: Any]] {
            for pin in pins {
                let kind = (pin["kind"] as? String) ?? ""
                let location = (pin["location"] as? String) ?? ""
                XCTAssertFalse(kind == "localSourceControl",
                               "Package.resolved 仍包含 localSourceControl pin：\(pin)")
                XCTAssertFalse(location.contains("ThirdParty/SwiftTerm-fork"),
                               "Package.resolved 仍引用本地 fork 路径：\(location)")
                XCTAssertFalse(location.contains("migueldeicaza/SwiftTerm"),
                               "Package.resolved 仍引用上游 migueldeicaza/SwiftTerm：\(location)")
            }
        }
    }

    /// 输出 SwiftTerm fork 身份摘要（upstream base / fork 远端 URL / patch branch /
    /// patch revision / upstream tag），供测试日志与验收报告引用，并校验各字段非空。
    func testPrintSwiftTermForkIdentitySummary() {
        let summary = """
        ---- MacSSH SwiftTerm fork identity (Phase 5) ----
        upstream repository : migueldeicaza/SwiftTerm
        upstream base       : \(swiftTermUpstreamBase) (\(swiftTermUpstreamTag))
        MacSSH fork remote  : \(swiftTermForkRepositoryURL)
        patch branch        : \(swiftTermForkPatchBranch)
        production revision : \(swiftTermPatchRevision)
        dependency type     : remote SwiftPM source-control (exact revision)
        ----------------------------------------------------
        """
        print(summary)
        XCTAssertFalse(swiftTermUpstreamBase.isEmpty)
        XCTAssertFalse(swiftTermForkRepositoryURL.isEmpty)
        XCTAssertFalse(swiftTermPatchRevision.isEmpty)
        XCTAssertNotEqual(swiftTermUpstreamBase, swiftTermPatchRevision,
                          "upstream base 与 patch revision 不能相同（patch 必须是 fork 上的新 commit）")
    }

    // MARK: - Helpers

    private func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
