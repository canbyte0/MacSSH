import Darwin
import Foundation

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

    /// 使用线程安全的 getpwuid_r 读取当前用户的 pw_shell。
    private static func accountShell() -> String? {
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

        return String(cString: passwordRecord.pw_shell)
    }

    /// 只接受绝对路径且当前用户可执行的 Shell。
    private static func isUsableShell(_ path: String) -> Bool {
        path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
    }
}
