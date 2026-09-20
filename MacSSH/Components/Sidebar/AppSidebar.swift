import AppKit
import SwiftUI

/// macOS 原生 Sidebar，只负责顶层页面选择。
struct AppSidebar: View {
    /// 与 AppState 双向绑定的页面选择。
    @Binding var selection: AppSection

    var body: some View {
        List(AppSection.allCases, selection: $selection) { section in
            AppSidebarRow(
                section: section,
                isSelected: selection == section
            )
            .tag(section)
            .accessibilityIdentifier("sidebar.\(section.rawValue)")
        }
        .listStyle(.sidebar)
        .navigationTitle("MacSSH")
        .navigationSplitViewColumnWidth(
            min: AppTheme.Layout.sidebarMinimumWidth,
            ideal: AppTheme.Layout.sidebarIdealWidth,
            max: AppTheme.Layout.sidebarMaximumWidth
        )
        .background {
            // 为 SwiftUI 内部的 NSSplitView 设置稳定 autosave name；AppKit
            // 负责保存和恢复左侧栏分隔位置，包括完全退出后的下一次启动。
            NavigationSplitViewAutosaveBridge(
                autosaveName: NSSplitView.AutosaveName(
                    AppPreferenceKey.mainSplitViewAutosaveName
                )
            )
            .frame(width: 0, height: 0)
        }
        .accessibilityLabel("accessibility.main_sidebar")
    }
}

/// 顶层导航行：保留 List 原生选中样式，只为未选中项补充轻量悬停反馈。
private struct AppSidebarRow: View {
    /// SidebarListStyle 的行背景自身已有边缘布局；10 pt 可与系统选中底色对齐。
    private static let hoverBackgroundHorizontalInset: CGFloat = 10

    let section: AppSection
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Label {
            Text(section.titleKey)
        } icon: {
            Image(systemName: section.systemImage)
        }
        // 扩大到 List 行的完整内容宽度，让图标、标题和右侧空白都能触发悬停。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowBackground(sidebarRowBackground)
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: AppTheme.ButtonInteraction.hoverDuration),
            value: isHovering
        )
        .onHover { isHovering = $0 }
    }

    /// 选中项继续由系统绘制较深背景；未选中项悬停时显示更浅的圆角底色。
    private var sidebarRowBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.Spacing.compact)
            .fill(
                isHovering && !isSelected
                    ? Color.primary.opacity(0.04)
                    : Color.clear
            )
            // Retina 截图中的 4 px 差值对应 2 pt；10 pt 是 8 与 12 的正确中间值。
            .padding(.horizontal, Self.hoverBackgroundHorizontalInset)
    }
}

/// 把 SwiftUI `NavigationSplitView` 接入 AppKit 原生 divider autosave。
private struct NavigationSplitViewAutosaveBridge: NSViewRepresentable {
    let autosaveName: NSSplitView.AutosaveName

    func makeNSView(context: Context) -> SplitViewAutosaveProbe {
        SplitViewAutosaveProbe(autosaveName: autosaveName)
    }

    func updateNSView(_ nsView: SplitViewAutosaveProbe, context: Context) {
        nsView.autosaveName = autosaveName
        nsView.configureEnclosingSplitView()
    }
}

/// 零尺寸探针；加入视图树后向上寻找 NavigationSplitView 的垂直 NSSplitView。
private final class SplitViewAutosaveProbe: NSView {
    var autosaveName: NSSplitView.AutosaveName

    init(autosaveName: NSSplitView.AutosaveName) {
        self.autosaveName = autosaveName
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureEnclosingSplitView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingSplitView()
    }

    func configureEnclosingSplitView() {
        var ancestor = superview
        while let current = ancestor {
            if let splitView = current as? NSSplitView, splitView.isVertical {
                if splitView.autosaveName != autosaveName {
                    splitView.autosaveName = autosaveName
                }
                return
            }
            ancestor = current.superview
        }
    }
}
