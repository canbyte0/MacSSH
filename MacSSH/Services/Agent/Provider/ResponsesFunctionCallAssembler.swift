import Foundation

// MARK: - Output item 模型（B4 §61/§62）

/// Responses 流事件中的 output item（宽松解码：只取组装需要的字段，
/// 未知字段忽略；`rawJSON` 保留完整 item 供 opaque 回放）。
struct ResponsesOutputItem: Decodable, Equatable, Sendable {
    let type: String
    /// item 自身 id（如 `fc_...` / `rs_...`）；function_call 组装的
    /// assembly key（§62）。
    var id: String?
    /// function call 的配对身份（§14 hard identity）。
    var callID: String?
    var name: String?
    /// output_item.done 时 item 自带的完整 arguments（§12 参照值）。
    var arguments: String?
    /// 完整 item 的原始 JSON（reasoning 等 opaque replay 用，§22/§23）。
    let raw: ResponsesJSONValue

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case callID = "call_id"
        case name
        case arguments
    }

    init(
        type: String,
        id: String? = nil,
        callID: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        raw: ResponsesJSONValue
    ) {
        self.type = type
        self.id = id
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
        raw = try ResponsesJSONValue(from: decoder)
    }
}

// MARK: - 组装状态机（B4 §11/§12/§13/§14/§15/§61/§62）

/// 单次 Provider response 流内的 function-call / reasoning 组装器。
///
/// 职责（全部在 Provider 传输层内部，Agent runtime 只见完整
/// `AgentProviderToolCall`，§11 hard gate）：
/// - `response.output_item.added`（function_call）→ 按 `item.id` 注册
///   assembly，登记 `call_id`（重复 → `streamProtocol`，§15）；
/// - `response.function_call_arguments.delta` → 追加到对应 assembly
///   （未知 item → `streamProtocol`，§61）；
/// - `response.function_call_arguments.done` → 记录 authoritative
///   arguments（§12）；
/// - `response.output_item.done`（function_call）→ 终检 + 产出完整
///   `AgentProviderToolCall`（§12：done 与累计 delta 不一致 →
///   `streamProtocol`，绝不静默执行不确定数据）；
/// - `response.output_item.done`（reasoning）→ 产出 provider-scoped
///   opaque continuation item（§22/§23）。
///
/// 未 finalize 的 assembly（incomplete / failed / 流中断，§59/§60）
/// 永不产出 toolCall——残缺工具绝不执行。
///
/// 线程模型：非 Sendable；由 `ResponsesProviderCore` 的单一 producer
/// Task 顺序调用（每条流一个实例）。
final class ResponsesFunctionCallAssembler {
    private struct CallAssembly {
        var callID: String?
        var name: String?
        var accumulatedArguments = ""
        var receivedDeltas = false
        var finalArguments: String?
        var isDone = false
        /// call_id 是否已在 added 阶段登记（避免 finalize 重复登记误报 §15）。
        var isCallIDRegistered = false
    }

    private let providerScope: AgentProviderScope
    /// item.id → assembly（§62 mapping）。
    private var assemblies: [String: CallAssembly] = [:]
    /// 本 response 内已见 call_id（§15 duplicate 检测）。
    private var seenCallIDs: Set<String> = []

    init(providerScope: AgentProviderScope) {
        self.providerScope = providerScope
    }

    /// `response.output_item.added`：function_call 注册 assembly；
    /// 其余类型（message / reasoning 等）无需注册（reasoning 在 done
    /// 时一次性捕获完整 item）。
    func registerItemAdded(_ item: ResponsesOutputItem) throws {
        guard item.type == "function_call" else { return }
        guard let itemID = item.id else {
            throw AgentProviderError.streamProtocol("function_call output_item.added without item id")
        }
        guard assemblies[itemID] == nil else {
            throw AgentProviderError.streamProtocol("duplicate function_call item id")
        }
        var assembly = CallAssembly(callID: item.callID, name: item.name)
        if let callID = item.callID {
            try registerCallID(callID)
            assembly.isCallIDRegistered = true
        }
        assemblies[itemID] = assembly
    }

