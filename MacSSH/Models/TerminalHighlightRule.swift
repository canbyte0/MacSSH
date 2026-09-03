import Foundation

/// MacSSH 1.1 Phase 6：终端字符串自动高亮的数据模型。
///
/// 高亮规则是**纯偏好设置**（数量小、结构稳定、无关系、无查询），与
/// `AppLanguage` 同类，经 `TerminalHighlightStore` 存入 UserDefaults
/// （Codable JSON），不进入 SwiftData。
///
/// 安全边界：规则只影响 presentation（renderer background decoration），
/// 永不修改 PTY bytes / parser 输入 / BufferLine 内容 / 复制文本。

/// 高亮预设颜色。
///
/// 使用稳定 String rawValue 持久化；**禁止**直接序列化 `NSColor` / `CGColor`
/// （非稳定、跨版本不可迁移）。第一版不提供任意取色器。
enum TerminalHighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var id: String { rawValue }
}

/// 一条终端字符串高亮规则：`text` 以 literal substring 方式匹配终端行文本。
struct TerminalHighlightRule: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// 匹配文本（非空；存储前已 trim，matcher / UI 双重防御）。
    var text: String
    var color: TerminalHighlightColor
    var isCaseSensitive: Bool
    var isEnabled: Bool
    /// 优先级：升序；冲突时 first-rule-wins（次序键为 `id`，保证确定性）。
    var sortOrder: Int

    init(id: UUID = UUID(),
         text: String,
         color: TerminalHighlightColor = .red,
         isCaseSensitive: Bool = false,
         isEnabled: Bool = true,
         sortOrder: Int = 0) {
        self.id = id
        self.text = text
        self.color = color
        self.isCaseSensitive = isCaseSensitive
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
    }

    // MARK: - Codable（向前兼容）

    /// 手动解码：所有字段缺失时回退默认值。未来新增字段一律
    /// `decodeIfPresent + 默认值`，旧 JSON / 新 JSON 互相不 crash；
    /// 未知字段由 `JSONDecoder` 默认忽略。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        color = try container.decodeIfPresent(TerminalHighlightColor.self, forKey: .color) ?? .red
        isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

/// 高亮设置全集（全局开关 + 规则列表）。
struct TerminalHighlightSettings: Codable, Equatable, Sendable {
    /// 全局开关。默认 `true` + 空 `rules`：老用户升级后零视觉变化，
    /// 新增第一条规则立即生效（无需先找总开关）。
    var isHighlightEnabled: Bool
    var rules: [TerminalHighlightRule]

    init(isHighlightEnabled: Bool = true, rules: [TerminalHighlightRule] = []) {
        self.isHighlightEnabled = isHighlightEnabled
        self.rules = rules
    }

    static let `default` = TerminalHighlightSettings(isHighlightEnabled: true, rules: [])

    /// 按 `(sortOrder 升序, id 升序)` 的确定性优先级排序。
    var sortedRules: [TerminalHighlightRule] {
        rules.sorted {
            ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString)
        }
    }

    /// 排序后的**已启用**规则（matcher 输入）。
    var enabledRules: [TerminalHighlightRule] {
        sortedRules.filter(\.isEnabled)
    }

    // MARK: - Codable（向前兼容）

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isHighlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .isHighlightEnabled) ?? true
        rules = try container.decodeIfPresent([TerminalHighlightRule].self, forKey: .rules) ?? []
    }
}
