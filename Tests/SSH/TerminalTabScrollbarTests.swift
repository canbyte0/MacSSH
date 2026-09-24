import AppKit
import SwiftUI
import XCTest

@testable import MacSSH

/// 使用真实 NSScrollView 验证双向同步、内容收缩与挂接生命周期。
@MainActor
final class TerminalTabScrollbarTests: XCTestCase {
    private var scrollView: NSScrollView!
    private var document: NSView!
    private var probe: TerminalTabScrollbarProbe!

    override func setUp() async throws {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 42))
        document = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 42))
        scrollView.documentView = document
        probe = TerminalTabScrollbarProbe(accessibilityLabel: "Terminal tabs")
        document.addSubview(probe)
        probe.attachIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        probe.removeFromSuperview()
        probe.detach()
        probe = nil
        document = nil
        scrollView = nil
    }

    /// 溢出时常显、保持原来的可视高度，且原生辅助功能方向为水平。
    func testOverflowShowsHorizontalScrollerWithoutResizingViewport() {
        XCTAssertFalse(probe.scroller.isHidden)
        XCTAssertEqual(probe.scroller.knobProportion, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentView.bounds.height, 42, accuracy: 0.001)
        XCTAssertEqual(probe.scroller.frame.height, 8, accuracy: 0.001)
        XCTAssertEqual(probe.scroller.accessibilityOrientation(), .horizontal)
    }

    /// 触控板最终改变 clip bounds；通知必须同步滑块而无需主动刷新。
    func testViewportScrollingUpdatesKnob() {
        scrollView.contentView.scroll(to: NSPoint(x: 400, y: 0))
        XCTAssertEqual(probe.scroller.doubleValue, 0.5, accuracy: 0.001)
    }

    /// 原生控件发出 action 时，文档必须能够准确到达两个端点。
    func testScrollerActionReachesBothEnds() {
        for (value, expectedOffset) in [(1.0, 800.0), (0.0, 0.0)] {
            probe.scroller.doubleValue = value
            XCTAssertTrue(probe.scroller.sendAction(probe.scroller.action, to: probe.scroller.target))
            XCTAssertEqual(scrollView.contentView.bounds.minX, expectedOffset, accuracy: 0.001)
        }
    }

    /// 删除末尾标签会缩短文档；当前偏移应立即收敛并隐藏无用滚动条。
    func testShrinkingContentClampsOffsetAndHidesScroller() {
        scrollView.contentView.scroll(to: NSPoint(x: 800, y: 0))
        document.setFrameSize(NSSize(width: 300, height: 42))
        XCTAssertTrue(probe.scroller.isHidden)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.001)
        XCTAssertEqual(probe.scroller.doubleValue, 0, accuracy: 0.001)
    }

    /// 窗口变宽后无需重建桥接，也必须移除不再需要的滚动条。
    func testViewportResizeUpdatesVisibilityAndProportion() {
        scrollView.setFrameSize(NSSize(width: 600, height: 42))
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(probe.scroller.knobProportion, 0.5, accuracy: 0.001)
        scrollView.setFrameSize(NSSize(width: 1400, height: 42))
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertTrue(probe.scroller.isHidden)
    }

    /// SwiftUI 多次 update 不得重复添加控件，页面离开后也不得留下控件。
    func testRepeatedAttachmentAndRemovalDoNotLeaveDuplicateControls() {
        probe.attachIfNeeded()
        probe.attachIfNeeded()
        XCTAssertTrue(probe.scroller.hostScrollView === scrollView)
        probe.removeFromSuperview()
        XCTAssertNil(probe.scroller.hostScrollView)
        XCTAssertTrue(probe.scroller.isHidden)
        // 解除观察后，旧容器滚动不应再次显示控件。
        scrollView.contentView.scroll(to: NSPoint(x: 400, y: 0))
        XCTAssertTrue(probe.scroller.isHidden)
    }

    /// 侧栏覆盖 220 pt 时，实际可见宽度为 900 pt，左端允许负 clip 偏移。
    func testSidebarContentInsetsPreserveFullScrollRange() {
        scrollView.setFrameSize(NSSize(width: 1120, height: 94))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsets(top: 0, left: 220, bottom: 0, right: 0)
        document.setFrameSize(NSSize(width: 1200, height: 94))
        probe.attachIfNeeded()
        XCTAssertEqual(probe.scroller.knobProportion, 0.75, accuracy: 0.001)
        for (value, expectedOffset) in [(0.0, -220.0), (1.0, 80.0)] {
            probe.scroller.doubleValue = value
            XCTAssertTrue(probe.scroller.sendAction(probe.scroller.action, to: probe.scroller.target))
            XCTAssertEqual(scrollView.contentView.bounds.minX, expectedOffset, accuracy: 0.001)
        }
    }

    /// 使用真实 SwiftUI 宿主，验证覆盖层的底部几何和完整细线命中区域。
    func testSwiftUIScrollViewPositionsScrollerAtBottom() async throws {
        let sharedProbe = TerminalTabScrollbarProbe(accessibilityLabel: "Tabs")
        let host = NSHostingView(rootView:
            ScrollView(.horizontal, showsIndicators: false) {
                Color.clear.frame(width: 1200, height: 42)
                    .background {
                        TerminalTabScrollbarBridge(probe: sharedProbe, accessibilityLabel: "Tabs")
                            .frame(width: 0, height: 0)
                    }
            }.frame(width: 400, height: 42)
                .overlay(alignment: .bottom) {
                    TerminalTabScrollbarTrack(probe: sharedProbe)
                        .frame(height: 8).padding(.horizontal, 8)
                }
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 42),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        // 仅遍历测试自身的视图树，不依赖 SwiftUI 私有类名。
        func findProbe(_ view: NSView) -> TerminalTabScrollbarProbe? {
            if let found = view as? TerminalTabScrollbarProbe { return found }
            return view.subviews.lazy.compactMap(findProbe).first
        }
        let bridge = try XCTUnwrap(findProbe(host))
        bridge.attachIfNeeded()
        let enclosing = try XCTUnwrap(bridge.enclosingScrollView)
        let trackRect = bridge.scroller.convert(bridge.scroller.bounds, to: host)
        XCTAssertEqual(trackRect.minX, 8, accuracy: 0.001)
        XCTAssertEqual(bridge.scroller.frame.width, enclosing.bounds.width - 16, accuracy: 0.001)
        XCTAssertEqual(bridge.scroller.frame.height, 8, accuracy: 0.001)
        let expectedY: CGFloat = host.isFlipped ? 34 : 0
        XCTAssertEqual(trackRect.minY, expectedY, accuracy: 0.001)
        // 标准 NSScroller 会漏掉薄控件底边；可见细线和上方留白都应可拖动。
        let knob = bridge.scroller.rect(for: .knob)
        for y in [0.5, 4.0, 7.5] {
            let point = bridge.scroller.convert(NSPoint(x: knob.midX, y: y), to: nil)
            XCTAssertEqual(bridge.scroller.testPart(point), .knob)
        }
        XCTAssertFalse(bridge.scroller.isHidden)
        bridge.detach()
        window.contentView = nil
    }
}
