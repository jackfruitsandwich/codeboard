import XCTest
@testable import Codeboard

final class CanvasControlTests: XCTestCase {
    func testUpdateAllSwapsTilesThatWouldCollideOneAtATime() {
        let model = CanvasModel()
        let left = UUID()
        let right = UUID()
        model.register(tileID: left, at: .origin, size: GridSize(width: 2, height: 1))
        model.register(tileID: right, at: GridPoint(x: 2, y: 0), size: GridSize(width: 2, height: 1))

        XCTAssertTrue(model.updateAll([
            left: GridRect(origin: GridPoint(x: 2, y: 0), size: GridSize(width: 2, height: 1)),
            right: GridRect(origin: .origin, size: GridSize(width: 2, height: 1)),
        ]))
        XCTAssertEqual(model.point(for: left), GridPoint(x: 2, y: 0))
        XCTAssertEqual(model.point(for: right), .origin)
        XCTAssertFalse(model.canPlace(tileID: UUID(), at: GridPoint(x: 3, y: 0), size: .one))
    }

    func testUpdateAllRejectsOverlapAndLeavesEverythingInPlace() {
        let model = CanvasModel()
        let moving = UUID()
        let other = UUID()
        let fixed = UUID()
        model.register(tileID: moving, at: .origin)
        model.register(tileID: other, at: GridPoint(x: 1, y: 0))
        model.register(tileID: fixed, at: GridPoint(x: 5, y: 5), size: GridSize(width: 2, height: 2))

        XCTAssertFalse(model.updateAll([
            moving: GridRect(origin: GridPoint(x: 0, y: 3), size: .one),
            other: GridRect(origin: GridPoint(x: 6, y: 6), size: .one),
        ]))
        XCTAssertEqual(model.point(for: moving), .origin)
        XCTAssertEqual(model.point(for: other), GridPoint(x: 1, y: 0))
        XCTAssertFalse(model.canPlace(tileID: UUID(), at: .origin, size: .one))
        XCTAssertFalse(model.canPlace(tileID: UUID(), at: GridPoint(x: 1, y: 0), size: .one))
        XCTAssertTrue(model.canPlace(tileID: UUID(), at: GridPoint(x: 0, y: 3), size: .one))

        XCTAssertFalse(model.updateAll([
            moving: GridRect(origin: GridPoint(x: 0, y: 3), size: GridSize(width: 2, height: 1)),
            other: GridRect(origin: GridPoint(x: 1, y: 3), size: .one),
        ]))
        XCTAssertEqual(model.point(for: moving), .origin)
    }

    func testUpdateAllRejectsUnknownTiles() {
        let model = CanvasModel()
        XCTAssertFalse(model.updateAll([UUID(): GridRect(origin: .origin, size: .one)]))
    }

    func testParsesNewTerminalWithPlacementAndCommand() throws {
        let command = try CanvasControlCommand.parse(name: "new-terminal", arguments: [
            "x": 2, "y": -1, "width": 2, "height": 3,
            "cwd": "~/hack", "command": "claude --resume abc --fork-session", "focus": true,
        ])
        guard case .newTerminal(let origin, let span, let cwd, let shellCommand, let focus) = command else {
            return XCTFail("expected new-terminal, got \(command)")
        }
        XCTAssertEqual(origin, GridPoint(x: 2, y: -1))
        XCTAssertEqual(span, GridSize(width: 2, height: 3))
        XCTAssertEqual(cwd, "~/hack")
        XCTAssertEqual(shellCommand, "claude --resume abc --fork-session")
        XCTAssertTrue(focus)
    }

    func testNewTerminalWithoutPlacementDefaultsToOneCellAnywhere() throws {
        guard case .newTerminal(let origin, let span, _, _, let focus) = try CanvasControlCommand.parse(
            name: "new-terminal",
            arguments: [:]
        ) else {
            return XCTFail("expected new-terminal")
        }
        XCTAssertNil(origin)
        XCTAssertEqual(span, .one)
        XCTAssertFalse(focus)
    }

    func testPlaceKeepsSpanOptionalAndAcceptsIndexReferences() throws {
        guard case .place(let placements) = try CanvasControlCommand.parse(name: "place", arguments: [
            "tiles": [
                ["tile": "3f2a", "x": 0, "y": 0, "width": 2, "height": 2],
                ["tile": 4, "x": 2, "y": 0],
            ],
        ]) else {
            return XCTFail("expected place")
        }
        XCTAssertEqual(placements.map(\.tile), ["3f2a", "4"])
        XCTAssertEqual(placements[0].span, GridSize(width: 2, height: 2))
        XCTAssertNil(placements[1].span)
    }

    func testRejectsHalfSpecifiedGeometryAndUnknownCommands() {
        XCTAssertThrowsError(try CanvasControlCommand.parse(name: "new-terminal", arguments: ["x": 1]))
        XCTAssertThrowsError(try CanvasControlCommand.parse(name: "new-terminal", arguments: ["width": 2]))
        XCTAssertThrowsError(try CanvasControlCommand.parse(name: "place", arguments: ["tiles": [["tile": "a"]]]))
        XCTAssertThrowsError(try CanvasControlCommand.parse(name: "new-browser", arguments: ["url": "not a url"]))
        XCTAssertThrowsError(try CanvasControlCommand.parse(name: "explode", arguments: [:]))
    }
}
