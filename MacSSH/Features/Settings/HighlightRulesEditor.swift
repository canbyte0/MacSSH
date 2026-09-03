import SwiftUI

/// MacSSH 1.1 Phase 6：终端字符串高亮规则编辑器（设置 → Terminal → 高亮）。
///
/// 仅使用 macOS 原生 Form 控件，不引入自定义绘制；与现有 SettingsView 风格一致。
/// 编辑路径全部经 `TerminalHighlightStore` 落盘 + 触发 Coordinator 广播重绘，
/// 不重建任何 TerminalView / Shell / SSH。
struct HighlightRulesEditor: View {
    @Bindable var store: TerminalHighlightStore
    @Environment(\.locale) private var locale

    @State private var editingRule: TerminalHighlightRule?
    @State private var draftText: String = ""
    @State private var draftColor: TerminalHighlightColor = .red
    @State private var draftCaseSensitive: Bool = false
    @State private var draftEnabled: Bool = true
    @State private var textError: Bool = false

    /// 全零 UUID 作为"新建规则"标识，sheet 据此切换标题与提交分支。
    private static let newRuleID = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("settings.terminal.highlight.enable", isOn: highlightEnabledBinding)

            Divider()

            if store.settings.rules.isEmpty {
                Text("settings.terminal.highlight.empty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.settings.sortedRules) { rule in
                    HighlightRuleRow(rule: rule,
                                     locale: locale,
                                     onToggle: { store.setRuleEnabled(id: rule.id, isEnabled: $0) },
                                     onEdit: { startEditing(rule) },
                                     onDelete: { store.deleteRule(id: rule.id) })
                }
            }

            Button("settings.terminal.highlight.add") {
                startEditing(nil)
            }
            .buttonStyle(AppInteractiveButtonStyle(baseStyle: BorderlessButtonStyle()))
            .accessibilityIdentifier("settings.highlight.add")
        }
        .sheet(item: $editingRule) { rule in
            HighlightRuleEditorSheet(
                isNew: rule.id == Self.newRuleID,
                draftText: $draftText,
                draftColor: $draftColor,
                draftCaseSensitive: $draftCaseSensitive,
                draftEnabled: $draftEnabled,
                textError: $textError,
                onCancel: { editingRule = nil },
                onSave: {
                    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        textError = true
                        return
                    }
                    if rule.id == Self.newRuleID {
                        store.addRule(text: trimmed,
                                      color: draftColor,
                                      isCaseSensitive: draftCaseSensitive)
                    } else {
                        store.updateRule(id: rule.id,
                                         text: trimmed,
                                         color: draftColor,
                                         isCaseSensitive: draftCaseSensitive,
                                         isEnabled: draftEnabled)
                    }
                    editingRule = nil
                }
            )
        }
    }

    private var highlightEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.isHighlightEnabled },
            set: { store.setHighlightEnabled($0) }
        )
    }

    /// `nil` = 新建占位规则；既有规则 = 编辑。用全零 UUID 标识新建。
    private func startEditing(_ rule: TerminalHighlightRule?) {
        editingRule = rule ?? TerminalHighlightRule(
            id: Self.newRuleID, text: "", color: .red,
            isCaseSensitive: false, isEnabled: true, sortOrder: 0
        )
        if let rule {
            draftText = rule.text
            draftColor = rule.color
            draftCaseSensitive = rule.isCaseSensitive
            draftEnabled = rule.isEnabled
        } else {
            draftText = ""
            draftColor = .red
            draftCaseSensitive = false
            draftEnabled = true
        }
        textError = false
    }
}

/// 单条规则行：色点 + 文本 + 启用开关 + Edit + Delete。
private struct HighlightRuleRow: View {
    let rule: TerminalHighlightRule
    let locale: Locale
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            Circle()
                .fill(Color(nsColor: TerminalHighlightPalette.swatchColor(
                    for: rule.color, dark: colorScheme == .dark)))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.text)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                Text(rule.isCaseSensitive
                     ? L10n.string("settings.terminal.highlight.case_sensitive",
                                   defaultValue: "Case Sensitive", locale: locale)
                     : L10n.string("settings.terminal.highlight.case_insensitive",
                                   defaultValue: "Case Insensitive", locale: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { newValue in onToggle(newValue) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(Text("settings.terminal.highlight.enabled"))

            Button("action.edit") { onEdit() }
                .buttonStyle(AppInteractiveButtonStyle(baseStyle: BorderlessButtonStyle()))
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(AppInteractiveButtonStyle(baseStyle: BorderlessButtonStyle()))
            .accessibilityLabel(Text("settings.terminal.highlight.delete"))
        }
        .padding(.vertical, 2)
    }
}

/// 新建 / 编辑 sheet。
private struct HighlightRuleEditorSheet: View {
    let isNew: Bool
    @Binding var draftText: String
    @Binding var draftColor: TerminalHighlightColor
    @Binding var draftCaseSensitive: Bool
    @Binding var draftEnabled: Bool
    @Binding var textError: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew
                 ? "settings.terminal.highlight.add"
                 : "action.edit")
                .font(.headline)

            TextField("settings.terminal.highlight.text", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.highlight.text")
            if textError {
                Text("validation.highlight_text_required")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Picker("settings.terminal.highlight.color", selection: $draftColor) {
                ForEach(TerminalHighlightColor.allCases) { color in
                    Text(colorLabel(color)).tag(color)
                }
            }
            .pickerStyle(.menu)

            Toggle("settings.terminal.highlight.case_sensitive", isOn: $draftCaseSensitive)
            if !isNew {
                Toggle("settings.terminal.highlight.enabled", isOn: $draftEnabled)
            }

            HStack {
                Button("action.cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("action.save") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    /// 颜色名按现有命名体系走本地化 key。使用显式 switch 确保 xcstrings key
    /// 静态可扫描（LocalizationTests 用正则扫描源码字面量）。
    private func colorLabel(_ color: TerminalHighlightColor) -> String {
        switch color {
        case .red:    return L10n.string("settings.terminal.highlight.color.red",    defaultValue: "Red",    locale: .current)
        case .orange: return L10n.string("settings.terminal.highlight.color.orange", defaultValue: "Orange", locale: .current)
        case .yellow: return L10n.string("settings.terminal.highlight.color.yellow", defaultValue: "Yellow", locale: .current)
        case .green:  return L10n.string("settings.terminal.highlight.color.green",  defaultValue: "Green",  locale: .current)
        case .blue:   return L10n.string("settings.terminal.highlight.color.blue",   defaultValue: "Blue",   locale: .current)
        case .purple: return L10n.string("settings.terminal.highlight.color.purple", defaultValue: "Purple", locale: .current)
        case .gray:   return L10n.string("settings.terminal.highlight.color.gray",   defaultValue: "Gray",   locale: .current)
        }
    }
}
