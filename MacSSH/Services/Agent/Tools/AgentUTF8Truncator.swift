import Foundation

/// 按 UTF-8 字节预算截断后的文本（任务书 10D-B2 §5）。
///
/// 预算一律按 **UTF-8 bytes** 计算，绝不按 `String.count` / UTF-16
/// length / Character count（§4）。
struct AgentBoundedText: Sendable, Equatable {
    let text: String
    let truncated: Bool
    let bytesReturned: Int

    static let empty = AgentBoundedText(text: "", truncated: false, bytesReturned: 0)
}

/// Agent 文本载荷的硬上限（任务书 §4 / §25）。
enum AgentTextLimits: Sendable {
    /// recent output 的 physical rows 上限（§4/§13）。
    static let recentOutputMaxRows = 200
    /// selection 的 UTF-8 字节上限（§4/§17）。
    static let selectionMaxBytes = 64 * 1024
    /// terminal 文本载荷总预算：selection + recentOutput（§4）。
    static let terminalTextualPayloadMaxBytes = 256 * 1024
    /// 单次 read_file 的 UTF-8 字节上限（§25）。
    static let fileReadMaxBytes = 256 * 1024
    /// 为跨边界多字节字符多读的探测字节（§26）。
    static let fileUTF8ProbeBytes = 8
}

/// 统一的 UTF-8 截断 helper（§5/§26）。
///
/// terminal selection、recent output 与本地文件读取共用同一实现：
/// 绝不在 Character（组合字符 / Emoji / 中文多字节序列）的 UTF-8
/// byte sequence 中间截断。
enum AgentUTF8Truncator: Sendable {
    static func byteCount(of text: String) -> Int {
        text.utf8.count
    }

    /// 按 UTF-8 字节预算截断字符串。
    ///
    /// 逐 Character（grapheme cluster）累加 UTF-8 宽度：放不下的整个
    /// Character 都不返回（😀 = 4 bytes，只剩 3 bytes 时整个丢弃，§5）。
    static func truncate(_ text: String, byteLimit: Int) -> AgentBoundedText {
        guard byteLimit > 0 else {
            return AgentBoundedText(text: "", truncated: !text.isEmpty, bytesReturned: 0)
        }
        let total = text.utf8.count
        guard total > byteLimit else {
            return AgentBoundedText(text: text, truncated: false, bytesReturned: total)
        }

        var used = 0
        var end = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let width = text.utf8[index..<next].count
            if used + width > byteLimit {
                break
            }
            used += width
            end = next
            index = next
        }
        return AgentBoundedText(
            text: String(text[..<end]),
            truncated: true,
            bytesReturned: used
        )
    }

    /// 在数据层找 `<= byteLimit` 的最大合法 UTF-8 前缀长度（§26）。
    ///
    /// 只在字节层回退 continuation byte（`0b10xxxxxx`），最多回退 3 字节
    /// 到一个 code point 边界；随后由 `String` 解码做最终校验。
    static func utf8PrefixBoundary(in data: Data, byteLimit: Int) -> Int {
        guard byteLimit >= 0 else { return 0 }
        if data.count <= byteLimit {
            return data.count
        }
        var cut = byteLimit
        var backoff = 0
        while cut > 0, backoff < 3, (data[cut] & 0xC0) == 0x80 {
            cut -= 1
            backoff += 1
        }
        return cut
    }

    /// 严格 UTF-8 解码：非法字节序列返回 nil（§27 → binaryUnsupported）。
    static func decodeStrictUTF8(_ data: Data) -> String? {
        String(bytes: data, encoding: .utf8)
    }
}
