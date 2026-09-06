import Foundation

/// Local Terminal 的启动配置（MacSSH 1.1 Phase 3：macOS 原生登录语义）。
///
/// 配置只描述"如何启动 PTY 子进程"，不执行任何进程操作；
/// 由 `LocalTerminalService` 交给 SwiftTerm `LocalProcessTerminalView`。
struct LocalShellLaunchConfiguration: Equatable {
    /// 启动策略。
    enum Strategy: Equatable {
        /// 系统登录链：`/usr/bin/login -p -f <user>` → 账户默认 login shell。
        ///
        /// 与 Terminal.app "Shells open with: Default login shell" 同构：
        /// - login（setuid root）负责打印系统 `Last login`、更新 utmpx、
        ///   补齐 HOME / SHELL / PATH / USER / LOGNAME；
        /// - 账户 shell 以 argv[0] 前缀 "-" 启动（interactive login shell），
        ///   自行按正确顺序读取 /etc/zprofile → ~/.zprofile → ~/.zshrc；
        /// - `~/.hushlogin` 等抑制行为完全由系统 login 决定，MacSSH 不干预。
        case systemLogin(username: String)

        /// 直接 spawn 账户 Shell（argv[0] 前缀 "-"，Phase 2 既有行为）。
        /// 仅在登录链不可用时回退，绝不静默替换 Shell（OSLog 记录原因）。
        case directShell(reason: DirectShellReason)
    }

    /// directShell 回退原因（诊断用；不含用户名 / 路径等环境细节）。
    enum DirectShellReason: Equatable {
        /// 账户 pw_shell 缺失或不可执行：login 使用同一 pw_shell 必然
        /// 同样失败，因此回退到 LoginShellResolver 的安全回退顺序。
        case accountShellUnusable
        /// /usr/bin/login 不存在或不可执行（系统异常）。
        case systemLoginUnavailable
    }

    /// PTY 子进程可执行文件（forkpty + execve 目标）。
    let executable: String

    /// execve argv[1...]（不含 argv[0]）。
    let args: [String]

    /// argv[0]；nil 表示使用 executable 本身。带前缀 "-" 表示 login shell。
    let execName: String?

    /// 完整替换子进程环境的 "K=V" 数组（不继承 GUI App 进程环境；
    /// login 链下由系统 login 在此基础上补齐 SHELL / PATH）。
    let environment: [String]

    /// 子进程初始工作目录（用户 HOME）。
    let currentDirectory: String

    /// 本次解析出的账户 Shell 路径（回退时为实际回退 Shell），
    /// 仅用于 OSLog 诊断，绝不静默换 Shell。
    let resolvedShellPath: String

    let strategy: Strategy
}

/// Phase 3 启动策略：Local Terminal 尽可能复用 macOS 原生登录链。
///
/// 决策依据（本机实证 + login(1) man page，详见 DevelopmentStatus.md Phase 3）：
/// - Terminal.app 默认链为 `Terminal → (root) login -pf <user> → -zsh`；
/// - `/usr/bin/login` 为 setuid root，man page 明确 `-f` 允许
///   "an already logged in user is logging in as themselves"，
///   MacSSH 以普通 GUI 用户身份执行完全合法，无需任何特权 hack；
/// - `Last login` 行由 login 读取 lastlog 打印并更新 utmpx，
///   MacSSH 绝不伪造或抑制（包括 ~/.hushlogin 语义）。
enum LocalShellLauncher {
    /// macOS 系统登录工具路径。
    static let systemLoginPath = "/usr/bin/login"

    /// 生产入口：读取当前账户与文件系统状态，决定启动链。
    static func makeConfiguration() -> LocalShellLaunchConfiguration {
        let account = LoginShellResolver.currentAccount()
        return resolve(
            username: account?.name ?? NSUserName(),
            home: account?.home ?? NSHomeDirectory(),
            accountShell: account?.shell,
            environmentShell: ProcessInfo.processInfo.environment["SHELL"],
            lang: systemLocaleLANG(),
            pasteHighlightEnabled: UserDefaults.standard.bool(forKey: AppPreferenceKey.pasteHighlightEnabled),
            zshIntegrationDirectory: Bundle.main.url(forResource: "ShellIntegration", withExtension: nil)?.path,
            isExecutable: { path in
                path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
            }
        )
    }

    /// 系统登录环境的 LANG 值（与 Terminal.app "Set locale environment
    /// variables on startup" 同构：只设置 LANG，绝不设置任何 LC_*）。
    ///
    /// 来源优先级：NSGlobalDomain `AppleLocale`（系统"语言与地区"设置，
    /// 不受 App 域偏好影响）→ `Locale.current`。与 MacSSH UI 语言
    /// （`AppLanguage`，仅写自有 `appLanguage` key）完全解耦。
    /// 解析失败时不设置 LANG（由 /etc/zprofile 等系统机制兜底），
    /// 绝不硬编码任何具体 locale。
    ///
    /// 必须主动设置的原因（实测）：/usr/bin/login 本身不设置 LANG；
    /// macOS /etc/zprofile 对空 LANG 统一兜底 `C.UTF-8`，不会推导
    /// 系统 locale——不显式设置则与 Terminal.app 的 zh_CN.UTF-8 等
    /// 原生行为不一致。
    static func systemLocaleLANG() -> String? {
        let globalDomain = UserDefaults.standard.persistentDomain(
            forName: UserDefaults.globalDomain
        )
        let rawIdentifier = (globalDomain?["AppleLocale"] as? String)
            ?? Locale.current.identifier
        return posixLANG(from: rawIdentifier)
    }

