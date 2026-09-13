import Foundation

/// Command 输出清洗（10E-A §37/§38/§39 冻结策略；B2 实现并测试）。
///
/// 管线（严格按冻结顺序）：
/// 1. cap 截断处的**不完整 UTF-8 尾部序列**：仅在尾部确实是某合法
///    序列前缀时移除（`utf8PrefixBoundary` 语义的等价实现）；
/// 2. NUL 检测：命中即 `binaryDetected`，内容截断到首个 NUL 前
///    的安全前缀（绝不 Base64 / hex dump，§39）；
/// 3. 严格 UTF-8 解码：失败 → U+FFFD 替换 + `nonUTF8Detected`
///    （绝不 `binaryUnsupported` 硬失败——命令输出天然可能混入局部
///    非 UTF-8 字节，硬失败会让模型无法理解结果，§37）；
/// 4. ANSI/CSI/OSC/DCS strip + C0/C1 控制字符过滤（保留 `\n`，§38）。
///
/// 本层是 **UX 卫生**而非安全边界（安全边界是 per-call approval）；
/// 绝不把 command 输出喂给任何终端模拟器 / SwiftTerm（§35/§51）。
enum AgentLocalCommandOutputSanitizer {
    /// 单流清洗结果。`truncated` 仅表示 cap 截断（NUL / 非法字节有独立标记）。
    struct SanitizedOutput: Sendable, Equatable {
        let text: String
        let truncated: Bool
        let binaryDetected: Bool
        let nonUTF8Detected: Bool

        static let empty = SanitizedOutput(
            text: "", truncated: false, binaryDetected: false, nonUTF8Detected: false
        )
    }

    /// 字节 → 清洗后文本 + 标记。
    static func sanitize(_ data: Data, capacityTruncated: Bool) -> SanitizedOutput {
        var bytes = [UInt8](data)
        if capacityTruncated {
            bytes = removeIncompleteUTF8Suffix(bytes)
        }

        var binaryDetected = false
        if let nulIndex = bytes.firstIndex(of: 0) {
            binaryDetected = true
            bytes = Array(bytes[..<nulIndex])
        }

        let decoded: String
        var nonUTF8Detected = false
        if let strict = String(bytes: bytes, encoding: .utf8) {
            decoded = strict
        } else {
            nonUTF8Detected = true
            decoded = String(decoding: bytes, as: UTF8.self)
        }

        return SanitizedOutput(
            text: stripControlSequences(decoded),
            truncated: capacityTruncated,
            binaryDetected: binaryDetected,
            nonUTF8Detected: nonUTF8Detected
        )
    }

    // MARK: - UTF-8 边界

    /// 移除尾部**不完整**的 UTF-8 序列（仅当尾部是合法序列的前缀时）。
    /// 非法 lead / 过长 continuation 一律保留，交给 lossy 解码替换为 U+FFFD。
    static func removeIncompleteUTF8Suffix(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return bytes }
        var continuationCount = 0
        var index = bytes.count - 1
        while index >= 0 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 {
                continuationCount += 1
                guard continuationCount <= 3 else { return bytes }
                index -= 1
                continue
            }
            let expected = expectedSequenceLength(leadByte: byte)
            guard expected > 0 else { return bytes }
            let available = continuationCount + 1
            if available < expected {
                return Array(bytes[..<index])
            }
            return bytes
        }
        return bytes
    }

    private static func expectedSequenceLength(leadByte: UInt8) -> Int {
        switch leadByte {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 0
        }
    }

    // MARK: - ANSI / 控制字符

    /// ANSI/CSI/OSC/DCS strip + C0/C1 过滤（保留 `\n`；`\t` 不在保留集，
    /// 严格遵循 10E-A §38 冻结文本）。
    ///
    /// 状态机（scalar 级，确定性）：
    /// - `ESC` 引入：`[` → CSI；`]` `P` `X` `^` `_` → 字符串态（OSC/DCS/SOS/PM/APC）；
    ///   其余 → 二字符 escape（整体丢弃）；`ESC \` 单独出现亦丢弃；
    /// - CSI：丢弃至 final byte（`0x40–0x7E`），其间 `ESC` 重启引入态；
    /// - 字符串态：`BEL` / C1 ST（U+009C）/ `ESC \` 终止，其余全部丢弃
    ///   （绝不重解释 escape，只做确定性删除）；
    /// - C0（除 `\n`）/ C1 / DEL 一律丢弃。
    static func stripControlSequences(_ text: String) -> String {
        enum State {
            case text
            case escape
            case csi
            case stringBody
            case stringEscape
        }

        var state = State.text
        var output = ""
        output.reserveCapacity(text.utf8.count)

        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1B:
                    state = .escape
                case 0x9B:
                    state = .csi
                case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                    state = .stringBody
                case 0x0A:
                    output.unicodeScalars.append(scalar)
                case 0x00...0x1F, 0x7F, 0x80...0x9F:
                    break
                default:
                    output.unicodeScalars.append(scalar)
                }
            case .escape:
                switch value {
                case 0x5B:
                    state = .csi
                case 0x50, 0x58, 0x5D, 0x5E, 0x5F:
                    state = .stringBody
                default:
                    state = .text
                }
            case .csi:
                if value == 0x1B {
                    state = .escape
                } else if (0x40...0x7E).contains(value) {
                    state = .text
                }
            case .stringBody:
                switch value {
                case 0x07, 0x9C:
                    state = .text
                case 0x1B:
                    state = .stringEscape
                default:
                    break
                }
            case .stringEscape:
                state = value == 0x5C ? .text : .stringBody
            }
        }
        return output
    }
}
