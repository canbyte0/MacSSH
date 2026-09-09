import Foundation

/// 单个已完成的 SSE 事件（event 名 + data 载荷）。
struct SSEEvent: Equatable, Sendable {
    /// `event:` 字段值；未提供时为空字符串。
    let event: String
    /// 多行 `data:` 以换行拼接后的载荷（原始文本，未做 JSON 解析）。
    let data: String
}

/// MacSSH 1.1 Phase 10C：状态化 SSE 增量解析器（任务书 §17 / §31）。
///
/// 输入：URLSession bytes 流产出的任意行序列；输出：每次 feed 返回
/// 本批次完成的完整事件（0…n 个）。需覆盖的现实边界：
/// - 事件跨 chunk 分裂 / 一个 chunk 内含多个事件；
/// - CRLF / LF 混排；
/// - UTF-8 多字节字符跨 chunk 分裂（按字节缓冲，只在 `\n`（0x0A）
///   处切行——UTF-8 续字节均 ≥ 0x80，绝不与 0x0A 冲突，切分安全）；
/// - 未知事件 / 未知字段 / 注释行（按 SSE 规范忽略）。
///
/// 线程模型：非 Sendable；由单一 Task 顺序调用（Provider stream 内部）。
final class SSEEventParser {
    /// 按字节缓冲，避免 String 索引在部分 UTF-8 序列上崩溃。
    private var buffer: [UInt8] = []
    private var pendingEventName: String?
    private var pendingDataLines: [String] = []

    /// 喂入一个网络 chunk，返回本 chunk 内完成的完整事件。
    func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(contentsOf: chunk)
        var events: [SSEEvent] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineBytes = Array(buffer[0..<newlineIndex])
            buffer.removeFirst(newlineIndex + 1)
            var line = String(decoding: lineBytes, as: UTF8.self)
            // 兼容 CRLF：行尾 CR 在行级剥离。
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            processLine(line, into: &events)
        }
        return events
    }

    /// 流结束（EOF）：宽容 flush——残余字节视为最后一行处理，随后产出
    /// 未以空行结尾的最后一个事件，避免服务端在最终事件后直接关闭连接
    /// 时丢失 `response.completed`。截断流中半截 JSON 会因解析失败显式
    /// 报错，绝不静默当作完整内容吞掉。finish 幂等：重复调用不再产出。
    func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        // 残余无换行结尾的字节按最后一行宽容处理。
        if !buffer.isEmpty {
            var line = String(decoding: buffer, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            buffer.removeAll()
            processLine(line, into: &events)
        }
        if let event = takePendingEvent() {
            events.append(event)
        }
        return events
    }

    // MARK: - 行处理（SSE 规范）

    private func processLine(_ line: String, into events: inout [SSEEvent]) {
        if line.isEmpty {
            // 空行 = 事件分隔符：dispatch pending event。
            if let event = takePendingEvent() {
                events.append(event)
            }
            return
        }
        if line.hasPrefix(":") {
            // 注释行，忽略。
            return
        }
        guard let colonIndex = line.firstIndex(of: ":") else {
            // 无冒号的字段行（如裸 "event"），按规范忽略。
            return
        }
        let field = String(line[..<colonIndex])
        var value = String(line[line.index(after: colonIndex)...])
        // SSE 规范：剥掉紧跟冒号的一个前导空格。
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        switch field {
        case "event":
            pendingEventName = value
        case "data":
            pendingDataLines.append(value)
        default:
            // 未知字段（id / retry 等），按规范忽略。
            break
        }
    }

    /// 取出 pending 事件；按 SSE 规范，无 data 行的事件不 dispatch。
    private func takePendingEvent() -> SSEEvent? {
        defer {
            pendingEventName = nil
            pendingDataLines = []
        }
        guard !pendingDataLines.isEmpty else { return nil }
        return SSEEvent(
            event: pendingEventName ?? "",
            data: pendingDataLines.joined(separator: "\n")
        )
    }
}
