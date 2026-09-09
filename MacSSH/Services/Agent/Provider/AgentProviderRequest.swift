import Foundation

/// MacSSH 1.1 Phase 10C：单次请求的不可变配置快照（任务书 §25）。
///
/// 请求启动时刻解析一次（Settings 与 Keychain 各读一次）；整个请求
/// 生命周期内不变。streaming 过程中用户修改 Settings / 删除 API Key
/// 只影响下一次请求（任务书 §26）。
///
/// ⚠️ `apiKey` 是 Secret：绝不写入日志、error message、UserDefaults、
/// 测试输出或报告（任务书 §11 / §21 / §48）。因此本类型刻意不实现
/// Equatable / CustomStringConvertible，避免被意外断言或打印。
struct AgentProviderRequest: Sendable {
    let model: String
    let baseURL: URL
    let apiKey: String
}
