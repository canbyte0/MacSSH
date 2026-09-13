import Darwin
import Foundation

/// Local 子进程环境（10E-A §21/§24 冻结 allowlist）。
///
/// **绝不透传 `ProcessInfo.processInfo.environment`**（§23）：本构造
/// 只显式组装冻结键集合，任何 IDE / 调试注入变量（含潜在 secret、
/// CI token、Provider 凭据）都没有进入子进程的路径。
///
/// | 变量 | 来源 | 冻结理由 |
/// |---|---|---|
/// | `HOME` / `USER` / `LOGNAME` / `SHELL` | `getpwuid_r` 账户信息 | `~` 展开、脚本惯例、`$SHELL` 一致性 |
/// | `PATH` | App 固定值 | 非 login shell 的 PATH 局限由显式值解决；绝不继承 GUI App PATH |
/// | `LANG` | `en_US.UTF-8` 固定值 | 确定性输出排序 / 解码；不透传 App locale |
/// | `TERM` | `dumb` | 明确非交互语义，抑制 pager / color |
/// | `TMPDIR` | `confstr(_CS_DARWIN_USER_TEMP_DIR)` | 脚本普遍需要；不读取继承环境（避免被上游环境改写） |
enum AgentLocalCommandEnvironment {
    /// App 固定 PATH（10E-A §21 逐字冻结值）。
    static let fixedPATH =
        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// 固定 LANG（不设置任何 `LC_*`，与 Terminal 启动链一致）。
    static let fixedLANG = "en_US.UTF-8"
    /// 固定 TERM（非交互语义）。
    static let fixedTERM = "dumb"

    /// 构造 allowlist 环境（键集合恒定，未知变量一律不存在）。
    static func makeEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        if let account = LoginShellResolver.currentAccount() {
            environment["HOME"] = account.home
            environment["USER"] = account.name
            environment["LOGNAME"] = account.name
            environment["SHELL"] = account.shell
        }
        environment["PATH"] = fixedPATH
        environment["LANG"] = fixedLANG
        environment["TERM"] = fixedTERM
        if let temporaryDirectory = darwinUserTempDirectory() {
            environment["TMPDIR"] = temporaryDirectory
        }
        return environment
    }

    /// App 进程的 darwin user temp dir（`confstr` 系统值，不读取进程环境）。
    static func darwinUserTempDirectory() -> String? {
        let requiredSize = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard requiredSize > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: requiredSize)
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, requiredSize)
        guard written > 1 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
