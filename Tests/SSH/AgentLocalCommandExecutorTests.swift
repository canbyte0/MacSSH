import Darwin
import Foundation
import XCTest

@testable import MacSSH

// MARK: - B2 共享 fixture

/// B2 测试工作区：所有 command side effect 一律限定在 TMPDIR 下的
/// 唯一临时目录（§100：绝不动真实项目 / HOME / ~/.ssh / Git repo）。
final class AgentLocalCommandTestWorkspace {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macssh-phase10e-b2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func makeDirectory(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func path(_ name: String) -> String {
        root.appendingPathComponent(name).path
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(name))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// B2 测试共享构造 / 探针。
enum AgentLocalCommandTestSupport {
    /// 快速失败策略（5s timeout / 200ms grace）——绝不真的等 production 60s。
    static let fastPolicy = AgentLocalCommandExecutionPolicy(
        timeout: .seconds(5),
        terminationGracePeriod: .milliseconds(200)
    )

    /// 走完整 request → approval → claim 链，产出一次性授权。
    static func makeAuthorization(
        coordinator: AgentCommandApprovalCoordinator,
        command: String,
        workingDirectory: String,
        target: AgentCommandTarget = .local(displayName: "Local")
    ) async throws -> AgentCommandExecutionAuthorization {
        let request = try AgentCommandTestSupport.makeRequestOrThrow(
            target: target,
            command: command,
            workingDirectory: AgentWorkingDirectory(
                path: workingDirectory,
                source: .osc7,
                confidence: .authoritative
            )
        )
        let approvalID = await coordinator.register(request)
        _ = await coordinator.approve(approvalID)
        return try await coordinator.claimExecution(
            approvalID: approvalID,
            expected: AgentCommandClaimExpectations(
                generationID: request.generationID,
                sessionID: request.sessionID,
                providerSnapshotID: request.providerBinding.snapshotID
            )
        )
    }

    /// `printf 'PID=%s PGID=%s\n' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')"`
    ///
    /// 注意：刻意使用普通字符串（非 raw string）——raw string 的结束符
    /// `"#` 会与结尾引号竞争，导致命令末尾引号被吞。
    static let processIdentifierProbe =
        "printf 'PID=%s PGID=%s\\n' \"$$\" \"$(ps -o pgid= -p $$ | tr -d ' ')\""

    /// token 级解析（`KEY=value` 可在同一行的任意位置）。
    static func parseProcessIdentifiers(from text: String) -> (pid: pid_t, pgid: pid_t)? {
        var pid: pid_t?
        var pgid: pid_t?
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if token.hasPrefix("PID=") {
                pid = pid_t(token.dropFirst(4))
            }
            if token.hasPrefix("PGID=") {
                pgid = pid_t(token.dropFirst(5))
            }
        }
        guard let pid, let pgid else { return nil }
        return (pid, pgid)
    }
}

/// 进程存活探针（zombie 判定：reap 后 `kill(pid, 0)` = ESRCH）。
enum AgentLocalCommandTestProcessProbe {
    static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    static func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isGone(pid) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return isGone(pid)
    }
}

// MARK: - 基础执行 / cwd / 环境 / stdin / TTY

/// Phase 10E-B2 §56–§62：Local Independent Command Executor 基础行为。
final class AgentLocalCommandExecutorTests: XCTestCase {
    private var workspace: AgentLocalCommandTestWorkspace!

    override func setUpWithError() throws {
        workspace = try AgentLocalCommandTestWorkspace()
    }

    override func tearDownWithError() throws {
        workspace.cleanup()
        workspace = nil
    }

    // MARK: - 执行 helper

