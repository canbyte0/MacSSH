import XCTest

@testable import MacSSH

/// MacSSH 1.1 Phase 10D-B1 §9：cwd domain model 测试。
///
/// 核心断言：cwd 的安全语义（source / confidence / path）只由工厂
/// 构造合法组合，非法 OSC 7 输入一律 closed（unavailable），
/// 绝不猜测路径。
final class AgentCWDTests: XCTestCase {
    // MARK: - OSC 7 → authoritative

    /// OSC 7 URL 解码为权威路径（Foundation 按 RFC 3986 还原
    /// percent-encoding）。
    func testOSC7URLYieldsAuthoritativeDecodedPath() {
        let cwd = AgentWorkingDirectory.fromOSC7URL("file://MacBook-Air/simple/path")
        XCTAssertEqual(cwd.path, "/simple/path")
        XCTAssertEqual(cwd.source, .osc7)
        XCTAssertEqual(cwd.confidence, .authoritative)
    }

    /// Unicode / 空格 / `%` / `?` / `#` 全部正确解码（任务书 §4 硬断言
    /// 的解码侧对应）。
    func testOSC7DecodesUnicodeSpacesAndReservedMarks() {
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/%E8%B7%AF%E5%BE%84/%E4%B8%AD%E6%96%87").path,
            "/路径/中文"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/%ED%95%9C%EA%B5%AD%EC%96%B4/%ED%85%8C%EC%8A%A4%ED%8A%B8").path,
            "/한국어/테스트"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/%E6%97%A5%E6%9C%AC%E8%AA%9E/%E3%83%86%E3%82%B9%E3%83%88").path,
            "/日本語/テスト"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/emoji/%F0%9F%98%80").path,
            "/emoji/😀"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/path%20with%20spaces").path,
            "/path with spaces"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/contains%25percent").path,
            "/contains%percent"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/question%3Fmark").path,
            "/question?mark"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/hash%23fragment").path,
            "/hash#fragment"
        )
        XCTAssertEqual(
            AgentWorkingDirectory.fromOSC7URL("file://h/mixed/%E4%B8%AD%E6%96%87%20test%20%25%20%23%20%3F").path,
            "/mixed/中文 test % # ?"
        )
    }

    /// 非法输入全部 closed：nil / 空 / 不可解析 / 非 file scheme /
    /// 空路径——绝不返回伪造 path。
    func testInvalidOSC7InputsFallBackToUnavailable() {
        for raw in [nil, "", "not a url with spaces", "http://host/path", "file://host"] {
            let cwd = AgentWorkingDirectory.fromOSC7URL(raw)
            XCTAssertNil(cwd.path, "输入 \(raw ?? "nil") 必须解析失败")
            XCTAssertEqual(cwd.source, .unavailable)
            XCTAssertEqual(cwd.confidence, .unavailable)
        }
    }

    // MARK: - sessionDefault → approximate

    /// SFTP 会话默认目录只是近似：携带 path 但不得参与 allowedRoots
    /// / 相对路径基准（由 scope 与 resolver 测试另行覆盖）。
    func testSessionDefaultIsApproximate() {
        let cwd = AgentWorkingDirectory.sessionDefault(path: "/home/user")
        XCTAssertEqual(cwd.path, "/home/user")
        XCTAssertEqual(cwd.source, .sessionDefault)
        XCTAssertEqual(cwd.confidence, .approximate)
    }

    func testEmptySessionDefaultPathIsUnavailable() {
        XCTAssertEqual(AgentWorkingDirectory.sessionDefault(path: ""), .unavailable)
    }

    // MARK: - unavailable

    func testUnavailableModelCarriesNoPath() {
        XCTAssertNil(AgentWorkingDirectory.unavailable.path)
        XCTAssertEqual(AgentWorkingDirectory.unavailable.source, .unavailable)
        XCTAssertEqual(AgentWorkingDirectory.unavailable.confidence, .unavailable)
    }

    // MARK: - 双轴 policy（任务书 §11）

    /// 变更风险与数据披露是正交枚举：同一个 readOnly 风险必须可以
    /// 配两种数据访问策略——合并为一个 enum 会让「只读」绕过 scope。
    func testMutationRiskAndDataAccessAreDistinctAxes() {
        let combinations = [
            (AgentToolRisk.readOnly, AgentDataAccessPolicy.sessionContext),
            (AgentToolRisk.readOnly, AgentDataAccessPolicy.scopedFileRead),
            (AgentToolRisk.modifying, AgentDataAccessPolicy.scopedFileRead),
            (AgentToolRisk.destructive, AgentDataAccessPolicy.scopedFileRead)
        ]
        XCTAssertEqual(Set(combinations.map { "\($0)|\($1)" }).count, combinations.count)
    }
}
