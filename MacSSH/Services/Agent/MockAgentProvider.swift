import Foundation

/// MacSSH 1.1 Phase 10B / B4：本地 mock 流式回复（任务书 §10）。
///
/// 只在内存中生成文本：无网络、无 URLSession、无执行能力、无 Keychain。
/// - 回复按固定 chunk 流式产出，chunk 间隔可注入（测试用 `.zero` 避免 flaky）；
/// - deterministic test hook：最后一条 user **文本**消息包含 `/mock-error`
///   时抛错，用于验证失败 UI 与恢复（任务书 §22）；
/// - B4：mock 永不产出 toolCall——工具路径的验证由测试专用 scripted
///   provider 承担（生产 loop 测试）。
struct MockAgentProvider: AgentProvider {
    /// 每个 chunk 之间的延迟（生产默认 100ms，测试注入 `.zero`）。
    let chunkDelay: Duration

    init(chunkDelay: Duration = .milliseconds(100)) {
        self.chunkDelay = chunkDelay
    }

    func stream(
        transcript: [AgentMessage],
        tools: [AgentToolDefinition],
        context: AgentSessionContext
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    if Self.shouldTriggerMockError(transcript) {
                        throw AgentMockError.mockFailure
                    }
                    let reply = Self.replyText
                    for chunk in Self.chunks(of: reply) {
                        try Task.checkCancellation()
                        if chunkDelay > .zero {
                            try await Task.sleep(for: chunkDelay)
                        }
                        continuation.yield(.textDelta(chunk))
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 消费方取消（Stop / 会话关闭）时终止生产任务，不残留后台睡眠。
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    // MARK: - Mock 文本

    enum AgentMockError: Error {
        case mockFailure
    }

    /// `/mock-error`：最后一条 user 文本消息命中即失败（deterministic
    /// test hook；tool card 等非文本条目不参与判定）。
    static func shouldTriggerMockError(_ transcript: [AgentMessage]) -> Bool {
        guard let lastUser = transcript.last(where: { $0.role == .user }) else {
            return false
        }
        return lastUser.text.contains("/mock-error")
    }

    /// mock 回复正文：明确告知当前未接真实模型、无执行能力（任务书 §10 示例）。
    static let replyText =
        "这是 Phase 10B 的本地模拟回复。\n当前 Agent 尚未连接外部模型，也不会执行任何终端操作。\n此回复仅用于验证流式渲染、Stop 取消与会话隔离。"

    /// 固定切分 mock 回复（4 字符/chunk，保证流式可见性）。
    static func chunks(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        var result: [String] = []
        var index = 0
        let chunkSize = 4
        while index < characters.count {
            let end = min(index + chunkSize, characters.count)
            result.append(String(characters[index..<end]))
            index = end
        }
        return result
    }
}
