import Foundation

// MARK: - Target Snapshot（任务书 §8：kind snapshot + remote host display snapshot）

/// mutation 目标的展示快照：**只是 UI metadata**，绝不参与目标解析、
/// 绝不用于寻址（真正的授权身份是 `AgentTerminalInputTargetIdentity`）。
/// `hostDisplay` 只在 Remote 分支携带，未来卡片展示用，全程 redacted。
enum AgentTerminalMutationTargetSnapshot: Sendable, Equatable {
    case local
    case remote(hostDisplay: String)
}

// MARK: - Provider Snapshot Binding（任务书 §25）

/// 复用 Phase 10E 已验收的 `AgentCommandProviderBinding`（vendor 枚举 +
/// opaque snapshotID 的值类型，语义不变，零 10E 行为改动）：mutation 与
/// command 共享“generation 开始时冻结的 provider 快照”这一既有概念；
/// 快照在 Provider A 下提出 → 审批绑定 Provider A，B 快照身份不可消费。
/// （10F-A 冻结：不为此新建平行类型，也不改动既有类型的语义。）

// MARK: - Request（任务书 §8/§20）

/// 一次 interactive terminal mutation 请求的不可变领域模型。
///
/// 创建后**全部字段不得修改**（§20：全部 `let`，immutable value object）：
/// 文本、submit、目标 incarnation 身份、provider 快照在审批后绝不可替换。
/// 只能经 `AgentTerminalMutationRequestFactory` 构造（校验集中在
/// factory，`init` 为 `fileprivate`——外部含测试无法绕过校验拼装）。
///
/// Provider 只控制 `text` / `submit` 两个 schema 字段（10F-A 冻结）；
/// generation、callID、session、incarnation 身份、provider 快照、展示
/// metadata 全部由应用在构造时冻结。**绝不**从当前选中 tab / 活动会话 /
/// 第一个终端 / hostname 匹配派生目标（active-tab fallback 结构性禁止）。
///
/// 与 command execution 的语义分界见
/// `AgentTerminalInputTargetIdentity.swift` 顶部注释（两类操作不可互换）。
struct AgentTerminalMutationRequest: Sendable, Equatable {
    let generationID: UUID
    let callID: String
    /// logical / UI 会话身份（不足以单独授权，见 target identity）。
    let logicalSessionID: UUID
    /// 具体输入 endpoint incarnation 的授权身份（session + epoch + token）。
    let targetIdentity: AgentTerminalInputTargetIdentity
    /// 展示快照（Local / Remote + host display），非授权身份。
    let targetSnapshot: AgentTerminalMutationTargetSnapshot
    /// Provider 原样文本（§15：绝不 normalize / trim / 重写）。
    let text: String
    /// 是否由 delivery 层追加恰好一个 CR；false 只承诺不追加 CR，
    /// 不承诺“不执行”（10F-A-R1 §R1.5）。
    let submit: Bool
    /// generation 冻结的 provider 快照（复用 10E 类型，语义不变）。
    let providerBinding: AgentCommandProviderBinding
    /// 请求构造时刻（request identity 的一部分，仅诊断 / 排序用途）。
    let createdAt: Date

    /// 仅 `AgentTerminalMutationRequestFactory`（同文件）可构造。
    fileprivate init(
        generationID: UUID,
        callID: String,
        logicalSessionID: UUID,
        targetIdentity: AgentTerminalInputTargetIdentity,
        targetSnapshot: AgentTerminalMutationTargetSnapshot,
        text: String,
        submit: Bool,
        providerBinding: AgentCommandProviderBinding,
        createdAt: Date
    ) {
        self.generationID = generationID
        self.callID = callID
        self.logicalSessionID = logicalSessionID
        self.targetIdentity = targetIdentity
        self.targetSnapshot = targetSnapshot
        self.text = text
        self.submit = submit
        self.providerBinding = providerBinding
        self.createdAt = createdAt
    }
}

// MARK: - 零内容日志（任务书 §32/§62；10E redacted-description 模式照抄）

/// `description` / `debugDescription` 刻意 **redacted**：只含身份字段与
/// payload 字节数，绝不输出文本、host display、endpoint token 全值——
/// 默认合成描述会经 reflection 泄漏全部字段，必须显式覆盖。
extension AgentTerminalMutationRequest: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "AgentTerminalMutationRequest(generationID: \(generationID.uuidString), "
            + "callID: \(callID), logicalSessionID: \(logicalSessionID.uuidString), "
            + "inputTargetEpoch: \(targetIdentity.inputTargetEpoch), "
            + "payloadBytes: \(text.utf8.count), submit: \(submit), "
            + "content: <redacted>)"
    }

    var debugDescription: String { description }
}

// MARK: - Factory（任务书 §13/§14）

/// mutation request 的唯一构造入口：集中文本校验与构造一致性检查，
/// 绝不把校验散落到 UI / 调用方。
///
/// 参数来源分界（§13 冻结）：
/// - Provider 给出：`text`、`submit`（未来 B4 从 schema 解析）；
/// - 应用冻结：generation、callID、logical session、incarnation 身份
///   （epoch / endpoint token 由应用在审批注册**之前** capture，Provider
///    结构上无法提供 token——本 factory 只接受已生成的
///    `AgentTerminalEndpointToken`）、provider 快照、展示 metadata。
enum AgentTerminalMutationRequestFactory: Sendable {
    /// 组装并校验一次 mutation request。
    static func make(
        generationID: UUID,
        callID: String,
        logicalSessionID: UUID,
        targetIdentity: AgentTerminalInputTargetIdentity,
        targetSnapshot: AgentTerminalMutationTargetSnapshot,
        text: String,
        submit: Bool,
        providerBinding: AgentCommandProviderBinding,
        createdAt: Date
    ) -> Result<AgentTerminalMutationRequest, AgentTerminalMutationError> {
        // 构造一致性：顶层 logical session 与 identity 内 session 必须一致。
        guard logicalSessionID == targetIdentity.logicalSessionID else {
            return .failure(.invalidArguments)
        }
        if let validationError = AgentTerminalMutationValidation.validate(text) {
            return .failure(validationError)
        }
        return .success(AgentTerminalMutationRequest(
            generationID: generationID,
            callID: callID,
            logicalSessionID: logicalSessionID,
            targetIdentity: targetIdentity,
            targetSnapshot: targetSnapshot,
            text: text,
            submit: submit,
            providerBinding: providerBinding,
            createdAt: createdAt
        ))
    }
}
