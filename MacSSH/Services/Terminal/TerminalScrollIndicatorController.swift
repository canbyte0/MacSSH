import AppKit
import SwiftTerm

/// 让 SwiftTerm 保留原生滚动交互，同时只显示与内容比例一致的短滑块。
///
/// SwiftTerm 的 `NSScroller` 会覆盖终端全部高度。即使滚动数据正确，某些
/// macOS 外观下仍会绘制整条浅色轨道，看起来像“滑块始终占满一页”。本控制器
/// 仅把原生滚动器设为透明，并用轻量覆盖层绘制可见部分；覆盖层保持事件穿透，
/// 局部事件监听在原生滚动区域内恢复系统箭头。
@MainActor
final class TerminalScrollIndicatorController {
    /// 测试与辅助功能检查使用的稳定标识。
    static let accessibilityIdentifier = "terminal.scrollIndicator"

    private weak var terminalView: TerminalView?
    private weak var nativeScroller: NSScroller?
    private let indicatorView = TerminalScrollIndicatorView()
    private var cursorEventMonitor: Any?
    private var cursorState = TerminalScrollCursorState()

    init(terminalView: TerminalView) {
        self.terminalView = terminalView

        // SwiftTerm 在 TerminalView 初始化期间已经创建直接子级 NSScroller。
        // alpha 为 0 不影响 hit testing，因此拖拽、点击轨道等原生行为仍可用。
        if let scroller = terminalView.subviews.compactMap({ $0 as? NSScroller }).first {
            nativeScroller = scroller
            // legacy 样式不会自行执行 overlay 淡入动画，避免系统在滚动时
            // 把 alpha 改回 1；滚动器本身仍完整参与命中测试和 action。
            scroller.scrollerStyle = .legacy
            scroller.alphaValue = 0
        }

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        indicatorView.setAccessibilityElement(false)
        terminalView.addSubview(indicatorView, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            indicatorView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            indicatorView.topAnchor.constraint(equalTo: terminalView.topAnchor),
            indicatorView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            indicatorView.widthAnchor.constraint(equalToConstant: TerminalScrollIndicatorView.overlayWidth)
        ])

        installCursorEventMonitor()
        update()
    }

    isolated deinit {
        if let cursorEventMonitor {
            NSEvent.removeMonitor(cursorEventMonitor)
        }
    }

    /// 在输出、用户滚动或视图尺寸变化后同步短滑块的位置和长度。
    func update() {
        guard let terminalView else {
            return
        }

        // SwiftTerm 切换 Metal backing view 时可能调整子视图层级；重复确保原生
        // 轨道保持透明，并把可见短滑块放回最上层。
        nativeScroller?.alphaValue = 0
        terminalView.addSubview(indicatorView, positioned: .above, relativeTo: nil)
        indicatorView.update(
            canScroll: terminalView.canScroll,
            proportion: terminalView.scrollThumbsize,
            position: terminalView.scrollPosition
        )
    }

    private func installCursorEventMonitor() {
        cursorEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .cursorUpdate, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.updateCursor(for: event)
            return event
        }
    }

    private func updateCursor(for event: NSEvent) {
        guard
            let nativeScroller,
            let terminalView,
            event.window === nativeScroller.window
        else {
            cursorState.reset()
            return
        }

        let scrollerRectInWindow = nativeScroller.convert(nativeScroller.bounds, to: nil)
        let terminalRectInWindow = terminalView.convert(terminalView.bounds, to: nil)
        let region = TerminalScrollCursorRegion.region(
            windowPoint: event.locationInWindow,
            scrollerRectInWindow: scrollerRectInWindow,
            terminalRectInWindow: terminalRectInWindow,
            isScrollerVisible: !indicatorView.isHidden
        )

        switch cursorState.transition(to: region) {
        case .showArrow:
            // SwiftTerm 会在 cursorUpdate 中无条件设置 I-beam，因此必须等
            // 当前事件分发结束后再恢复箭头。
            DispatchQueue.main.async {
                NSCursor.arrow.set()
            }
        case .showIBeam:
            // 滚动条与终端正文属于 SwiftTerm 的同一个 cursor rect，离开滚动条时
            // AppKit 不一定再次触发 cursorUpdate；显式恢复终端原本的 I-beam。
            DispatchQueue.main.async {
                NSCursor.iBeam.set()
            }
        case nil:
            break
        }
    }
}

/// 纯命中计算：区分滚动条、终端正文和其他界面区域。
struct TerminalScrollCursorRegion {
    enum Region: Equatable {
        case scroller
        case terminalContent
        case outside
    }

