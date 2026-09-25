import Foundation

/// 预测只描述当前终端输入，不持有传输能力或任何可执行动作。
enum SuggestionTerminalKind: Equatable, Sendable {
    case local
    case remote
}

struct SuggestionGeneration: Equatable, Sendable {
    let value: UInt64
}

struct SuggestionRequest: Equatable, Sendable {
    let logicalSessionID: UUID
    let terminalKind: SuggestionTerminalKind
    let targetGeneration: UInt64
    let typedPrefix: String
    let inputRevision: UInt64
}

/// 所有条件由未来 UI/会话接线显式提供；缺失条件一律不能推断为 true。
struct SuggestionEligibility: Equatable, Sendable {
    let trustedShellEditing: Bool
    let terminalFocused: Bool
    let alternateScreen: Bool
    let imeMarkedText: Bool
    let settingsEnabled: Bool

    var isEligible: Bool {
        trustedShellEditing && terminalFocused && !alternateScreen
            && !imeMarkedText && settingsEnabled
    }
}

/// 接受建议时必须重新比对全部字段，尤其是目标代次和输入修订号。
struct SuggestionBinding: Equatable, Sendable {
    let request: SuggestionRequest
    let providerGeneration: SuggestionGeneration
}

struct SuggestionCandidate: Equatable, Sendable {
    let command: String
    let suffix: String

    /// 使用原始 UTF-8 精确前缀，随后确认切点正好在 Character 边界。
    /// 这样不会因 Unicode 规范等价而改变 Shell 字节，也不会截断字素。
    static func make(command: String, prefix: String) -> Self? {
        guard !prefix.isEmpty,
              command.utf8.count > prefix.utf8.count,
              command.utf8.starts(with: prefix.utf8),
              !command.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) })
        else { return nil }

        var byteCount = 0
        var characterCount = 0
        for character in command {
            byteCount += String(character).utf8.count
            characterCount += 1
            if byteCount == prefix.utf8.count {
                let head = String(command.prefix(characterCount))
                guard head.utf8.elementsEqual(prefix.utf8) else { return nil }
                let tail = String(command.dropFirst(characterCount))
                return tail.isEmpty ? nil : Self(command: command, suffix: tail)
            }
            if byteCount > prefix.utf8.count { return nil }
        }
        return nil
    }
}

enum SuggestionState: Equatable, Sendable {
    case idle
    case pending(SuggestionBinding)
    case loading(SuggestionBinding)
    case showing(SuggestionBinding, SuggestionCandidate)
    case dismissed
    case stale
}

/// 纯状态机：没有 PTY/SSH 引用，provider 的结果只能进入 showing。
struct TerminalSuggestionStateMachine: Sendable {
    private(set) var state: SuggestionState = .idle
    private var nextProviderGeneration: UInt64 = 0

    @discardableResult
    mutating func begin(_ request: SuggestionRequest, eligibility: SuggestionEligibility) -> SuggestionBinding? {
        guard eligibility.isEligible, !request.typedPrefix.isEmpty else {
            invalidate()
            return nil
        }
        nextProviderGeneration &+= 1
        let binding = SuggestionBinding(
            request: request,
            providerGeneration: SuggestionGeneration(value: nextProviderGeneration)
        )
        state = .pending(binding)
        return binding
    }

    mutating func loading(_ binding: SuggestionBinding) {
        guard state == .pending(binding) else { return }
        state = .loading(binding)
    }

    mutating func receive(_ candidate: SuggestionCandidate?, for binding: SuggestionBinding) {
        guard state == .pending(binding) || state == .loading(binding) else { return }
        guard let candidate,
              SuggestionCandidate.make(
                command: candidate.command,
                prefix: binding.request.typedPrefix
              ) == candidate
        else {
            state = .idle
            return
        }
        state = .showing(binding, candidate)
    }

    mutating func providerFailed(for binding: SuggestionBinding) {
        guard state == .pending(binding) || state == .loading(binding) else { return }
        state = .idle
    }

    /// 只返回经完整 identity 复核的后缀；绝不负责写入或追加 Return。
    func suffixIfCurrent(
        _ binding: SuggestionBinding,
        currentRequest: SuggestionRequest,
        eligibility: SuggestionEligibility
    ) -> String? {
        guard eligibility.isEligible,
              binding.request == currentRequest,
              case let .showing(current, candidate) = state,
              current == binding
        else { return nil }
        return candidate.suffix
    }

    mutating func dismiss() { state = .dismissed }
    mutating func prefixChanged() { invalidate() }
    mutating func backspaceOrEdit() { invalidate() }
    mutating func executed() { invalidate() }
    mutating func focusLost() { invalidate() }
    mutating func sessionSwitched() { invalidate() }
    mutating func sessionClosed() { invalidate() }
    mutating func remoteReconnected() { invalidate() }
    mutating func settingsDisabled() { invalidate() }
    mutating func agentTerminalMutated() { invalidate() }

    private mutating func invalidate() {
        nextProviderGeneration &+= 1
        state = .stale
    }
}

/// SwiftData 的投影；测试可构造合成历史，避免读取真实用户命令。
struct SuggestionHistoryRecord: Sendable {
    let command: String
    let sessionKind: String
    let hostDisplayName: String?
}

@MainActor
struct HistorySuggestionProvider {
    let store: CommandHistoryStore

    func candidate(for request: SuggestionRequest) -> SuggestionCandidate? {
        guard store.historyEnabled else { return nil }
        let records = store.recentEntries().map {
            SuggestionHistoryRecord(
                command: $0.command,
                sessionKind: $0.sessionKind,
                hostDisplayName: $0.hostDisplayName
            )
        }
        return Self.match(request: request, historyEnabled: true, records: records)
    }

    /// records 已按执行时间倒序。全局文本去重会刷新来源快照，不能把
    /// entries(forSession:) 当成完整逐会话日志。11B1 的 Remote 预测关闭。
    nonisolated static func match(
        request: SuggestionRequest,
        historyEnabled: Bool,
        records: [SuggestionHistoryRecord]
    ) -> SuggestionCandidate? {
        guard historyEnabled, request.terminalKind == .local else { return nil }
        for record in records where record.sessionKind == "local" && record.hostDisplayName == nil {
            if let candidate = SuggestionCandidate.make(
                command: record.command,
                prefix: request.typedPrefix
            ) {
                return candidate
            }
        }
        return nil
    }
}
