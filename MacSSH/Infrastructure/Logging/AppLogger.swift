import Foundation
import OSLog

/// 统一管理应用日志分类，避免业务代码自行构造 Logger。
enum AppLogger {
    /// Bundle Identifier 在测试环境缺失时使用稳定的非敏感回退值。
    private static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "com.macssh.MacSSH"
    }

    /// 应用生命周期和非敏感 UI 状态日志。
    static let app = Logger(subsystem: subsystem, category: "App")

    /// 本地 Terminal 生命周期日志；禁止写入命令、输出或环境变量。
    static let terminal = Logger(subsystem: subsystem, category: "Terminal")

    /// SwiftData 操作日志；禁止写入 Host 名称、地址、用户名或备注。
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")

    /// Keychain 生命周期日志；禁止写入 Password、Passphrase、Private Key 或 Secret Data。
    static let security = Logger(subsystem: subsystem, category: "Security")
}