    static func region(
        windowPoint: NSPoint,
        scrollerRectInWindow: NSRect,
        terminalRectInWindow: NSRect,
        isScrollerVisible: Bool
    ) -> Region {
        if isScrollerVisible, scrollerRectInWindow.contains(windowPoint) {
            return .scroller
        }
        if terminalRectInWindow.contains(windowPoint) {
            return .terminalContent
        }
        return .outside
    }
}

/// 记录上一次是否位于滚动条，使同一 cursor rect 内的离开动作也能恢复 I-beam。
struct TerminalScrollCursorState {
    enum Action: Equatable {
        case showArrow
        case showIBeam
    }

    private(set) var isPointerOverScroller = false

    mutating func transition(to region: TerminalScrollCursorRegion.Region) -> Action? {
        switch region {
        case .scroller:
            isPointerOverScroller = true
            return .showArrow
        case .terminalContent:
            let shouldRestoreIBeam = isPointerOverScroller
            isPointerOverScroller = false
            return shouldRestoreIBeam ? .showIBeam : nil
        case .outside:
            // 进入其他界面区域后，光标样式由对应控件和 AppKit 接管。
            isPointerOverScroller = false
            return nil
        }
    }

    mutating func reset() {
        isPointerOverScroller = false
    }
}

/// 纯几何计算，便于独立验证短滑块在顶部、底部及超长内容下的位置。
struct TerminalScrollIndicatorGeometry: Equatable {
    let y: CGFloat
    let height: CGFloat

    static func make(
        containerHeight: CGFloat,
        proportion: Double,
        position: Double,
        verticalInset: CGFloat = 4,
        minimumHeight: CGFloat = 24
    ) -> Self {
        let availableHeight = max(0, containerHeight - (verticalInset * 2))
        let clampedProportion = min(max(CGFloat(proportion), 0), 1)
        let thumbHeight = min(availableHeight, max(minimumHeight, availableHeight * clampedProportion))
        let travel = max(0, availableHeight - thumbHeight)
        let clampedPosition = min(max(CGFloat(position), 0), 1)

        // 本 View 使用 flipped 坐标：0 表示顶部，1 表示底部。
        return Self(
            y: verticalInset + (travel * clampedPosition),
            height: thumbHeight
        )
    }
}

/// 只负责绘制可见滑块；所有鼠标事件都穿透给下方原生 NSScroller。
private final class TerminalScrollIndicatorView: NSView {
    static let overlayWidth: CGFloat = 11
    static let thumbWidth: CGFloat = 5
    static let trailingInset: CGFloat = 3
    static let verticalInset: CGFloat = 4
    static let minimumThumbHeight: CGFloat = 24

    private let thumbLayer = CALayer()
    private var canScroll = false
    private var proportion = 1.0
    private var position = 0.0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        thumbLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull()
        ]
        layer?.addSublayer(thumbLayer)
        updateColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.addSublayer(thumbLayer)
        updateColor()
    }

    /// 覆盖层绝不拦截点击、拖拽或滚轮事件。
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        updateThumbFrame()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 局部事件监听只接收本 App 的 mouseMoved；允许窗口发送该事件。
        window?.acceptsMouseMovedEvents = true
    }

    func update(canScroll: Bool, proportion: Double, position: Double) {
        self.canScroll = canScroll
        self.proportion = proportion
        self.position = position
        isHidden = !canScroll
        updateThumbFrame()
    }

    private func updateThumbFrame() {
        guard canScroll else {
            thumbLayer.frame = .zero
            return
        }

        let geometry = TerminalScrollIndicatorGeometry.make(
            containerHeight: bounds.height,
            proportion: proportion,
            position: position
        )
        thumbLayer.frame = CGRect(
            x: bounds.width - Self.trailingInset - Self.thumbWidth,
            y: geometry.y,
            width: Self.thumbWidth,
            height: geometry.height
        )
        thumbLayer.cornerRadius = Self.thumbWidth / 2
    }

    private func updateColor() {
        thumbLayer.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.7).cgColor
    }
}

/// LocalProcessTerminalView 会占用 `terminalDelegate`；通过子类转发滚动通知，
/// 不替换 SwiftTerm 内部 delegate，也就不会破坏 PTY 输入输出。
final class ScrollTrackingLocalProcessTerminalView: LocalProcessTerminalView {
    var scrollIndicatorNeedsUpdate: (() -> Void)?

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        scrollIndicatorNeedsUpdate?()
    }
}
