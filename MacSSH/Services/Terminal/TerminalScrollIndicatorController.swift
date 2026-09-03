import AppKit
import SwiftTerm

/// 让 SwiftTerm 保留原生滚动交互，同时只显示与内容比例一致的短滑块。
///
/// SwiftTerm 的 `NSScroller` 会覆盖终端全部高度。即使滚动数据正确，某些
/// macOS 外观下仍会绘制整条浅色轨道，看起来像“滑块始终占满一页”。本控制器
/// 仅把原生滚动器设为透明，原生滚轮、点击和拖拽命中区域仍然保留；可见部分
/// 由一个不接收鼠标事件的轻量覆盖层绘制。
@MainActor
final class TerminalScrollIndicatorController {
    /// 测试与辅助功能检查使用的稳定标识。
    static let accessibilityIdentifier = "terminal.scrollIndicator"

    private weak var terminalView: TerminalView?
    private weak var nativeScroller: NSScroller?
    private let indicatorView = TerminalScrollIndicatorView()

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

        update()
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

    func update(canScroll: Bool, proportion: Double, position: Double) {
        self.canScroll = canScroll
        self.proportion = proportion
        self.position = position
        isHidden = !canScroll
        updateThumbFrame()
    }

    private func updateThumbFrame() {
        guard canScroll else {
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
