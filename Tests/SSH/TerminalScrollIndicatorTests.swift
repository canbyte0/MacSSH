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
}
