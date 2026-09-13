import Foundation

// MARK: - Target（任务书 §10）

/// Agent 命令的执行目标。
///
/// `displayName` **只是 UI metadata**：绝不用于 session 解析、SSH 查找
/// 或 shell command 构造。真正的 target identity 是 request 的
/// `sessionID`（origin session，非 active 指针——§45）。
enum AgentCommandTarget: Sendable, Equatable {
    case local(displayName: String)
    case remote(displayName: String)
}

// MARK: - Provider Binding（任务书 §11/§12）

/// Approval 对 Provider generation 的绑定身份。
///
/// `snapshotID` 是 opaque generation identity——**不是 credential**。
/// 本结构绝不包含 API key / Authorization header / SSH 凭据
/// （§11 hard gate；凭据仅存在于 Provider 层，approval domain 无引用路径）。
///
/// `provider` 复用项目现有 `AgentProviderSettings.Provider`（vendor 枚举，
/// 即任务书推荐 `AgentProviderKind` 的项目内既有形态，避免重复定义）。
struct AgentCommandProviderBinding: Sendable, Equatable {
    /// Provider generation 快照的 opaque ID。B4 runtime 在
    /// `snapshotForGeneration()` 时刻生成并保持
    /// generationID ↔ providerSnapshotID 一一绑定（§12）。
    let snapshotID: UUID
    let provider: AgentProviderSettings.Provider
    let model: String
    let baseURL: URL
}

// MARK: - Request（任务书 §9）

/// 一次 command 请求的不可变领域模型。
///
/// 创建后 `command` / `cwd` / `session` / provider binding 全部不得修改
/// （§9：全部 `let`）。只能经 `AgentCommandRequestFactory` 构造
/// （validation + 权威 cwd 检查都在 factory 内，§61），`init` 是
/// `fileprivate`——外部（含测试）无法绕过校验手工拼装 request。
///
/// cwd 语义（§15–§17）：`workingDirectory` 是 generation 开始时冻结的
/// **authoritative** cwd，不是模型参数；generation 中途交互 shell `cd`
/// 不影响已冻结 request；本层不实现 canonicalization（B2/B3）。
struct AgentCommandRequest: Sendable, Equatable {
    let generationID: UUID
    let callID: String
    let sessionID: UUID
    let target: AgentCommandTarget
    /// Provider 原始 command（§66：绝不 normalize / 重写 / trim）。
    let command: String
    /// generation 冻结的 authoritative working directory（绝对路径）。
    let workingDirectory: String
    let providerBinding: AgentCommandProviderBinding

    /// 仅 `AgentCommandRequestFactory`（同文件）可构造。
    fileprivate init(
        generationID: UUID,
        callID: String,
        sessionID: UUID,
        target: AgentCommandTarget,
        command: String,
        workingDirectory: String,
        providerBinding: AgentCommandProviderBinding
    ) {
        self.generationID = generationID
        self.callID = callID
        self.sessionID = sessionID
        self.target = target
        self.command = command
        self.workingDirectory = workingDirectory
        self.providerBinding = providerBinding
    }
}

// MARK: - 零内容日志（任务书 §57）

/// `description` / `debugDescription` 刻意 **redacted**：只含身份字段，
/// 绝不输出 command / cwd / displayName——默认合成描述会经 reflection
/// 泄漏全部字段，必须显式覆盖。
extension AgentCommandRequest: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "AgentCommandRequest(generationID: \(generationID.uuidString), "
            + "callID: \(callID), sessionID: \(sessionID.uuidString), "
            + "content: <redacted>)"
    }

    var debugDescription: String { description }
}

// MARK: - Factory（任务书 §61）

/// command request 的唯一构造入口：集中 validation 与权威 cwd 检查，
/// 绝不把校验散落到 UI / 调用方。
enum AgentCommandRequestFactory: Sendable {
    /// 组装并校验一次 command request。
    ///
    /// - command：经 `AgentCommandValidation`（§13）。
    /// - cwd：只接受 `confidence == .authoritative` 的
    ///   `AgentWorkingDirectory`（§62/§63：Local 与 Remote 同一域要求，
    ///   sessionDefault approximate 一律拒绝），且必须为**绝对路径**；
    ///   否则 `cwdUnavailable`——绝不 fallback HOME / App cwd /
    ///   登录默认目录（§16）。
    static func make(
        generationID: UUID,
        callID: String,
        sessionID: UUID,
        target: AgentCommandTarget,
        command: String,
        workingDirectory: AgentWorkingDirectory,
        providerBinding: AgentCommandProviderBinding
    ) -> Result<AgentCommandRequest, AgentCommandError> {
        if let validationError = AgentCommandValidation.validate(command) {
            return .failure(validationError)
        }
        guard
            workingDirectory.confidence == .authoritative,
            let path = workingDirectory.path,
            !path.isEmpty,
            path.hasPrefix("/")
        else {
            return .failure(.cwdUnavailable)
        }
        return .success(AgentCommandRequest(
            generationID: generationID,
            callID: callID,
            sessionID: sessionID,
            target: target,
            command: command,
            workingDirectory: path,
            providerBinding: providerBinding
        ))
    }
}
