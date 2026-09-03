import Foundation
import SwiftTerm

/// MacSSH 1.1 Phase 6：终端字符串高亮匹配器（纯逻辑，无 UI / 存储 / 缓存）。
///
/// 输入：一条 `BufferLine`（visible 行，含 scrollback 行）+ 已排序启用规则。
/// 输出：terminal cell range + 颜色。
///
/// 语义（Phase 6 v1 冻结）：
/// - literal substring（无 regex / 无 whole-word / 无 host 规则 / 无 shell 解析）；
/// - 物理行独立匹配：terminal wrap 把关键词拆到两个物理行（`ERRO` / `R`）时
///   **不匹配**——这是明确的 v1 limitation（resize 后每帧重算，无 stale range）；
/// - 大小写：case-sensitive 直比；case-insensitive 用确定性
///   `String.CompareOptions.caseInsensitive`（locale 无关，不用 localized*）；
/// - 重复匹配全部返回（`ERROR ERROR ERROR` → 3 段）；
/// - 重叠语义：first-rule-wins——按 `(sortOrder, id)` 排序的规则依次匹配，
///   与已接受区间重叠的后续命中**整段放弃**，确定性可复现。
///
/// Unicode cell 映射：严禁把 `String.count` / UTF-16 length / NSRange location
/// 直接当列号。本匹配器把 String offset 经 `BufferLine.CharData.width`
/// （wide + width-0 续接格跳过）映射回 terminal cell 列，算法镜像
/// `SearchEngine.stringLengthToBufferSize`（SwiftTerm 内部，Phase 6A probe
/// 已逐字验证等价）。
enum TerminalHighlightMatcher {

    /// 一条命中：`endColumn` 不含（exclusive）。
    struct Match: Equatable {
        let startColumn: Int
        let endColumn: Int
        let color: TerminalHighlightColor
    }

    /// 对一条物理行执行全部规则的 literal substring 匹配。
    ///
    /// - Parameters:
    ///   - line: 目标物理行（buffer row 的 `BufferLine`）。
    ///   - terminal: 行所属 Terminal（提供 `getCharacter(for:)` 字符翻译）。
    ///   - rules: **已排序**的启用规则（调用方负责 `enabledRules`）。
    static func matches(inLine line: BufferLine,
                        terminal: Terminal,
                        rules: [TerminalHighlightRule]) -> [Match] {
        guard !rules.isEmpty else { return [] }
        let lineText = lineString(terminal: terminal, line: line)
        guard !lineText.isEmpty else { return [] }

        var accepted: [Match] = []
        for rule in rules {
            // 双重防御：空文本 / 禁用规则在 UI 与 Store 已过滤，
            // 这里再挡一次（matcher 也可能被直接调用）。trim 后再判空，
            // 避免 whitespace-only pattern 进入 range 搜索产生零宽匹配。
            let trimmed = rule.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rule.isEnabled, !trimmed.isEmpty else { continue }
            let options: String.CompareOptions = rule.isCaseSensitive ? [] : [.caseInsensitive]
            var searchStart = lineText.startIndex
            while let found = lineText.range(of: trimmed,
                                             options: options,
                                             range: searchStart..<lineText.endIndex) {
                let strStart = lineText.distance(from: lineText.startIndex, to: found.lowerBound)
                let strEnd = lineText.distance(from: lineText.startIndex, to: found.upperBound)
                let startCell = stringOffsetToCell(line: line, offset: strStart)
                let endCell = stringOffsetToCell(line: line, offset: strEnd)
                if endCell > startCell,
                   !accepted.contains(where: { $0.startColumn < endCell && startCell < $0.endColumn }) {
                    accepted.append(Match(startColumn: startCell,
                                          endColumn: endCell,
                                          color: rule.color))
                }
                // 继续搜索剩余部分（重复匹配全部返回）。
                searchStart = found.upperBound
            }
        }
        return accepted
    }

    // MARK: - String ↔ Cell 映射

    /// 把单行 `translateToString(skipNullCellsFollowingWide: true)` 产出的
    /// String offset（Character 数）映射回 terminal cell 列。
    ///
    /// 宽字符（width == 2）之后的 width-0 续接格不产生字符串字符，因此逐格
    /// 步进时跳过：镜像 `SearchEngine.stringLengthToBufferSize`，仅使用
    /// public 的 `CharData.width`（`CharData.code` 为 internal）。
    static func stringOffsetToCell(line: BufferLine, offset: Int) -> Int {
        var strIdx = 0
        var cell = 0
        let limit = min(offset, line.count)
        while cell < line.count, strIdx < limit {
            if line[cell].width == 2, cell + 1 < line.count, line[cell + 1].width == 0 {
                cell += 2
            } else {
                cell += 1
            }
            strIdx += 1
        }
        return cell
    }

    /// 单行翻译：与 `SearchLineCache.translateBufferLineToStringWithWrap` 的
    /// 单行部分一致——null 续接格跳过、NUL 替换为空格、ANSI escape 已被
    /// parser 消化（matcher 只见可见字符）。
    static func lineString(terminal: Terminal, line: BufferLine) -> String {
        line.translateToString(
            trimRight: false,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: { terminal.getCharacter(for: $0) }
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }
}
