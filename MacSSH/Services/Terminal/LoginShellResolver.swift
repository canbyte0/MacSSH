import Darwin
import Foundation

/// 当前 macOS 账户信息（getpwuid_r 读取；Phase 3 供启动链决策使用）。
struct AccountContext: Equatable {
    /// 账户名（pw_name；`login -f` 的目标用户参数）。
    let name: String

    /// 账户 Home 目录（pw_dir；子进程初始工作目录）。
    let home: String

    /// 账户配置的登录 Shell（pw_shell 原始值，未经可用性校验）。
    let shell: String
}

/// 从当前 macOS 账户配置读取 login shell，避免把 `/bin/zsh` 写死为正常路径。
enum LoginShellResolver {
    /// 返回可执行的账户 Shell；系统账户信息不可用时才使用安全回退顺序。
    static func resolve() -> String {
        if let accountShell = accountShell(), isUsableShell(accountShell) {
            return accountShell
        }

        if let environmentShell = ProcessInfo.processInfo.environment["SHELL"],
           isUsableShell(environmentShell) {
            return environmentShell
        }

        // 回退只处理异常账户配置；正常启动始终优先使用系统账户中的 pw_shell。
        return ["/bin/zsh", "/bin/bash"].first(where: isUsableShell) ?? "/bin/sh"
    }

    /// 当前用户的完整账户信息（Phase 3：LocalShellLauncher 需要
    /// username / home / 原始 pw_shell 构造登录启动链）。
    /// 账户信息不可用时返回 nil，由调用方回退到 Foundation 等价 API。
    static func currentAccount() -> AccountContext? {
        let suggestedBufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = suggestedBufferSize > 0 ? Int(suggestedBufferSize) : 16_384
        var passwordRecord = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = buffer.withUnsafeMutableBufferPointer { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                return Int32(EINVAL)
            }

            return getpwuid_r(
                getuid(),
                &passwordRecord,
                baseAddress,
                bufferPointer.count,
                &result
            )
        }

        guard status == 0, result != nil else {
            return nil
        }

        guard let name = passwordRecord.pw_name.map({ String(cString: $0) }),
              let home = passwordRecord.pw_dir.map({ String(cString: $0) }),
              let shell = passwordRecord.pw_shell.map({ String(cString: $0) })
        else {
            return nil
        }

        return AccountContext(name: name, home: home, shell: shell)
    }

    private static func accountShell() -> String? {
        currentAccount()?.shell
    }

    /// 只接受绝对路径且当前用户可执行的 Shell。
    private static func isUsableShell(_ path: String) -> Bool {
        path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
    }
}