    /// 把 macOS locale identifier 规范化为 POSIX LANG 值（附加 `.UTF-8`）。
    ///
    /// 清洗规则：`@modifier` 截断；`-` → `_`；POSIX 无 script 段，
    /// 三段式（如 `zh_Hans_CN`）取 `language_TERRITORY`；
    /// 仅接受字母/数字/下划线，其余一律返回 nil（宁可不设置也不猜）。
    static func posixLANG(from identifier: String) -> String? {
        var value = identifier
        if let modifierIndex = value.firstIndex(of: "@") {
            value = String(value[..<modifierIndex])
        }
        value = value.replacingOccurrences(of: "-", with: "_")
        // 先整串校验：只允许 locale 合法字符（字母/数字/下划线），
        // 任何其他字符（空格、分号、路径分隔符等）直接拒绝——
        // 必须在分段之前校验，避免非法段被丢弃后逃逸。
        guard !value.isEmpty,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else {
            return nil
        }
        let parts = value.split(separator: "_").map(String.init)
        let normalized: String
        switch parts.count {
        case 0:
            return nil
        case 1:
            normalized = parts[0]
        case 2:
            normalized = "\(parts[0])_\(parts[1])"
        default:
            normalized = "\(parts[0])_\(parts[parts.count - 1])"
        }
        guard !normalized.isEmpty else {
            return nil
        }
        return "\(normalized).UTF-8"
    }

    /// 纯决策函数（测试注入账户、文件系统状态与 LANG 值）。
    ///
    /// 环境策略：只传终端模拟器职责内的最小集合
    /// （TERM / COLORTERM / HOME / USER / LOGNAME，及系统 locale 派生
    /// 的 LANG），不复制 GUI App 进程环境；SHELL 与 PATH 由 login
    /// （或回退路径下的 login-shell startup files）建立，
    /// MacSSH 不硬编码任何用户环境；绝不设置任何 LC_* 变量。
    static func resolve(
        username: String,
        home: String,
        accountShell: String?,
        environmentShell: String?,
        lang: String?,
        pasteHighlightEnabled: Bool = true,
        zshIntegrationDirectory: String? = nil,
        isExecutable: (String) -> Bool
    ) -> LocalShellLaunchConfiguration {
        let accountShellIsUsable = accountShell.map(isExecutable) ?? false

        // 回退顺序与 LoginShellResolver 一致：账户 Shell → 环境 SHELL →
        // 系统默认（仅处理异常账户配置，正常启动始终用 pw_shell）。
        let fallbackShell: String
        if let accountShell, isExecutable(accountShell) {
            fallbackShell = accountShell
        } else if let environmentShell, isExecutable(environmentShell) {
            fallbackShell = environmentShell
        } else {
            fallbackShell = ["/bin/zsh", "/bin/bash"].first(where: isExecutable) ?? "/bin/sh"
        }

        var environment = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "HOME=\(home)",
            "USER=\(username)",
            "LOGNAME=\(username)"
        ]
        // LANG 仅来自系统 locale 派生值（调用方注入）；为 nil 时不设置，
        // 绝不回退到任何硬编码 locale。
        if let lang {
            environment.append("LANG=\(lang)")
        }

        // 仅关闭本地 zsh 的 paste 高亮；开启时完整保留 Shell 原生配置。
        // Bundle 内的代理按原顺序读取用户配置并恢复 ZDOTDIR，不改写用户文件。
        // 不触碰 bracketed paste、ZLE widget 或 SSH 的环境/数据通路。
        if !pasteHighlightEnabled,
           URL(fileURLWithPath: fallbackShell).lastPathComponent == "zsh",
           let zshIntegrationDirectory {
            environment.append("ZDOTDIR=\(zshIntegrationDirectory)")
        }

        // 账户 Shell 可用且系统 login 在场 → 原生登录链。
        // argv 与 Terminal.app 实证一致：login -p -f <user>（-l 会禁用
        // login shell 语义，绝不使用）。
        if accountShellIsUsable, isExecutable(systemLoginPath) {
            return LocalShellLaunchConfiguration(
                executable: systemLoginPath,
                args: ["-p", "-f", username],
                execName: nil,
                environment: environment,
                currentDirectory: home,
                resolvedShellPath: fallbackShell,
                strategy: .systemLogin(username: username)
            )
        }

        // 回退：login 链不可用（账户 Shell 异常或 login 缺失），
        // 直接 spawn 回退 Shell，保持 Phase 2 的 argv[0] login 语义。
        let reason: LocalShellLaunchConfiguration.DirectShellReason = accountShellIsUsable
            ? .systemLoginUnavailable
            : .accountShellUnusable
        return LocalShellLaunchConfiguration(
            executable: fallbackShell,
            args: [],
            execName: "-\(URL(fileURLWithPath: fallbackShell).lastPathComponent)",
            environment: environment,
            currentDirectory: home,
            resolvedShellPath: fallbackShell,
            strategy: .directShell(reason: reason)
        )
    }
}
