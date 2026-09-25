import AppKit
import XCTest
@testable import Codeboard

@MainActor
final class TerminalTileLayoutTests: XCTestCase {
    func testTerminalContentResizesOnceWhenDeferredTileResizeCommits() {
        let contentView = NSView(frame: .zero)
        let container = CanvasTileContainerView(title: "Terminal", contentView: contentView)
        container.setCanvasFrame(CGRect(x: 10, y: 20, width: 400, height: 300))

        XCTAssertEqual(contentView.frame, CGRect(x: 0, y: 0, width: 400, height: 300))

        container.setContentResizeDeferred(true)
        container.setCanvasFrame(CGRect(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(contentView.frame, CGRect(x: 0, y: 0, width: 400, height: 300))

        container.setContentResizeDeferred(false)
        XCTAssertEqual(contentView.frame, CGRect(x: 0, y: 0, width: 800, height: 600))
    }
}
