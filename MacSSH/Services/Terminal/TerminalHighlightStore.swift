import Foundation
import Observation

/// MacSSH 1.1 Phase 6：高亮规则存储（UserDefaults + Codable JSON）。
///
/// 职责（仅存储与校验）：
/// - load / save（单 key 原子写）；
/// - 全局开关；
/// - 规则 CRUD（含空文本防御——UI 与本层**双重防御**）；
/// - 变更通知（`onSettingsChanged` 回调，由 Coordinator 挂接广播重绘）。
///
/// 不包含：TerminalView / PTY / renderer 逻辑。
///
/// 安全：规则文本可能包含 IP / hostname / 用户名等用户数据——日志只记录
/// 规则数量与聚合信息，**禁止**记录规则文本或命中文本。
@MainActor
@Observable
final class TerminalHighlightStore {

    /// 高亮设置的唯一 UserDefaults key（集中管理，禁止散落硬编码）。
    static let storageKey = "macssh.terminalHighlightSettings"

    private let userDefaults: UserDefaults

    /// 当前设置（变更经本类 API，直接读写不落盘）。
    private(set) var settings: TerminalHighlightSettings

    /// 每次成功变更 +1。供测试与调试观察；provider **不做**跨帧缓存，
    /// 渲染时始终读当前 `settings`。
    private(set) var revision: Int = 0

    /// 设置变更回调（Coordinator 挂接，触发全部 live TerminalView 重绘）。
    /// 弱引用挂接方由 Coordinator 自行保证（closure 内 `[weak self]`）。
    var onSettingsChanged: (() -> Void)?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.settings = Self.load(from: userDefaults)
    }

    // MARK: - 读取 / 回退

    /// 读取设置：key 不存在 → 默认（`isHighlightEnabled = true, rules = []`，
    /// 老用户零视觉变化）；损坏 JSON → 回退默认并记录**不含规则内容**的安全日志。
    static func load(from userDefaults: UserDefaults) -> TerminalHighlightSettings {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(TerminalHighlightSettings.self, from: data)
        } catch {
            // 不记录解码错误中的任何 payload 片段（可能含用户规则文本）。
            AppLogger.app.error(
                "Terminal highlight settings failed to decode, falling back to defaults"
            )
            return .default
        }
    }

    // MARK: - 全局开关

    func setHighlightEnabled(_ enabled: Bool) {
        mutate { $0.isHighlightEnabled = enabled; return true }
    }

    // MARK: - 规则 CRUD

    /// 新增规则（文本 trim 后非空才接受）。`sortOrder` 追加到队尾。
    @discardableResult
    func addRule(text: String,
                 color: TerminalHighlightColor,
                 isCaseSensitive: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let nextOrder = (settings.rules.map(\.sortOrder).max() ?? -1) + 1
        let rule = TerminalHighlightRule(id: UUID(),
                                         text: trimmed,
                                         color: color,
                                         isCaseSensitive: isCaseSensitive,
                                         isEnabled: true,
                                         sortOrder: nextOrder)
        return mutate { $0.rules.append(rule); return true }
    }

    /// 编辑既有规则（文本 trim 后非空才接受；未找到 id 返回 false）。
    @discardableResult
    func updateRule(id: UUID,
                    text: String,
                    color: TerminalHighlightColor,
                    isCaseSensitive: Bool,
                    isEnabled: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return mutate { settings in
            guard let index = settings.rules.firstIndex(where: { $0.id == id }) else {
                return false
            }
            settings.rules[index].text = trimmed
            settings.rules[index].color = color
            settings.rules[index].isCaseSensitive = isCaseSensitive
            settings.rules[index].isEnabled = isEnabled
            return true
        }
    }

    /// 单条规则启用 / 禁用（快速开关，不改动其他字段）。
    func setRuleEnabled(id: UUID, isEnabled: Bool) {
        _ = mutate { settings in
            guard let index = settings.rules.firstIndex(where: { $0.id == id }) else {
                return false
            }
            settings.rules[index].isEnabled = isEnabled
            return true
        }
    }

    /// 删除规则。未找到 id 安全返回 false（幂等）。
    @discardableResult
    func deleteRule(id: UUID) -> Bool {
        mutate { settings in
            guard let index = settings.rules.firstIndex(where: { $0.id == id }) else {
                return false
            }
            settings.rules.remove(at: index)
            return true
        }
    }

    /// 整体替换规则列表（Settings UI 批量编辑后一次性落盘）。
    /// 内部会逐条 trim + 去空文本，但**不**重新生成 id 或 sortOrder
    /// ——调用方负责 id 稳定性与 sortOrder 排序意图。
    func replaceAllRules(_ rules: [TerminalHighlightRule]) {
        let cleaned = rules.compactMap { rule -> TerminalHighlightRule? in
            let trimmed = rule.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            var copy = rule
            copy.text = trimmed
            return copy
        }
        _ = mutate { $0.rules = cleaned; return true }
    }

    // MARK: - 持久化（内部）

    /// 通用变更通道：闭包内修改 snapshot、校验是否真有变化、
    /// 持久化、递增 revision、回调 Coordinator。
    /// 闭包返回 false 表示无改动（未找到 id / 校验失败），跳过副作用。
    @discardableResult
    private func mutate(_ apply: (inout TerminalHighlightSettings) -> Bool) -> Bool {
        var copy = self.settings
        guard apply(&copy) else { return false }
        guard copy != self.settings else { return false }
        self.settings = copy
        persist(self.settings)
        revision &+= 1
        AppLogger.app.info("Terminal highlight settings updated, rule count=\(self.settings.rules.count, privacy: .public), enabled=\(self.settings.isHighlightEnabled, privacy: .public)")
        onSettingsChanged?()
        return true
    }

    /// 原子写：JSONEncoder 输出后经 `UserDefaults.set(_:forKey:)`，
    /// 由系统保证首字节完整 / 全无；不写中间文件，避免半写 JSON。
    private func persist(_ settings: TerminalHighlightSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            userDefaults.set(data, forKey: Self.storageKey)
        } catch {
            // 不记录 payload；只记录事件本身。
            AppLogger.app.error("Terminal highlight settings failed to encode")
        }
    }}