    @discardableResult
    private func execute(
        _ command: String,
        workingDirectory: String? = nil,
        policy: AgentLocalCommandExecutionPolicy = AgentLocalCommandTestSupport.fastPolicy
    ) async throws -> AgentCommandResult {
        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: command,
            workingDirectory: workingDirectory ?? workspace.root.path
        )
        let executor = AgentLocalCommandExecutor(policy: policy)
        return try await executor.execute(
            authorization: authorization,
            approvalCoordinator: coordinator
        )
    }

    // MARK: - §56 基础执行

    func testEchoWritesStdoutAndExitsZero() async throws {
        let result = try await execute(#"printf 'hello-b2\n'"#)
        XCTAssertEqual(result.stdout, "hello-b2\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.terminationSignal)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertFalse(result.binaryOutputDetected)
        XCTAssertFalse(result.nonUTF8Detected)
        XCTAssertGreaterThan(result.duration, .zero)
    }

    func testStderrOnlyOutput() async throws {
        let result = try await execute(#"printf 'oops-b2\n' >&2"#)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "oops-b2\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStdoutAndStderrAreCapturedSeparately() async throws {
        let result = try await execute(#"printf 'to-stdout\n'; printf 'to-stderr\n' >&2"#)
        XCTAssertEqual(result.stdout, "to-stdout\n")
        XCTAssertEqual(result.stderr, "to-stderr\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNonZeroExitIsValidCommandResultNotInfrastructureError() async throws {
        let result = try await execute("exit 7")
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertNil(result.terminationSignal)
        XCTAssertFalse(result.timedOut)
    }

    func testCommandNotFoundYieldsExit127() async throws {
        // §38：shell 内 "command not found" 是 valid command result（127），
        // 与 spawn/infrastructure failure 严格区分（后者 throw）。
        let result = try await execute("nonexistent_command_phase10e_b2_xyz")
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertTrue(result.stderr.contains("not found"))
    }

    func testMultilineCommandPreservesSemantics() async throws {
        let command = "printf 'a\\n'\nprintf 'b\\n'"
        let result = try await execute(command)
        XCTAssertEqual(result.stdout, "a\nb\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testUnicodeOutputIsPreserved() async throws {
        let result = try await execute(#"printf '中文😀-ok\n'"#)
        XCTAssertEqual(result.stdout, "中文😀-ok\n")
        XCTAssertFalse(result.nonUTF8Detected)
    }

    func testCommandTextIsExecutedVerbatim() async throws {
        // §21/§22：绝不 trim / 改写引号 / 重写空白。
        let result = try await execute(#"printf '<%s>' '  keep  '"#)
        XCTAssertEqual(result.stdout, "<  keep  >")
    }

    // MARK: - §19/§20 shell

    func testShellIsAccountShellWithDashCAndNoLoginOrInteractiveFlags() async throws {
        let resolvedShell = LoginShellResolver.resolve()
        XCTAssertTrue(resolvedShell.hasPrefix("/"))
        let probe = #"""
        printf 'shell=%s\n' "$0"
        printf 'args=%s\n' "$(ps -o args= -p $$ | head -1)"
        if [ -n "${ZSH_VERSION:-}" ]; then
          if [[ -o login ]]; then printf 'login=yes\n'; else printf 'login=no\n'; fi
          if [[ -o interactive ]]; then printf 'interactive=yes\n'; else printf 'interactive=no\n'; fi
        else
          printf 'login=unknown\ninteractive=unknown\n'
        fi
        """#
        let result = try await execute(probe)
        XCTAssertEqual(result.exitCode, 0)

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(
            lines.contains("shell=" + resolvedShell),
            "argv[0] 必须是账户 shell：\(resolvedShell)"
        )
        let argumentsLine = try XCTUnwrap(lines.first { $0.hasPrefix("args=") })
        let tokens = argumentsLine
            .dropFirst(5)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        XCTAssertEqual(tokens.first, resolvedShell)
        XCTAssertEqual(tokens.dropFirst().first, "-c")
        XCTAssertFalse(tokens.contains("-l"), "§20：绝不使用 login flag")
        XCTAssertFalse(tokens.contains("--login"))
        XCTAssertFalse(tokens.contains("-i"), "§20：绝不使用 interactive flag")
        if resolvedShell.hasSuffix("zsh") {
            XCTAssertTrue(lines.contains("login=no"))
            XCTAssertTrue(lines.contains("interactive=no"))
        }
    }

    // MARK: - §57/§58 cwd

    func testWorkingDirectoryIsFrozenApprovedDirectory() async throws {
        let directory = try workspace.makeDirectory(named: "work")
        let result = try await execute("pwd -P", workingDirectory: directory.path)
        let expected = try XCTUnwrap(
            AgentPathResolver.canonicalize(directory.path, kind: .local)
        )
        XCTAssertEqual(result.stdout, expected + "\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testWorkingDirectoryWithSpaces() async throws {
        let directory = try workspace.makeDirectory(named: "dir with spaces")
        let result = try await execute("pwd -P", workingDirectory: directory.path)
        let expected = try XCTUnwrap(AgentPathResolver.canonicalize(directory.path, kind: .local))
        XCTAssertEqual(result.stdout, expected + "\n")
    }

    func testWorkingDirectoryWithUnicode() async throws {
        let directory = try workspace.makeDirectory(named: "中文目录-😀")
        let result = try await execute("pwd -P", workingDirectory: directory.path)
        let expected = try XCTUnwrap(AgentPathResolver.canonicalize(directory.path, kind: .local))
        XCTAssertEqual(result.stdout, expected + "\n")
    }

    func testTwoRequestsUseTheirOwnApprovedWorkingDirectories() async throws {
        // §58：approved cwd 不随"另一个 session/请求的 cwd"漂移。
        let directoryA = try workspace.makeDirectory(named: "project-a")
        let directoryB = try workspace.makeDirectory(named: "project-b")
        let resultA = try await execute("pwd -P", workingDirectory: directoryA.path)
        let resultB = try await execute("pwd -P", workingDirectory: directoryB.path)
        let canonicalA = try XCTUnwrap(AgentPathResolver.canonicalize(directoryA.path, kind: .local))
        let canonicalB = try XCTUnwrap(AgentPathResolver.canonicalize(directoryB.path, kind: .local))
        XCTAssertEqual(resultA.stdout, canonicalA + "\n")
        XCTAssertEqual(resultB.stdout, canonicalB + "\n")
        XCTAssertNotEqual(resultA.stdout, resultB.stdout)
    }

    func testMissingWorkingDirectoryIsRejectedWithoutSpawn() async throws {
        let directory = try workspace.makeDirectory(named: "vanishing")
        let coordinator = AgentCommandApprovalCoordinator()
        let authorization = try await AgentLocalCommandTestSupport.makeAuthorization(
            coordinator: coordinator,
            command: "touch \(workspace.path("should-not-exist"))",
            workingDirectory: directory.path
        )
        try FileManager.default.removeItem(at: directory)

        let executor = AgentLocalCommandExecutor(policy: AgentLocalCommandTestSupport.fastPolicy)
        do {
            _ = try await executor.execute(
                authorization: authorization,
                approvalCoordinator: coordinator
            )
            XCTFail("cwd 不存在必须抛 workingDirectoryUnavailable（§18）")
        } catch let error as AgentCommandExecutionError {
            XCTAssertEqual(error, .workingDirectoryUnavailable)
        }
        XCTAssertFalse(workspace.exists("should-not-exist"), "绝不允许 fallback 到其它目录执行")
    }

    func testFileAsWorkingDirectoryIsRejected() async throws {
        let fileURL = workspace.root.appendingPathComponent("not-a-directory.txt")
        try Data("x".utf8).write(to: fileURL)
        do {
            _ = try await execute("pwd", workingDirectory: fileURL.path)
            XCTFail("非目录 cwd 必须抛 workingDirectoryUnavailable")
        } catch let error as AgentCommandExecutionError {
            XCTAssertEqual(error, .workingDirectoryUnavailable)
        }
    }

    func testUnenterableWorkingDirectoryIsRejected() async throws {
        let directory = try workspace.makeDirectory(named: "locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }
        do {
            _ = try await execute("pwd", workingDirectory: directory.path)
            XCTFail("不可进入 cwd 必须抛 workingDirectoryUnavailable")
        } catch let error as AgentCommandExecutionError {
            XCTAssertEqual(error, .workingDirectoryUnavailable)
        }
    }

    // MARK: - §50/§71/§72 parent 隔离

    func testParentProcessWorkingDirectoryIsUnchanged() async throws {
        let before = FileManager.default.currentDirectoryPath
        let result = try await execute("cd /tmp && pwd")
        XCTAssertEqual(result.stdout, "/tmp\n")
        XCTAssertEqual(FileManager.default.currentDirectoryPath, before)
    }

    func testParentEnvironmentIsUnchanged() async throws {
        let result = try await execute("export MACSSH_TEST_CHILD_ONLY=1")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(
            ProcessInfo.processInfo.environment["MACSSH_TEST_CHILD_ONLY"],
            "子进程 export 绝不改变 App 进程环境（§72）"
        )
    }

    // MARK: - §59 环境 allowlist

    func testEnvironmentIsExplicitAllowlist() async throws {
        let secrets = [
            "FAKE_OPENAI_API_KEY": "sk-fake-b2-openai-secret",
            "FAKE_DEEPSEEK_SECRET": "dsk-fake-b2-deepseek-secret",
            "GITHUB_TOKEN": "ghp_fake_b2_token",
            "MACSSH_B2_CUSTOM_SECRET": "custom-b2-secret-value",
            "SAFE_ALLOWED_VAR": "should-not-be-inherited",
        ]
        for (key, value) in secrets {
            setenv(key, value, 1)
        }
        defer {
            for key in secrets.keys {
                unsetenv(key)
            }
        }

        let result = try await execute("env")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("PATH=\(AgentLocalCommandEnvironment.fixedPATH)"))
        XCTAssertTrue(result.stdout.contains("LANG=\(AgentLocalCommandEnvironment.fixedLANG)"))
        XCTAssertTrue(result.stdout.contains("TERM=\(AgentLocalCommandEnvironment.fixedTERM)"))
        XCTAssertTrue(result.stdout.contains("HOME="))
        XCTAssertTrue(result.stdout.contains("SHELL="))
        for (key, value) in secrets {
            XCTAssertFalse(result.stdout.contains(key), "allowlist 外变量不得进入子进程：\(key)")
            XCTAssertFalse(result.stdout.contains(value), "secret 值不得进入子进程")
        }
    }

    // MARK: - §61/§62 stdin / TTY

    func testStdinIsClosedAndImmediatelyAtEOF() async throws {
        let result = try await execute(#"cat; printf 'cat-exit=%s\n' "$?""#)
        XCTAssertEqual(result.stdout, "cat-exit=0\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testNoTTYIsAllocatedForAnyDescriptor() async throws {
        let probe = """
        for descriptor in 0 1 2; do
          if test -t $descriptor; then printf 'tty=%s\\n' $descriptor; else printf 'notty=%s\\n' $descriptor; fi
        done
        """
        let result = try await execute(probe)
        XCTAssertEqual(result.stdout, "notty=0\nnotty=1\nnotty=2\n")
    }

    // MARK: - §15 CLOEXEC

    func testCLOEXECDefaultDoesNotLeakParentDescriptors() async throws {
        // canary：在测试进程打开一个高位 fd（shell 内部 fd 在低位），
        // 子进程不得看到它（POSIX_SPAWN_CLOEXEC_DEFAULT）。
        var canaryDescriptors: [Int32] = []
        defer {
            for descriptor in canaryDescriptors {
                close(descriptor)
            }
        }
        var canary: Int32 = -1
        for _ in 0..<64 {
            let descriptor = open("/dev/null", O_RDONLY)
            guard descriptor >= 0 else { break }
            canaryDescriptors.append(descriptor)
            if descriptor >= 30 {
                canary = descriptor
                break
            }
        }
        let descriptorNumber = try XCTUnwrap(canary >= 30 ? canary : nil, "无法取得高位 canary fd")

        let command = "test -e /dev/fd/\(descriptorNumber) && printf 'leaked\\n' || printf 'clean\\n'"
        let result = try await execute(command)
        XCTAssertEqual(result.stdout, "clean\n", "父进程 fd 不得泄漏给子进程（§15）")
    }

    // MARK: - §41/§43 policy

    func testExecutionUsesProductionPolicyAndCompletesNormally() async throws {
        // production policy（60 s timeout / 5 s grace）下的真实执行：
        // 短命令正常完成，timeout 不触发（防止"只有测试策略被执行过"）。
        let result = try await execute(#"printf 'production-ok\n'"#, policy: .production)
        XCTAssertEqual(result.stdout, "production-ok\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.cancelled)
    }

    func testProductionPolicyDefaultsAndHardMaxClamp() async throws {
        XCTAssertEqual(AgentLocalCommandExecutionPolicy.production.timeout, .seconds(60))
        XCTAssertEqual(
            AgentLocalCommandExecutionPolicy.production.terminationGracePeriod,
            .seconds(5)
        )
        let clamped = AgentLocalCommandExecutionPolicy(
            timeout: .seconds(700),
            terminationGracePeriod: .seconds(20)
        )
        XCTAssertEqual(clamped.timeout, .seconds(600), "§43：internal timeout 硬上限 600s")
        XCTAssertEqual(AgentCommandExecutionLimits.stdoutMaxBytes, 256 * 1024)
        XCTAssertEqual(AgentCommandExecutionLimits.stderrMaxBytes, 256 * 1024)
    }
}
