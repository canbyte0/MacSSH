import Darwin
import Foundation
import SwiftTerm
import SwiftData
import XCTest

@testable import MacSSH

/// MacSSH 1.1 Phase 3：Native Login Shell Behavior 测试。
///
/// 三类用例：
/// - 纯决策（`LocalShellLauncher.resolve` 注入账户与文件系统状态）：
///   登录链 / 回退矩阵、环境构造、argv 语义；
/// - locale policy（P3 整改）：LANG 只来自系统 locale 派生
///   （绝不硬编码任何具体 locale、绝不注入 LC_*）、POSIX 规范化、
///   与 AppLanguage UI 语言解耦；
/// - 真实集成（forkpty + /usr/bin/login 真实进程链）：interactive
///   login shell 语义、TTY、环境变量（含 LANG / LC_ALL）、cwd、
///   exit / terminate 进程收敛、50× 创建关闭无孤儿（任务书 49/50/63）。
///
/// 断言策略（任务书 47/48/64）：只测稳定语义（login 标志、TTY 前缀、
/// 账户路径），绝不硬编码日期文本、ttys 编号或具体 PATH 字符串。
@MainActor
final class LocalShellLauncherTests: XCTestCase {
    /// 集成用例持有的 Local Terminal Service；tearDown 统一清理子进程。
    private var services: [LocalTerminalService] = []

    override func tearDown() async throws {
        for service in services {
            service.terminate()
        }
        services.removeAll()
    }

    // MARK: - 纯决策：登录链与回退矩阵

    /// 独立偏好域验证默认关闭及重新创建 AppState 后的开关持久化。
    func testPasteHighlightPreferencePersistsAcrossAppStateCreation() throws {
        let suiteName = "MacSSH.PasteHighlightTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let schema = Schema([Host.self, HostGroup.self, KnownHost.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let initial = AppState(modelContainer: container, userDefaults: defaults)
        XCTAssertFalse(initial.pasteHighlightEnabled)
        initial.pasteHighlightEnabled = true
        let reloaded = AppState(modelContainer: container, userDefaults: defaults)
        XCTAssertTrue(reloaded.pasteHighlightEnabled)
        reloaded.pasteHighlightEnabled = false
        XCTAssertFalse(AppState(modelContainer: container, userDefaults: defaults).pasteHighlightEnabled)
    }

    /// 控制通道不可用时：所有本地 zsh（无论粘贴高亮开关）恒定注入
    /// ZDOTDIR 启动代理与开关初值——Phase 10D-B1 起 OSC 7 cwd emitter
    /// 必须在任何配置组合下稳定加载，不再依赖粘贴高亮状态；bash 不注入。
    /// 关闭态显式传递 `MACSSH_PASTE_HIGHLIGHT_ENABLED=0`：旧实现只注入
    /// ZDOTDIR 不注入开关值，`.zshenv` 的默认值会把关闭态错误翻成开启。
    func testPasteHighlightFallbackInjectsStartupAgentForAllLocalZshStates() {
        for shell in ["/bin/zsh", "/bin/bash"] {
            for enabled in [false, true] {
                let configuration = LocalShellLauncher.resolve(
                    username: "tester", home: "/Users/tester",
                    accountShell: shell, environmentShell: nil, lang: nil,
                    pasteHighlightEnabled: enabled,
                    zshIntegrationDirectory: "/Application With Spaces/ShellIntegration",
                    isExecutable: { _ in true }
                )
                XCTAssertEqual(configuration.executable, "/usr/bin/login")
                XCTAssertEqual(configuration.args, ["-p", "-f", "tester"])
                let isZsh = shell == "/bin/zsh"
                XCTAssertEqual(
                    configuration.environment.contains("ZDOTDIR=/Application With Spaces/ShellIntegration"),
                    isZsh,
                    "OSC 7 emitter 必须在粘贴高亮两种状态下都加载"
                )
                XCTAssertEqual(
                    configuration.environment.contains(
                        "MACSSH_PASTE_HIGHLIGHT_ENABLED=\(enabled ? "1" : "0")"
                    ),
                    isZsh,
                    "两种开关状态都必须显式传递初值"
                )
            }
        }
    }

