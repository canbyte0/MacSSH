import Foundation

/// MacSSH 1.1 Phase 10C：失败消息的 UI 展示分类（任务书 §20 / §36）。
///
/// 与底层错误解耦：`AgentProviderError.displayKind` 是
/// 「Provider 内部错误 → 展示分类」的唯一映射点；View 层再按分类
/// 取 agent.provider.error.* 本地化文案。
enum AgentFailureKind: Sendable, Equatable {
    case missingCredential
    case authentication
    case forbidden
    case rateLimited
    case server
    case network
    case invalidResponse
    /// 回复在完成前被服务端标记为 incomplete（如长度上限截断）。
    /// MacSSH 1.1 Phase 10C-D：DeepSeek `response.incomplete` 结构化分类。
    case incomplete
    /// B4 §26：工具轮次达到 hard cap（10）后模型仍请求工具，
    /// generation 被结构化终止。
    case toolRoundLimit
    /// B4 §28/§43：执行工具时目标终端会话已不可用（关闭 / 断开）——
    /// 无法继续的错误，generation 安全收尾。
    case sessionUnavailable
    case generic
}

/// MacSSH 1.1 Phase 10C：结构化 Provider 错误（任务书 §20）。
///
/// 内部必须结构化分类（禁止全部收敛成 "Unable to generate response"），
/// UI 层经 localization 映射为用户可理解文案。
/// 错误绝不携带 API Key、Authorization header 或完整对话内容
/// （任务书 §21 / §22 hard gate）。
enum AgentProviderError: Error, Sendable, Equatable {
    /// API Key 未配置——不得伪装成 generic network error（任务书 §15）。
    case missingCredential
    /// Base URL 非法（非 URL / scheme 非 http/https / 无法拼接 endpoint）。
    case invalidBaseURL
    /// 底层传输失败（连接失败、DNS、空闲超时等）。
    /// 关联值仅为安全的技术诊断标签，不含任何 Secret。
    case transport(String)
    /// HTTP 401。
    case unauthorized
    /// HTTP 403。
    case forbidden
    /// HTTP 429。
    case rateLimited
    /// HTTP 5xx 或流内 error 事件（statusCode 为 nil 表示非 HTTP 来源）。
    case serverError(statusCode: Int?)
    /// 响应无法解析（非 JSON / 结构不符）。
    case invalidResponse(String)
    /// SSE 流协议错误（malformed event、delta 事件缺字段等）。
    case streamProtocol(String)
    /// 服务端把响应标记为 incomplete（如达到输出长度上限）。
    /// MacSSH 1.1 Phase 10C-D：DeepSeek `response.incomplete` 事件。
    case incompleteResponse
    /// 主动取消（Stop / 会话关闭）。
    case cancelled

    /// 映射为 UI 展示分类（驱动本地化错误文案）。
    var displayKind: AgentFailureKind {
        switch self {
        case .missingCredential:
            return .missingCredential
        case .invalidBaseURL:
            return .invalidResponse
        case .transport:
            return .network
        case .unauthorized:
            return .authentication
        case .forbidden:
            return .forbidden
        case .rateLimited:
            return .rateLimited
        case .serverError:
            return .server
        case .invalidResponse:
            return .invalidResponse
        case .streamProtocol:
            return .invalidResponse
        case .incompleteResponse:
            return .incomplete
        case .cancelled:
            return .generic
        }
    }
}
