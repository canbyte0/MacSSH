import Foundation

/// 有界的 recent output 提取器（任务书 §10–§14）。
///
/// 设计要点：
/// - 绝不 `getBufferAsData()` 复制完整 scrollback（§11）；
/// - 只按 scroll-invariant 行号取尾部 ≤ 200 physical rows；
/// - 行总数未知时用「指数探测 + 二分」，probe 次数硬上限 32（§12）；
/// - `isWrapped` 续行合并为 logical line，不插入多余换行（§13）；
/// - 只裁尾部纯空白行，绝不 trim 整体 output（§14）；
/// - 最后按 UTF-8 字节预算截断（§4/§5）。
enum TerminalRecentOutputSnapshotter {
    /// probe 硬上限（§12）：防止无限探测，超出即接受已确认的边界。
    static let maxProbes = 32
    /// physical rows 上限（§13）。
    static let maxRows = AgentTextLimits.recentOutputMaxRows

    /// 提取尾部 recent output。
    ///
    /// - Parameters:
    ///   - source: buffer 适配器（MainActor）；
    ///   - byteBudget: 剩余 UTF-8 预算（已扣除 selection 占用，§4）。
    /// - Returns: 截断结果；`truncated` 同时覆盖「200 行上限」与「字节预算」。
    @MainActor
    static func snapshot(
        source: some AgentTerminalBufferSource,
        byteBudget: Int
    ) -> AgentBoundedText {
        let start = source.firstValidRow
        guard let last = lastValidRow(source: source, start: start), last >= start else {
            return .empty
        }

        let available = last - start + 1
        let take = min(maxRows, available)
        let lower = last - take + 1

        var logicalLines: [String] = []
        logicalLines.reserveCapacity(take)
        for row in lower...last {
            guard let line = source.line(atScrollInvariantRow: row) else {
                break
            }
            if line.isWrapped, let lastIndex = logicalLines.indices.last {
                // 软换行续行：直接拼接，绝不插入新换行（§13）。
                logicalLines[lastIndex] += line.text
            } else {
                logicalLines.append(line.text)
            }
        }

        // 只裁尾部纯空白行：前导 / 内部空格一律保留（§14）。
        while let lastIndex = logicalLines.indices.last,
              logicalLines[lastIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logicalLines.removeLast()
        }

        let joined = logicalLines.joined(separator: "\n")
        let bounded = AgentUTF8Truncator.truncate(joined, byteLimit: byteBudget)
        let rowCapped = available > maxRows
        return AgentBoundedText(
            text: bounded.text,
            truncated: bounded.truncated || rowCapped,
            bytesReturned: bounded.bytesReturned
        )
    }

    /// 定位当前最后一个有效 scroll-invariant 行号。
    ///
    /// 指数探测确定上界，再二分收窄；probe 次数不超过 `maxProbes`。
    /// 返回 nil 表示缓冲区为空。
    @MainActor
    private static func lastValidRow(
        source: some AgentTerminalBufferSource,
        start: Int
    ) -> Int? {
        var probes = 1
        guard source.line(atScrollInvariantRow: start) != nil else {
            return nil
        }

        var low = start
        var step = 1
        var invalidUpper: Int?
        while probes < maxProbes {
            let candidate = start + step
            probes += 1
            guard source.line(atScrollInvariantRow: candidate) != nil else {
                invalidUpper = candidate
                break
            }
            low = candidate
            step *= 2
        }

        if let invalidUpper {
            var lower = low + 1
            var upper = invalidUpper - 1
            while lower <= upper, probes < maxProbes {
                let mid = lower + (upper - lower) / 2
                probes += 1
                if source.line(atScrollInvariantRow: mid) != nil {
                    low = mid
                    lower = mid + 1
                } else {
                    upper = mid - 1
                }
            }
        }
        return low
    }
}