    /// `response.function_call_arguments.delta`（§61：未知 item 报错，
    /// 绝不猜测）。
    func appendArgumentsDelta(itemID: String, delta: String) throws {
        guard var assembly = assemblies[itemID], !assembly.isDone else {
            throw AgentProviderError.streamProtocol("arguments delta for unknown function_call item")
        }
        assembly.accumulatedArguments += delta
        assembly.receivedDeltas = true
        assemblies[itemID] = assembly
    }

    /// `response.function_call_arguments.done`（§12 authoritative）。
    func recordArgumentsDone(itemID: String, arguments: String) throws {
        guard var assembly = assemblies[itemID], !assembly.isDone else {
            throw AgentProviderError.streamProtocol("arguments done for unknown function_call item")
        }
        assembly.finalArguments = arguments
        assemblies[itemID] = assembly
    }

    /// `response.output_item.done`：function_call → 完整 AgentProviderToolCall；
    /// reasoning → opaque continuation item；其余类型忽略。
    /// - Returns: 0…n 个 AgentEvent（按 output order 产出，§13/§27）。
    func finalizeItem(_ item: ResponsesOutputItem) throws -> [AgentEvent] {
        switch item.type {
        case "function_call":
            return [try finalizeFunctionCall(item)]
        case "reasoning":
            return [
                .providerItem(
                    AgentProviderContinuationItem(
                        providerScope: providerScope,
                        kind: "reasoning",
                        itemJSON: item.raw.encodedString()
                    )
                )
            ]
        default:
            return []
        }
    }

    // MARK: - 内部

    private func finalizeFunctionCall(_ item: ResponsesOutputItem) throws -> AgentEvent {
        guard let itemID = item.id, var assembly = assemblies[itemID] else {
            throw AgentProviderError.streamProtocol("function_call output_item.done without preceding added event")
        }
        guard !assembly.isDone else {
            throw AgentProviderError.streamProtocol("function_call item finalized twice")
        }

        // done item 补全 added 时缺失的字段（§62）。
        if assembly.callID == nil { assembly.callID = item.callID }
        if assembly.name == nil { assembly.name = item.name }
        if !assembly.isCallIDRegistered, let callID = assembly.callID {
            try registerCallID(callID)
            assembly.isCallIDRegistered = true
        }
        guard let callID = assembly.callID, let name = assembly.name ?? item.name else {
            throw AgentProviderError.streamProtocol("function_call item without call_id or name")
        }

        // §12：canonical arguments = arguments.done > item.arguments >
        // accumulated deltas（fallback）。
        if assembly.finalArguments == nil {
            assembly.finalArguments = item.arguments
        }
        let arguments: String
        if let finalArguments = assembly.finalArguments {
            arguments = finalArguments
        } else {
            arguments = assembly.accumulatedArguments
        }

        // §12 hard gate：done 与累计 delta 不一致 → 结构化报错，
        // 绝不静默执行不确定数据。
        if assembly.receivedDeltas,
           let finalArguments = assembly.finalArguments,
           finalArguments != assembly.accumulatedArguments {
            throw AgentProviderError.streamProtocol(
                "function_call arguments done does not match accumulated deltas"
            )
        }

        assembly.isDone = true
        assemblies[itemID] = assembly
        return .toolCall(
            AgentProviderToolCall(callID: callID, name: name, argumentsJSON: arguments)
        )
    }

    /// call_id 唯一性登记（§15：同 response 内 duplicate → streamProtocol）。
    private func registerCallID(_ callID: String) throws {
        guard !seenCallIDs.contains(callID) else {
            throw AgentProviderError.streamProtocol("duplicate function call_id in response")
        }
        seenCallIDs.insert(callID)
    }
}
