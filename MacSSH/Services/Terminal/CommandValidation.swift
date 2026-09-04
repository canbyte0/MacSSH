import Foundation

/// MacSSH 1.1 Phase 7：SavedCommand 校验工具。
///
/// Phase 7A 验收 §22 / 任务书 §5–§6 的完整 control-character policy：
/// - 拒绝：空 / 纯 whitespace / NUL(U+0000) / CR(U+000D) / LF(U+000A) /
///   U+2028 / U+2029（视作 multiline）；
/// - 允许：TAB(U+0009) / ESC(U+001B) / BEL(U+0007) 等 C0（合法命令字符，
///   如 `printf '\a'`、`echo -e '\e[31m'`）；
/// - 允许单行多命令：`cd /tmp && ls`。
///
/// validation 用 trim 判断空，但 storage 保存用户原文（任务书 §71）。
/// Store 层与 UI 层**双重校验**。
enum CommandValidation {
    /// 拒绝的换行 / 行分隔 Unicode scalar。
    private static let rejectedNewlineScalars: Set<UInt32> = [
        0x000A, // LF
        0x000D, // CR
        0x2028, // LINE SEPARATOR
        0x2029, // PARAGRAPH SEPARATOR
    ]

    /// command 是否应被拒绝保存。true = 无效；false = 有效。
    ///
    /// 校验顺序：trim 判空 → NUL → 换行类。任一命中即拒绝。
    static func isRejected(_ command: String) -> Bool {
        // 1. 空 / 纯 whitespace（trim 判空，任务书 §71）。
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        // 2. NUL（永非合法命令字符；可截断字符串 / 破坏 shell）。
        if command.contains("\u{0}") {
            return true
        }
        // 3. 换行类（CR / LF / U+2028 / U+2029 → multiline）。
        for scalar in command.unicodeScalars {
            if rejectedNewlineScalars.contains(scalar.value) {
                return true
            }
        }
        return false
    }
}
