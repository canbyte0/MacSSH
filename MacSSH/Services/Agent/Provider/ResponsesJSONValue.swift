import Foundation

// MARK: - 通用 JSON 值（B4 §5/§23）

/// Provider-neutral 的 JSON 值树：同时支持 Decodable / Encodable / Equatable。
///
/// 两个用途：
/// 1. `AgentToolDefinition.parametersJSON`（JSON Schema）→ 请求体的
///    `parameters` 对象（§5/§9）；
/// 2. `AgentProviderContinuationItem.itemJSON`（provider 原始 item）→
///    continuation request input 的 verbatim 回放（§22/§23）。
///
/// 实现为值树而非 `Any`：`Any` 无法 Encodable / Equatable / Sendable，
/// 且无法保证 JSON-serializable。数值统一保真为 `String`（按
/// JSONSerialization 的规范数字文本往返，不做 Double 损耗猜测）。
enum ResponsesJSONValue: Sendable, Equatable {
    case object([String: ResponsesJSONValue])
    case array([ResponsesJSONValue])
    case string(String)
    /// 规范化数字文本（JSONSerialization `number` 的字符串形式）。
    case number(String)
    case bool(Bool)
    case null

    // MARK: - 解析

    /// 从 JSON 文本解析；顶层必须是 object 或 array。
    static func parse(_ json: String) throws -> ResponsesJSONValue {
        guard let data = json.data(using: .utf8) else {
            throw AgentProviderError.invalidResponse("tool JSON is not valid UTF-8")
        }
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> ResponsesJSONValue {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentProviderError.invalidResponse("malformed JSON")
        }
        return try value(from: any)
    }

    private static func value(from any: Any) throws -> ResponsesJSONValue {
        switch any {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // JSONSerialization 把 bool 桥接为 CFBoolean 类型的 NSNumber。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.stringValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map(value(from:)))
        case let object as [String: Any]:
            var result: [String: ResponsesJSONValue] = [:]
            for (key, value) in object {
                result[key] = try self.value(from: value)
            }
            return .object(result)
        default:
            throw AgentProviderError.invalidResponse("unexpected JSON value")
        }
    }

    // MARK: - 编码

    /// 编码回 JSON 文本（供存储 / Equatable 断言）。
    func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// object 成员访问（非 object 返回 nil）。
    var objectValue: [String: ResponsesJSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

// MARK: - Codable

extension ResponsesJSONValue: Decodable, Encodable {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        init(_ string: String) { self.init(stringValue: string) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            // Double 解码成功但 Bool 失败 → 数字。规范化文本：
            // 整数值不带小数点，其余用最短表示。
            if number == number.rounded(), abs(number) < 1e15 {
                self = .number(String(Int64(number)))
            } else {
                self = .number("\(number)")
            }
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if var array = try? decoder.unkeyedContainer() {
            var items: [ResponsesJSONValue] = []
            while !array.isAtEnd {
                items.append(try array.decode(ResponsesJSONValue.self))
            }
            self = .array(items)
        } else if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            var object: [String: ResponsesJSONValue] = [:]
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(ResponsesJSONValue.self, forKey: key)
            }
            self = .object(object)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .number(let text):
            // 规范数字文本 → 原始 JSON 数字（整数字面保持整数形态）。
            var container = encoder.singleValueContainer()
            if let int = Int64(text) {
                try container.encode(int)
            } else if let double = Double(text) {
                try container.encode(double)
            } else {
                try container.encode(text)
            }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .array(let items):
            var array = encoder.unkeyedContainer()
            for item in items {
                try array.encode(item)
            }
        case .object(let object):
            var keyed = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in object {
                try keyed.encode(value, forKey: AnyKey(key))
            }
        }
    }
}
