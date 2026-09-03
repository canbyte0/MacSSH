import AppKit
import SwiftTerm
import XCTest
@testable import MacSSH

/// 终端短滚动滑块的几何与原生交互保留测试。
@MainActor
final class TerminalScrollIndicatorTests: XCTestCase {
    /// 超过一页时，滑块高度必须按可见内容比例缩短。
    func testThumbHeightMatchesVisibleContentProportion() {
        let geometry = TerminalScrollIndicatorGeometry.make(
            containerHeight: 1_000,
            proportion: 0.2,
            position: 0
        )

        XCTAssertEqual(geometry.height, 198.4, accuracy: 0.001)
        XCTAssertEqual(geometry.y, 4, accuracy: 0.001)
    }

    /// 滚动到底部时，短滑块必须停在底部内边距之上。
    func testThumbPositionTracksBottom() {
        let geometry = TerminalScrollIndicatorGeometry.make(
            containerHeight: 1_000,
            proportion: 0.2,
            position: 1
        )

        XCTAssertEqual(geometry.y + geometry.height, 996, accuracy: 0.001)
    }

    /// 内容非常长时仍保留最小可操作高度，且不会越过容器。
    func testVeryLongContentUsesMinimumThumbHeight() {
        let geometry = TerminalScrollIndicatorGeometry.make(
            containerHeight: 400,
            proportion: 0.001,
            position: 1
        )

        XCTAssertEqual(geometry.height, 24, accuracy: 0.001)
        XCTAssertEqual(geometry.y + geometry.height, 396, accuracy: 0.001)
    }

    /// 原生 NSScroller 只变透明、不隐藏，确保滚轮、点击和拖拽仍由原生控件处理。
    func testControllerHidesTrackWithoutRemovingNativeScroller() {
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let nativeScroller = terminalView.subviews.compactMap { $0 as? NSScroller }.first
        XCTAssertNotNil(nativeScroller)

        let controller = TerminalScrollIndicatorController(terminalView: terminalView)

        XCTAssertEqual(nativeScroller?.alphaValue, 0)
        XCTAssertFalse(nativeScroller?.isHidden ?? true)
        XCTAssertEqual(nativeScroller?.scrollerStyle, .legacy)
        XCTAssertTrue(
            terminalView.subviews.contains {
                $0.accessibilityIdentifier() == TerminalScrollIndicatorController.accessibilityIdentifier
            }
        )
        withExtendedLifetime(controller) {}
    }

    /// 光标命中计算必须区分滚动条、终端正文和终端外部。
    func testCursorRegionDistinguishesScrollerTerminalAndOutside() {
        let scrollerRect = NSRect(x: 783, y: 0, width: 17, height: 600)
        let terminalRect = NSRect(x: 0, y: 0, width: 800, height: 600)

        XCTAssertEqual(
            TerminalScrollCursorRegion.region(
                windowPoint: NSPoint(x: 794, y: 300),
                scrollerRectInWindow: scrollerRect,
                terminalRectInWindow: terminalRect,
                isScrollerVisible: true
            ),
            .scroller
        )
        XCTAssertEqual(
            TerminalScrollCursorRegion.region(
                windowPoint: NSPoint(x: 782, y: 300),
                scrollerRectInWindow: scrollerRect,
                terminalRectInWindow: terminalRect,
                isScrollerVisible: true
            ),
            .terminalContent
        )
        XCTAssertEqual(
            TerminalScrollCursorRegion.region(
                windowPoint: NSPoint(x: 900, y: 300),
                scrollerRectInWindow: scrollerRect,
                terminalRectInWindow: terminalRect,
                isScrollerVisible: true
            ),
            .outside
        )
    }

    /// 不可滚动时，原生滚动器区域应按终端正文处理，避免残留箭头。
    func testHiddenScrollerRegionUsesTerminalCursor() {
        XCTAssertEqual(
            TerminalScrollCursorRegion.region(
                windowPoint: NSPoint(x: 794, y: 300),
                scrollerRectInWindow: NSRect(x: 783, y: 0, width: 17, height: 600),
                terminalRectInWindow: NSRect(x: 0, y: 0, width: 800, height: 600),
                isScrollerVisible: false
            ),
            .terminalContent
        )
    }

    /// 从滚动条进入终端正文时必须恢复 I-beam，后续正文移动不重复覆盖光标。
    func testCursorStateRestoresIBeamWhenLeavingScrollerForTerminal() {
        var state = TerminalScrollCursorState()

        XCTAssertEqual(state.transition(to: .scroller), .showArrow)
        XCTAssertTrue(state.isPointerOverScroller)
        XCTAssertEqual(state.transition(to: .terminalContent), .showIBeam)
        XCTAssertFalse(state.isPointerOverScroller)
        XCTAssertNil(state.transition(to: .terminalContent))
    }

    /// 从滚动条进入其他界面区域时交还给 AppKit，不强制设置终端光标。
    func testCursorStateDoesNotForceIBeamOutsideTerminal() {
        var state = TerminalScrollCursorState()

        XCTAssertEqual(state.transition(to: .scroller), .showArrow)
        XCTAssertNil(state.transition(to: .outside))
        XCTAssertFalse(state.isPointerOverScroller)
    }

}