    /// 控制通道可用时，两种开关状态的 zsh 都装配运行时监听；bash 不装配。
    func testPasteHighlightRuntimeControlIsRestrictedToLocalZsh() {
        for shell in ["/bin/zsh", "/bin/bash"] {
            for enabled in [false, true] {
                let configuration = LocalShellLauncher.resolve(
                    username: "tester", home: "/Users/tester",
                    accountShell: shell, environmentShell: nil, lang: nil,
                    pasteHighlightEnabled: enabled,
                    pasteHighlightControlPath: "/private/control.fifo",
                    zshIntegrationDirectory: "/Application With Spaces/ShellIntegration",
                    isExecutable: { _ in true }
                )
                let isZsh = shell == "/bin/zsh"
                XCTAssertEqual(
                    configuration.environment.contains("ZDOTDIR=/Application With Spaces/ShellIntegration"),
                    isZsh
                )
                XCTAssertEqual(
                    configuration.environment.contains("MACSSH_PASTE_HIGHLIGHT_FIFO=/private/control.fifo"),
                    isZsh
                )
                XCTAssertEqual(
                    configuration.environment.contains(
                        "MACSSH_PASTE_HIGHLIGHT_ENABLED=\(enabled ? "1" : "0")"
                    ),
                    isZsh
                )
            }
        }
    }

    /// App 端控制通道按顺序写入完整状态消息，供已打开 zsh 的 ZLE 读取。
    func testPasteHighlightControlChannelQueuesStateMessages() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacSSH.PasteChannelTests.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let channel = try XCTUnwrap(
            PasteHighlightControlChannel(temporaryDirectory: temporaryDirectory)
        )
        defer { channel.close() }
        let reader = open(channel.fifoPath, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }

        XCTAssertTrue(channel.send(isEnabled: true))
        XCTAssertTrue(channel.send(isEnabled: false))

