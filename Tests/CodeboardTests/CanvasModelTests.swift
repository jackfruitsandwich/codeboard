import XCTest
@testable import Codeboard

final class CanvasModelTests: XCTestCase {
    func testMultiCellOccupancyPreventsOverlapAndClearsOnRemoval() {
        let model = CanvasModel()
        let first = UUID()
        let second = UUID()
        model.register(tileID: first, at: GridPoint(x: 0, y: 0), size: GridSize(width: 2, height: 2))

        XCTAssertFalse(model.canPlace(tileID: second, at: GridPoint(x: 1, y: 1), size: .one))
        XCTAssertTrue(model.canPlace(tileID: second, at: GridPoint(x: 2, y: 1), size: .one))

        model.remove(tileID: first)
        XCTAssertTrue(model.canPlace(tileID: second, at: GridPoint(x: 1, y: 1), size: .one))
    }

    func testDirectionalFocusUsesGeometryAndRegistrationOrder() {
        let model = CanvasModel()
        let source = UUID()
        let near = UUID()
        let far = UUID()
        model.register(tileID: source, at: .origin)
        model.register(tileID: near, at: GridPoint(x: 1, y: 0))
        model.register(tileID: far, at: GridPoint(x: 3, y: 0))
        model.focus(tileID: source)

        XCTAssertEqual(model.nextFocus(from: source, direction: .right), near)
    }

    func testPreferredSpawnSkipsOccupiedCells() {
        let model = CanvasModel()
        let source = UUID()
        let blocker = UUID()
        model.register(tileID: source, at: .origin)
        model.register(tileID: blocker, at: GridPoint(x: 1, y: 0))

        XCTAssertEqual(
            model.nextSpawnPoint(near: source, preferredDirection: .right),
            GridPoint(x: 2, y: 0)
        )
    }
}
