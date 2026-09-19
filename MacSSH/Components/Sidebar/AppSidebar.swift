import AppKit
import SwiftUI

/// macOS 原生 Sidebar，只负责顶层页面选择。
struct AppSidebar: View {
    /// 与 AppState 双向绑定的页面选择。
    @Binding var selection: AppSection

    var body: some View {
        List(AppSection.allCases, selection: $selection) { section in
            Label {
                Text(section.titleKey)
            } icon: {
                Image(systemName: section.systemImage)
            }
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