        var bytes = [UInt8](repeating: 0, count: 4)
        let count = read(reader, &bytes, bytes.count)
        XCTAssertEqual(count, 4)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "1\n0\n")
    }

    /// 资源缺失时不注入失效 ZDOTDIR，继续原生启动（打包另有资源检查）。
    func testPasteHighlightMissingResourcesPreservesNativeStartup() {
        let configuration = LocalShellLauncher.resolve(
            username: "tester", home: "/Users/tester", accountShell: "/bin/zsh",
            environmentShell: nil, lang: nil, pasteHighlightEnabled: false,
            isExecutable: { _ in true }
        )
        XCTAssertFalse(configuration.environment.contains { $0.hasPrefix("ZDOTDIR=") })
    }

    /// 账户 Shell 与 /usr/bin/login 均可用 → 系统登录链，
    /// argv 与 Terminal.app 实证一致（`login -p -f <user>`，
    /// 绝不使用会禁用 login 语义的 -l）。
    func testA_SystemLoginChainWhenAccountShellAndLoginUsable() {
        let configuration = LocalShellLauncher.resolve(
            username: "msl",
            home: "/Users/msl",
            accountShell: "/bin/zsh",
            environmentShell: nil,
            lang: "fr_FR.UTF-8",
            isExecutable: executablePaths(["/bin/zsh", "/usr/bin/login"])
        )

        XCTAssertEqual(configuration.executable, "/usr/bin/login")
        XCTAssertEqual(configuration.args, ["-p", "-f", "msl"])
        XCTAssertNil(configuration.execName, "login 链下 argv[0] 由 login 决定")
        XCTAssertEqual(configuration.currentDirectory, "/Users/msl")
        XCTAssertEqual(configuration.strategy, .systemLogin(username: "msl"))
        XCTAssertEqual(configuration.resolvedShellPath, "/bin/zsh")
    }

    /// 环境只含终端模拟器职责内的最小集合：不继承 GUI App 环境，
    /// 不硬编码 SHELL / PATH（两者由 login / login-shell startup files 建立）。
    /// LANG 只透传调用方注入的系统 locale 派生值——注入刻意非 en_US、
    /// 非本机 locale 的 fr_FR.UTF-8，验证不存在任何固定 locale 硬编码；
    /// 同时断言绝不注入任何 LC_* 变量。
    func testB_EnvironmentContainsOnlyTerminalEssentials() {
        let configuration = LocalShellLauncher.resolve(
            username: "msl",
            home: "/Users/msl",
            accountShell: "/bin/zsh",
            environmentShell: nil,
            lang: "fr_FR.UTF-8",
            isExecutable: executablePaths(["/bin/zsh", "/usr/bin/login"])
        )

        XCTAssertEqual(
            Set(configuration.environment),
            [
                "TERM=xterm-256color",
                "COLORTERM=truecolor",
                "LANG=fr_FR.UTF-8",
                "HOME=/Users/msl",
                "USER=msl",
                "LOGNAME=msl"
            ]
        )
        XCTAssertFalse(
            configuration.environment.contains { $0.hasPrefix("LC_") },
            "不得注入任何 LC_* 变量（尤其 LC_ALL 会覆盖用户 locale 设置）"
        )
        XCTAssertFalse(
            configuration.environment.contains("LANG=en_US.UTF-8"),
            "LANG 不得硬编码为 en_US.UTF-8"
        )
    }

    /// 注入 LANG 为 nil（系统 locale 解析失败）：环境不含 LANG，
    /// 交由系统机制（/etc/zprofile）兜底，绝不回退任何硬编码 locale。
    func testB2_OmitsLANGWhenSystemLocaleUnavailable() {
        let configuration = LocalShellLauncher.resolve(
            username: "msl",
            home: "/Users/msl",
            accountShell: "/bin/zsh",
            environmentShell: nil,
            lang: nil,
            isExecutable: executablePaths(["/bin/zsh", "/usr/bin/login"])
        )

        XCTAssertFalse(
            configuration.environment.contains { $0.hasPrefix("LANG=") },
            "lang 为 nil 时不得编造 LANG 值"
        )
    }

    /// 账户 pw_shell 不可执行：login 使用同一 pw_shell 必然失败，
    /// 回退到环境 SHELL，并携带 accountShellUnusable 原因（不静默）。
    func testC_FallsBackWhenAccountShellUnusable() {
        let configuration = LocalShellLauncher.resolve(
            username: "msl",
            home: "/Users/msl",
            accountShell: "/nonexistent/custom-shell",
            environmentShell: "/bin/bash",
            lang: "fr_FR.UTF-8",
            isExecutable: executablePaths(["/bin/bash", "/usr/bin/login"])
        )

        XCTAssertEqual(configuration.strategy, .directShell(reason: .accountShellUnusable))
        XCTAssertEqual(configuration.executable, "/bin/bash")
        XCTAssertEqual(configuration.execName, "-bash")
        XCTAssertTrue(configuration.args.isEmpty)
        XCTAssertEqual(configuration.resolvedShellPath, "/bin/bash")
    }

    /// /usr/bin/login 不在场（系统异常）：账户 Shell 可用时直接 spawn 它，
    /// 保持 argv[0] 前缀 "-" 的 login shell 语义（Phase 2 行为）。
    func testD_FallsBackWhenSystemLoginUnavailable() {
        let configuration = LocalShellLauncher.resolve(
            username: "msl",
            home: "/Users/msl",
            accountShell: "/bin/zsh",
            environmentShell: nil,
            lang: nil,
            isExecutable: executablePaths(["/bin/zsh"])
        )

        XCTAssertEqual(configuration.strategy, .directShell(reason: .systemLoginUnavailable))
        XCTAssertEqual(configuration.executable, "/bin/zsh")
        XCTAssertEqual(configuration.execName, "-zsh")
        XCTAssertEqual(configuration.resolvedShellPath, "/bin/zsh")
    }

    /// 一切都不可用：最终回退 /bin/sh（execve 失败路径由
    /// failedToStart / exited 安全兜底，不挂死）。
    func testE_UltimateFallbackIsBinSh() {
        let configuration = LocalShellLauncher.resolve(
            username: "msl",
            home: "/Users/msl",
            accountShell: "/nonexistent/shell",
            environmentShell: "/also/nonexistent",
            lang: nil,
            isExecutable: { _ in false }
        )

        XCTAssertEqual(configuration.executable, "/bin/sh")
        XCTAssertEqual(configuration.execName, "-sh")
        XCTAssertEqual(configuration.strategy, .directShell(reason: .accountShellUnusable))
    }

    /// 账户信息不可用时用户名 / Home 回退到 Foundation 等价 API（不 Crash）。
    func testF_FallsBackToFoundationIdentityWithoutAccountRecord() {
        let configuration = LocalShellLauncher.resolve(
            username: "fallback",
            home: "/fallback/home",
            accountShell: nil,
            environmentShell: nil,
            lang: "fr_FR.UTF-8",
            isExecutable: executablePaths(["/bin/zsh", "/usr/bin/login"])
        )

        // 账户 Shell 缺失 → 不走 login（login 同样无 Shell 可用）。
        XCTAssertEqual(configuration.strategy, .directShell(reason: .accountShellUnusable))
        XCTAssertEqual(configuration.currentDirectory, "/fallback/home")
        XCTAssertTrue(configuration.environment.contains("USER=fallback"))
        XCTAssertTrue(configuration.environment.contains("LOGNAME=fallback"))
    }

    /// 生产入口在本机（正常 macOS：账户 Shell 可用 + /usr/bin/login 在场）
    /// 必须选择系统登录链，用户参数与当前账户一致。
    func testG_ProductionConfigurationUsesSystemLoginOnThisMachine() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: LocalShellLauncher.systemLoginPath),
            "本机缺少 /usr/bin/login（非标准 macOS 环境）"
        )
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: LoginShellResolver.resolve()),
            "本机账户 Shell 不可执行"
        )

        let configuration = LocalShellLauncher.makeConfiguration()

        XCTAssertEqual(configuration.strategy, .systemLogin(username: NSUserName()))
        XCTAssertEqual(configuration.executable, "/usr/bin/login")
        XCTAssertEqual(configuration.args, ["-p", "-f", NSUserName()])
        XCTAssertEqual(configuration.currentDirectory, NSHomeDirectory())

        // LANG 必须等于系统 locale 派生值（不断言具体地区，只断言与
        // systemLocaleLANG() 一致），且绝不注入任何 LC_* 变量。
        if let expectedLANG = LocalShellLauncher.systemLocaleLANG() {
            XCTAssertTrue(
                configuration.environment.contains("LANG=\(expectedLANG)"),
                "生产 LANG 必须来自系统 locale 派生（实际环境：\(configuration.environment)）"
            )
        }
        XCTAssertFalse(
            configuration.environment.contains { $0.hasPrefix("LC_") },
            "生产环境不得包含任何 LC_* 变量"
        )
        XCTAssertFalse(
            configuration.environment.contains("LANG=en_US.UTF-8"),
            "生产环境不得硬编码 en_US.UTF-8"
        )
    }

    /// getpwuid_r 账户信息与 Foundation API 一致（name / home）。
    func testH_CurrentAccountMatchesFoundationIdentity() throws {
        let account = try XCTUnwrap(LoginShellResolver.currentAccount())
        XCTAssertEqual(account.name, NSUserName())
        XCTAssertEqual(account.home, NSHomeDirectory())
        XCTAssertFalse(account.shell.isEmpty)
    }

    // MARK: - P3 整改：locale policy（不硬编码任何具体 locale）

    /// POSIX LANG 规范化：@modifier 截断、连字符转下划线、script 段移除、
    /// 数字 territory 保留、非法输入返回 nil（宁可不设置也不猜）。
    func testP_POSIXLANGNormalization() {
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "zh_CN"), "zh_CN.UTF-8")
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "en_US"), "en_US.UTF-8")
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "en_GB"), "en_GB.UTF-8")
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "zh-Hans-CN"), "zh_CN.UTF-8")
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "zh_Hant_TW"), "zh_TW.UTF-8")
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "zh_CN@rg=us"), "zh_CN.UTF-8")
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "es_419"), "es_419.UTF-8")
        XCTAssertEqual(LocalShellLauncher.posixLANG(from: "en"), "en.UTF-8")
        XCTAssertNil(LocalShellLauncher.posixLANG(from: ""))
        XCTAssertNil(LocalShellLauncher.posixLANG(from: "zh_CN;rm -rf"))
        XCTAssertNil(LocalShellLauncher.posixLANG(from: "../../etc"))
        XCTAssertNil(LocalShellLauncher.posixLANG(from: "LANG=$(whoami)"))
    }

    /// Shell locale 来源与 MacSSH UI 语言（AppLanguage）完全解耦：
    /// 切换 App 语言偏好不得改变 systemLocaleLANG() 的取值。
    func testQ_ShellLocaleDecoupledFromAppLanguage() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: AppPreferenceKey.language)
        defer {
            if let original {
                defaults.set(original, forKey: AppPreferenceKey.language)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.language)
            }
        }

        let baseline = LocalShellLauncher.systemLocaleLANG()
        AppLanguage.english.save(to: defaults)
        XCTAssertEqual(
            LocalShellLauncher.systemLocaleLANG(), baseline,
            "切换 App UI 语言为 English 不得改变 shell locale policy"
        )
        AppLanguage.simplifiedChinese.save(to: defaults)
        XCTAssertEqual(
            LocalShellLauncher.systemLocaleLANG(), baseline,
            "切换 App UI 语言为简体中文不得改变 shell locale policy"
        )
    }

    /// 本机 systemLocaleLANG() 必须能解析出非空值（标准 macOS 环境），
    /// 且格式为 POSIX `<lang>[_TERRITORY].UTF-8`；值由系统设置决定，
    /// 本测试不绑定任何具体地区。
    func testR_SystemLocaleLANGWellFormedOnThisMachine() {
        let lang = LocalShellLauncher.systemLocaleLANG()
        XCTAssertNotNil(lang, "标准 macOS 环境必须能解析系统 locale")
        guard let lang else {
            return
        }
        XCTAssertTrue(lang.hasSuffix(".UTF-8"), "LANG 必须是 UTF-8 locale（实际：\(lang)）")
        let localePart = String(lang.dropLast(".UTF-8".count))
        XCTAssertFalse(localePart.contains("-"), "locale 部分不得含连字符（实际：\(lang)）")
        XCTAssertFalse(localePart.contains("@"), "locale 部分不得含 modifier（实际：\(lang)）")
    }

    // MARK: - 真实集成：登录链语义（任务书 63）

    /// 真实 forkpty + login 链：interactive login shell、真实 TTY、
    /// SHELL / HOME / USER / LOGNAME / TERM / COLORTERM / cwd 全部正确，
    /// shell 父进程是系统 login（与 Terminal.app 同构）。
    func testI_RealLoginChainInteractiveLoginShellSemantics() async throws {
        let service = try await startAndWaitForReady()
        let accountShell = LoginShellResolver.resolve()
        let shellName = URL(fileURLWithPath: accountShell).lastPathComponent

        // 每个字段独立 echo 一行（短行不折行），整条一次发送。
        let probe = [
            "echo \"L3A_LOGIN=$([[ -o login ]] && echo YES || echo NO)\"",
            "echo \"L3A_INT=$([[ -o interactive ]] && echo YES || echo NO)\"",
            "echo \"L3A_SHELL=$SHELL\"",
            "echo \"L3A_ARGV0=$0\"",
            "echo \"L3A_TTY=$(tty)\"",
            "echo \"L3A_HOME=$HOME\"",
            "echo \"L3A_USER=$USER\"",
            "echo \"L3A_LOGNAME=$LOGNAME\"",
            "echo \"L3A_TERM=$TERM\"",
            "echo \"L3A_COLORTERM=$COLORTERM\"",
            "echo \"L3A_LANG=[$LANG]\"",
            "echo \"L3A_LC_ALL=[$LC_ALL]\"",
            "echo \"L3A_PWD=$PWD\"",
            "echo \"L3A_PPCMD=$(ps -o command= -p $PPID)\""
        ].joined(separator: "; ")
        service.terminalView.send(txt: probe + "\r")

        // 顺序执行：等最后一个字段的输出行（排除含 "$" 的命令回显行）。
        _ = try await waitForOutputLine(service, key: "L3A_PPCMD=", timeout: 20)
        let buffer = bufferText(of: service)

        func output(_ key: String) -> String {
            Self.outputLine(buffer, key: key) ?? "<missing \(key)>"
        }

        // Shell login / interactive 语义（任务书 12）。
        XCTAssertEqual(output("L3A_LOGIN="), "L3A_LOGIN=YES", "必须是 login shell")
        XCTAssertEqual(output("L3A_INT="), "L3A_INT=YES", "必须是 interactive shell")

        // 身份与环境（任务书 22~27）。
        XCTAssertEqual(output("L3A_SHELL="), "L3A_SHELL=\(accountShell)", "SHELL 必须是账户默认 Shell")
        XCTAssertEqual(output("L3A_ARGV0="), "L3A_ARGV0=-\(shellName)", "argv[0] 必须带 login 前缀")
        XCTAssertTrue(output("L3A_TTY=").hasPrefix("L3A_TTY=/dev/ttys"), "必须持有真实 PTY（前缀断言，不锁编号）")
        XCTAssertEqual(output("L3A_HOME="), "L3A_HOME=\(NSHomeDirectory())", "HOME 必须是账户 Home")
        XCTAssertEqual(output("L3A_USER="), "L3A_USER=\(NSUserName())", "USER 必须是当前账户")
        XCTAssertEqual(output("L3A_LOGNAME="), "L3A_LOGNAME=\(NSUserName())", "LOGNAME 必须是当前账户")
        XCTAssertEqual(output("L3A_TERM="), "L3A_TERM=xterm-256color", "TERM 保持安全基线")
        XCTAssertEqual(output("L3A_COLORTERM="), "L3A_COLORTERM=truecolor", "COLORTERM 不得被登录链清掉")

        // P3 整改：真实 login 链内 LANG 必须等于系统 locale 派生值
        //（不绑定具体地区；/etc/zprofile 对空 LANG 兜底 C.UTF-8，
        // 若实测为 C.UTF-8 说明派生值未传入），且 LC_ALL 必须为空。
        if let expectedLANG = LocalShellLauncher.systemLocaleLANG() {
            XCTAssertEqual(
                output("L3A_LANG="), "L3A_LANG=[\(expectedLANG)]",
                "login 链内 LANG 必须等于系统 locale 派生值，不得为 C.UTF-8 兜底或硬编码"
            )
        }
        XCTAssertEqual(output("L3A_LC_ALL="), "L3A_LC_ALL=[]", "不得设置 LC_ALL 覆盖用户 locale")

        // 初始 cwd 是用户 HOME（任务书 18）。
        XCTAssertEqual(output("L3A_PWD="), "L3A_PWD=\(NSHomeDirectory())", "初始 cwd 必须是 HOME")

        // 登录链父进程（任务书 75：真实 process tree 证据）。
        if case .systemLogin = LocalShellLauncher.makeConfiguration().strategy {
            XCTAssertTrue(
                output("L3A_PPCMD=").contains("login"),
                "systemLogin 策略下 shell 父进程必须是 /usr/bin login（实际：\(output("L3A_PPCMD="))）"
            )
        }
    }

    /// PATH 由 login + login-shell startup files 自然建立（任务书 23/24）：
    /// 在 shell 内做路径元素判断（避免长 PATH 折行），断言语义而非字符串。
    func testJ_LoginShellPathEstablishedByStartupFiles() async throws {
        let service = try await startAndWaitForReady()

        let probe = "echo \"L3B_USRBIN=$(case \":$PATH:\" in *:/usr/bin:*) echo YES;; *) echo NO;; esac)\"; "
            + "echo \"L3B_BIN=$(case \":$PATH:\" in *:/bin:*) echo YES;; *) echo NO;; esac)\""
        service.terminalView.send(txt: probe + "\r")

        // path_helper（/etc/zprofile）保证系统路径在场；用户 dotfiles
        // （Homebrew 等）追加与否属于用户环境，不做硬断言。
        let usrBinLine = try await waitForOutputLine(service, key: "L3B_USRBIN=", timeout: 20)
        let binLine = try await waitForOutputLine(service, key: "L3B_BIN=", timeout: 20)
        XCTAssertEqual(usrBinLine, "L3B_USRBIN=YES", "login shell PATH 必须包含 /usr/bin")
        XCTAssertEqual(binLine, "L3B_BIN=YES", "login shell PATH 必须包含 /bin")
    }

    /// cd 后 cwd 保持：同一 Shell 持续运行（任务书 31 的 shell 层面证据）。
    func testK_SessionPreservesCwdAcrossCommands() async throws {
        let service = try await startAndWaitForReady()

        service.terminalView.send(txt: "cd /tmp; echo \"L3C_MOVED=$PWD\"\r")
        let first = try await waitForBuffer(service, marker: "L3C_MOVED=/tmp", timeout: 20)
        XCTAssertTrue(first.contains("L3C_MOVED=/tmp"))

        service.terminalView.send(txt: "echo \"L3C_STILL=$PWD\"\r")
        let second = try await waitForBuffer(service, marker: "L3C_STILL=/tmp", timeout: 20)
        XCTAssertTrue(second.contains("L3C_STILL=/tmp"), "同一 Shell 的 cwd 必须保持")
        XCTAssertTrue(second.contains("L3C_MOVED=/tmp"), "screen buffer 不得被清除")
    }

    /// 用户 exit：login 进程随之退出并传播到 UI（任务书 51），
    /// 不留孤儿 login 进程。
    func testL_ShellExitPropagatesAndReapsLoginProcess() async throws {
        let service = try await startAndWaitForReady()
        let loginPID = service.terminalView.process.shellPid
        XCTAssertGreaterThan(loginPID, 0)

        service.terminalView.send(txt: "exit\r")
        let exited = try await waitForCondition(timeout: 15) {
            if case .exited = service.session.processState { return true }
            return false
        }
        XCTAssertTrue(exited, "exit 后必须进入 exited（当前 \(service.session.statusText)）")

        // login 进程必须被回收（kill 探测 ESRCH；无僵尸 / 孤儿）。
        let reaped = try await waitForCondition(timeout: 5) {
            kill(loginPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertTrue(reaped, "login 进程必须退出并被回收（pid \(loginPID)）")
    }

    /// MacSSH 主动 terminate：登录链整链退出（master 关闭 → SIGHUP →
    /// shell → login），无孤儿进程（任务书 49/50 的单次验证）。
    func testM_TerminateTearsDownEntireLoginChain() async throws {
        let service = try await startAndWaitForReady()
        let loginPID = service.terminalView.process.shellPid
        XCTAssertGreaterThan(loginPID, 0)

        service.terminate()
        let exited = try await waitForCondition(timeout: 15) {
            if case .exited = service.session.processState { return true }
            return false
        }
        XCTAssertTrue(exited, "terminate 后必须收敛到 exited")

        let reaped = try await waitForCondition(timeout: 5) {
            kill(loginPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertTrue(reaped, "terminate 后 login 进程不得残留（pid \(loginPID)）")
    }

    /// 50× 创建 / 启动 / 关闭（任务书 49）：每轮子进程退出、
    /// FD 不持续增长、无僵尸 login。
    func testN_FiftyCreateTerminateCyclesLeaveNoOrphan() async throws {
        let fdBefore = probeFileDescriptor()

        for cycle in 1...50 {
            let service = LocalTerminalService(
                session: TerminalSession(shellPath: LoginShellResolver.resolve())
            )
            services.append(service)
            service.startIfNeeded()
            XCTAssertEqual(
                service.session.processState, .running,
                "第 \(cycle) 轮：Shell 必须启动"
            )
            let loginPID = service.terminalView.process.shellPid
            XCTAssertGreaterThan(loginPID, 0, "第 \(cycle) 轮：必须拿到子进程 PID")

            service.terminate()
            let exited = try await waitForCondition(timeout: 15) {
                if case .exited = service.session.processState { return true }
                return false
            }
            XCTAssertTrue(exited, "第 \(cycle) 轮：terminate 后必须 exited")
            services.removeAll { $0 === service }

            let reaped = try await waitForCondition(timeout: 5) {
                kill(loginPID, 0) == -1 && errno == ESRCH
            }
            XCTAssertTrue(reaped, "第 \(cycle) 轮：login 进程不得残留（pid \(loginPID)）")
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let fdAfter = probeFileDescriptor()
        XCTAssertLessThanOrEqual(
            fdAfter - fdBefore,
            2,
            "50 轮后 PTY FD 不应持续增长（before=\(fdBefore), after=\(fdAfter)）"
        )
    }

    /// exec 失败（可执行文件不存在）：安全失败不挂死（任务书 52）。
    /// 子进程 execve 失败后 _exit(127)，退出事件异步到达——
    /// 断言收敛到非 running 而非同步状态。
    func testO_ExecFailureSurfacesWithoutHanging() async throws {
        let view = LocalProcessTerminalView(
            frame: .zero,
            font: TerminalFontProvider.regularFont(),
            options: TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 100)
        )

        view.startProcess(executable: "/definitely/not/a/program")
        let settled = try await waitForCondition(timeout: 5) {
            !view.process.running
        }
        XCTAssertTrue(settled, "exec 失败必须收敛到非 running（不得挂死）")
        view.terminate()
    }

    // MARK: - 辅助

    private func executablePaths(_ paths: [String]) -> (String) -> Bool {
        { paths.contains($0) }
    }

    /// 启动真实 Local Terminal 并等待 Shell 就绪（首屏输出到达）。
    private func startAndWaitForReady(timeout: TimeInterval = 15) async throws -> LocalTerminalService {
        let service = LocalTerminalService(
            session: TerminalSession(shellPath: LoginShellResolver.resolve())
        )
        services.append(service)
        service.startIfNeeded()

        let running = try await waitForCondition(timeout: timeout) {
            service.session.processState == .running
        }
        XCTAssertTrue(running, "Local Terminal 必须进入 running")

        // 等待 login / shell 首屏输出（Last login、prompt 等），
        // 避免命令早于 shell 就绪被丢弃。
        let ready = try await waitForCondition(timeout: timeout) {
            !self.bufferText(of: service).isEmpty
        }
        XCTAssertTrue(ready, "Shell 必须产生首屏输出")
        try await Task.sleep(nanoseconds: 500_000_000)
        return service
    }

    /// SwiftTerm normal buffer（含 scrollback）全文。
    private func bufferText(of service: LocalTerminalService) -> String {
        guard let terminal = service.terminalView.terminal else {
            return ""
        }
        let data = terminal.getBufferAsData(kind: .normal)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 轮询 buffer 直到出现 marker；返回当时的全文。
    private func waitForBuffer(
        _ service: LocalTerminalService,
        marker: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = bufferText(of: service)
            if text.contains(marker) {
                return text
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("在 \(timeout)s 内未在 buffer 中观察到 \(marker)")
        return bufferText(of: service)
    }

    /// 提取 "KEY=value" 的真实输出行：命令回显行包含未展开的 "$VAR"，
    /// 据此排除（marker 只可能由展开后的输出产生）。
    private static func outputLine(_ buffer: String, key: String) -> String? {
        buffer
            .split(separator: "\n")
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .first { $0.contains(key) && !$0.contains("$") }
    }

    /// 轮询 buffer 直到 "KEY=" 的真实输出行出现；返回该行。
    private func waitForOutputLine(
        _ service: LocalTerminalService,
        key: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = Self.outputLine(bufferText(of: service), key: key) {
                return line
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("在 \(timeout)s 内未观察到 \(key) 的输出行")
        return ""
    }

    private func waitForCondition(
        timeout: TimeInterval,
        where predicate: () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return await predicate()
    }

    /// 通过打开 /dev/null 探测当前 FD 高位值，用于泄漏检测。
    private func probeFileDescriptor() -> Int32 {
        let fd = open("/dev/null", O_RDONLY)
        if fd >= 0 {
            close(fd)
        }
        return fd
    }
}
