import XCTest
@testable import Codeboard

@MainActor
final class BrowserTileStateTests: XCTestCase {
    func testInitialURLIsAvailableForImmediateWorkspaceSave() {
        let url = URL(string: "https://example.invalid/restored")!
        let tile = BrowserTile(index: 1, position: .origin, initialURL: url)
        defer { tile.destroy() }

        XCTAssertEqual(tile.currentURL, url)
    }
}
