import Foundation

// MARK: - Terminal Mutation 语义分界（Phase 10F-A 冻结；本文件 B1 只含 identity 契约）

/// Interactive terminal mutation 与 command execution（run_command）是**两类
/// 不可互换的操作**（10F-A 冻结语义表）：
///
/// - command execution：独立进程 / 独立 SSH exec channel、非交互、
///   不改变当前 interactive shell 状态、捕获 stdout/stderr；
/// - interactive terminal mutation：寻址**一个已存在的具体交互终端
///   incarnation**、直接改变当前 shell / 程序输入状态、不捕获输出、
///   可能永久改变 cwd / env / shell / program 状态。
///
/// B1 的任何 API 都不允许把两者表达成可互换形态；transport / Provider
/// 注册属 B2/B3/B4，本阶段零交付、零注入。

// MARK: - Epoch（任务书 §10）

/// `inputTargetEpoch` 的窄类型：opaque 单调递增的 endpoint 实例代次。
///
/// 每当具体输入 endpoint 被替换（Local PTY/process incarnation 更换、
/// Remote connection+shell channel 组合任一重建、重连），epoch 必须 +1。
/// B1 只定义并测试 immutable identity 契约，不实现 Local/Remote 生命周期
/// （B2/B3 落地时由 terminal service 层维护 epoch 注册表）。
typealias AgentTerminalInputTargetEpoch = UInt64

// MARK: - Endpoint Token（任务书 §11）

/// opaque 非 secret 的 endpoint capability token。
///
/// - 由应用侧生成（UUID），**Provider 永远不能提供或选择**；
/// - 不是指针、不是文件描述符、不是主机名、不是任何 UI 对象身份；
/// - 不承载任何 secret；诊断只允许短前缀形态（`shortDescription`）。
struct AgentTerminalEndpointToken: Sendable, Hashable {
    let rawValue: UUID

    /// 应用侧生成唯一 token；本类型无 public 可注入构造入口，
    /// 结构上排除 Provider / 外部调用方指定 token 的通道。
    static func generate() -> AgentTerminalEndpointToken {
        AgentTerminalEndpointToken(rawValue: UUID())
    }

    /// 测试 / 受控构造入口（模块内）。
    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// 诊断用短前缀（非 secret，仅前 8 个 hex 字符）。
    var shortDescription: String {
        String(rawValue.uuidString.prefix(8))
    }
}

// MARK: - Target Identity（10F-A-R1 §R1.6 冻结的 incarnation 绑定）

/// 一次 interactive terminal mutation 的**授权目标身份**。
///
/// `ManagedTerminalSession.id`（logicalSessionID）只是 logical / UI 身份，
/// **不足以作为授权身份**（10F-A-R1 §R1.6 冻结）；完整授权身份必须
/// 三元绑定：
///
/// - `logicalSessionID`：稳定的 UI / session 身份；
/// - `inputTargetEpoch`：一个具体输入 endpoint incarnation 的代次；
/// - `endpointToken`：具体 endpoint capability 的 opaque 身份。
///
/// 只接受 sessionID 相等 = 结构性禁止（stale 语义见 coordinator）。
/// 无任何 raw pointer：endpoint 对象强引用由未来 B2/B3 的
/// `TerminalMutationEndpoint` capability 持有，本值类型只承载身份。
struct AgentTerminalInputTargetIdentity: Sendable, Equatable, Hashable {
    let logicalSessionID: UUID
    let inputTargetEpoch: AgentTerminalInputTargetEpoch
    let endpointToken: AgentTerminalEndpointToken
}

extension AgentTerminalInputTargetIdentity: CustomStringConvertible, CustomDebugStringConvertible {
    /// redacted：只含 logical session 与 epoch，token 只出短前缀。
    var description: String {
        "AgentTerminalInputTargetIdentity(logicalSessionID: \(logicalSessionID.uuidString), "
            + "inputTargetEpoch: \(inputTargetEpoch), "
            + "endpointToken: \(endpointToken.shortDescription)…)"
    }

    var debugDescription: String { description }
}
