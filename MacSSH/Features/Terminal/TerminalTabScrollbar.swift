import AppKit
import SwiftUI

/// 将细横向滚动条挂到现有 SwiftUI ScrollView，保持标签栏布局和滚动手势。
struct TerminalTabScrollbarBridge: NSViewRepresentable {
    let probe: TerminalTabScrollbarProbe
    let accessibilityLabel: String

    func makeNSView(context: Context) -> TerminalTabScrollbarProbe { probe }

    func updateNSView(_ nsView: TerminalTabScrollbarProbe, context: Context) {
        nsView.scroller.setAccessibilityLabel(accessibilityLabel)
        nsView.scheduleAttachment()
    }

    static func dismantleNSView(_ nsView: TerminalTabScrollbarProbe, coordinator: Void) {
        nsView.detach()
    }
}

/// 由 SwiftUI 管理控件的布局和命中，避免 HostingScrollView 吞掉外加子视图的鼠标事件。
struct TerminalTabScrollbarTrack: NSViewRepresentable {
    let probe: TerminalTabScrollbarProbe

    func makeNSView(context: Context) -> TerminalTabScroller { probe.scroller }
    func updateNSView(_ nsView: TerminalTabScroller, context: Context) {}
}

/// 零尺寸探针负责连接原生滚动容器；通知仅监听自身的 clip/document view。
final class TerminalTabScrollbarProbe: NSView {
    let scroller = TerminalTabScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 8))
    private weak var scrollView: NSScrollView?
    private weak var observedDocument: NSView?
    private var attachmentScheduled = false

    init(accessibilityLabel: String) {
        super.init(frame: .zero)
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.target = self
        scroller.action = #selector(scrollFromControl(_:))
        scroller.setAccessibilityLabel(accessibilityLabel)
        scroller.setAccessibilityIdentifier("tabBar.horizontalScrollbar")
        scroller.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit { detach() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { detach() } else { scheduleAttachment() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAttachment()
    }

    /// 等 SwiftUI 完成挂接后寻找 NSScrollView；合并同一轮更新，不轮询。
    func scheduleAttachment() {
        guard !attachmentScheduled else { return }
        attachmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachmentScheduled = false
            self.attachIfNeeded()
        }
    }

    func attachIfNeeded() {
        guard let enclosing = enclosingScrollView,
              let document = enclosing.documentView else { return }
        if scrollView !== enclosing || observedDocument !== document {
            detach()
            scrollView = enclosing
            observedDocument = document
            scroller.hostScrollView = enclosing

            // 触控板滚动、窗口 resize、标签增删和重命名均通过几何通知同步。
            enclosing.contentView.postsBoundsChangedNotifications = true
            enclosing.contentView.postsFrameChangedNotifications = true
            document.postsFrameChangedNotifications = true
            for (name, view) in [
                (NSView.boundsDidChangeNotification, enclosing.contentView),
                (NSView.frameDidChangeNotification, enclosing.contentView),
                (NSView.frameDidChangeNotification, document)
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(geometryDidChange(_:)), name: name, object: view
                )
            }
        }
        synchronize()
    }

    /// 页面离开或容器替换时隐藏控件并移除通知，覆盖层生命周期交给 SwiftUI。
    func detach() {
        NotificationCenter.default.removeObserver(self)
        scroller.isHidden = true
        scroller.hostScrollView = nil
        scrollView = nil
        observedDocument = nil
    }

    @objc private func geometryDidChange(_ notification: Notification) { synchronize() }

    /// 内容缩短时同时收敛滚动位置，防止关闭末尾标签后留下一块空白。
    private func synchronize() {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        // 新版 macOS 会把容器延伸至侧栏下方；contentInsets 才界定实际可见区域。
        let insets = clip.contentInsets
        let viewportWidth = max(0, clip.bounds.width - insets.left - insets.right)
        let document = clip.documentRect
        let minimumX = document.minX - insets.left
        let maximumOffset = max(0, document.width - viewportWidth)
        let offset = min(maximumOffset, max(0, clip.bounds.minX - minimumX))
        if abs(clip.bounds.minX - minimumX - offset) > 0.5 {
            clip.scroll(to: NSPoint(x: minimumX + offset, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        }
        scroller.isHidden = maximumOffset <= 0.5
        scroller.isEnabled = maximumOffset > 0.5
        scroller.knobProportion = document.width > 0 ? min(1, viewportWidth / document.width) : 1
        scroller.doubleValue = maximumOffset > 0 ? Double(offset / maximumOffset) : 0
        scroller.needsDisplay = true
    }

    /// 原生 NSScroller 负责拖动、轨道点击和辅助功能动作，本层只设置滚动位置。
    @objc private func scrollFromControl(_ sender: NSScroller) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let document = clip.documentRect
        let insets = clip.contentInsets
        let viewportWidth = max(0, clip.bounds.width - insets.left - insets.right)
        let minimumX = document.minX - insets.left
        let maximumOffset = max(0, document.width - viewportWidth)
        var offset = CGFloat(sender.doubleValue) * maximumOffset
        switch sender.hitPart {
        case .decrementPage: offset = clip.bounds.minX - minimumX - viewportWidth
        case .incrementPage: offset = clip.bounds.minX - minimumX + viewportWidth
        default: break
        }
        clip.scroll(to: NSPoint(
            x: minimumX + min(maximumOffset, max(0, offset)), y: clip.bounds.minY
        ))
        scrollView.reflectScrolledClipView(clip)
        synchronize()
    }
}

/// 8 pt 命中区域内仅绘制 3 pt 细滑块，拖动跟踪仍使用 NSScroller 原生实现。
final class TerminalTabScroller: NSScroller {
    weak var hostScrollView: NSScrollView?

    /// NSScroller 默认命中区域按标准厚度计算；扩展到完整 8 pt，包含底部细线。
    override func testPart(_ point: NSPoint) -> NSScroller.Part {
        let local = convert(point, from: nil)
        guard isEnabled, !isHidden, bounds.contains(local) else { return .noPart }
        let knob = rect(for: .knob)
        if local.x < knob.minX { return .decrementPage }
        if local.x > knob.maxX { return .incrementPage }
        return .knob
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: thinRect(slotRect), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnob() {
        NSColor.labelColor.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: thinRect(rect(for: .knob)), xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// 滚轮在滑块上方时仍交给原来的标签滚动容器。
    override func scrollWheel(with event: NSEvent) {
        hostScrollView?.scrollWheel(with: event)
    }

    private func thinRect(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: isFlipped ? bounds.height - 3.5 : 0.5, width: rect.width, height: 3)
    }
}
