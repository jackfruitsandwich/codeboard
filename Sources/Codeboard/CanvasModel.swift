import Foundation

struct GridPoint: Hashable, Sendable {
    let x: Int
    let y: Int

    static let origin = GridPoint(x: 0, y: 0)

    func moved(_ direction: NavigationDirection) -> GridPoint {
        switch direction {
        case .left:
            return GridPoint(x: x - 1, y: y)
        case .right:
            return GridPoint(x: x + 1, y: y)
        case .up:
            return GridPoint(x: x, y: y - 1)
        case .down:
            return GridPoint(x: x, y: y + 1)
        }
    }
}

struct GridSize: Hashable, Sendable {
    let width: Int
    let height: Int

    static let one = GridSize(width: 1, height: 1)

    var area: Int {
        width * height
    }
}

struct GridRect: Hashable, Sendable {
    let origin: GridPoint
    let size: GridSize

    var minX: Int { origin.x }
    var minY: Int { origin.y }
    var maxX: Int { origin.x + size.width }
    var maxY: Int { origin.y + size.height }

    var centerX: Double {
        Double(minX + maxX) / 2
    }

    var centerY: Double {
        Double(minY + maxY) / 2
    }
}

enum NavigationDirection: CaseIterable {
    case left
    case right
    case up
    case down

    var deltaX: Int {
        switch self {
        case .left:
            return -1
        case .right:
            return 1
        case .up, .down:
            return 0
        }
    }

    var deltaY: Int {
        switch self {
        case .up:
            return -1
        case .down:
            return 1
        case .left, .right:
            return 0
        }
    }
}

final class CanvasModel {
    private(set) var focusedTileID: UUID?

    private var pointByTileID: [UUID: GridPoint] = [:]
    private var sizeByTileID: [UUID: GridSize] = [:]
    private var tileIDByPoint: [GridPoint: UUID] = [:]
    private var creationOrderByTileID: [UUID: Int] = [:]
    private var nextCreationOrder = 0

    func point(for tileID: UUID) -> GridPoint? {
        pointByTileID[tileID]
    }

    func size(for tileID: UUID) -> GridSize {
        sizeByTileID[tileID] ?? .one
    }

    func rect(for tileID: UUID) -> GridRect? {
        guard let point = pointByTileID[tileID] else { return nil }
        return GridRect(origin: point, size: size(for: tileID))
    }

    func contains(_ point: GridPoint) -> Bool {
        tileIDByPoint[point] != nil
    }

    func register(tileID: UUID, at point: GridPoint, size: GridSize = .one) {
        pointByTileID[tileID] = point
        sizeByTileID[tileID] = size
        for occupiedPoint in occupiedPoints(origin: point, size: size) {
            tileIDByPoint[occupiedPoint] = tileID
        }
        creationOrderByTileID[tileID] = nextCreationOrder
        nextCreationOrder += 1
    }

    func canPlace(tileID: UUID, at point: GridPoint, size: GridSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return occupiedPoints(origin: point, size: size).allSatisfy { occupiedPoint in
            guard let existingTileID = tileIDByPoint[occupiedPoint] else { return true }
            return existingTileID == tileID
        }
    }

    @discardableResult
    func update(tileID: UUID, to point: GridPoint, size: GridSize) -> Bool {
        guard let oldPoint = pointByTileID[tileID] else { return false }
        let oldSize = sizeByTileID[tileID] ?? .one
        guard canPlace(tileID: tileID, at: point, size: size) else { return false }

        for occupiedPoint in occupiedPoints(origin: oldPoint, size: oldSize) where tileIDByPoint[occupiedPoint] == tileID {
            tileIDByPoint.removeValue(forKey: occupiedPoint)
        }

        pointByTileID[tileID] = point
        sizeByTileID[tileID] = size
        for occupiedPoint in occupiedPoints(origin: point, size: size) {
            tileIDByPoint[occupiedPoint] = tileID
        }
        return true
    }

    @discardableResult
    func remove(tileID: UUID) -> GridPoint? {
        guard let point = pointByTileID.removeValue(forKey: tileID) else { return nil }
        let size = sizeByTileID.removeValue(forKey: tileID) ?? .one
        for occupiedPoint in occupiedPoints(origin: point, size: size) where tileIDByPoint[occupiedPoint] == tileID {
            tileIDByPoint.removeValue(forKey: occupiedPoint)
        }
        creationOrderByTileID.removeValue(forKey: tileID)
        if focusedTileID == tileID {
            focusedTileID = nil
        }
        return point
    }

    func focus(tileID: UUID?) {
        focusedTileID = tileID
    }

    func nextSpawnPoint(near anchorTileID: UUID?, preferredDirection: NavigationDirection? = nil) -> GridPoint {
        guard let anchorTileID,
              let anchorPoint = pointByTileID[anchorTileID] else {
            return nextSpawnPoint(around: .origin, preferredDirection: preferredDirection)
        }

        return nextSpawnPoint(around: anchorPoint, preferredDirection: preferredDirection, allowAnchorPoint: false)
    }

    func nextSpawnPoint(around anchorPoint: GridPoint, preferredDirection: NavigationDirection? = nil) -> GridPoint {
        nextSpawnPoint(around: anchorPoint, preferredDirection: preferredDirection, allowAnchorPoint: true)
    }

    private func nextSpawnPoint(
        around anchorPoint: GridPoint,
        preferredDirection: NavigationDirection?,
        allowAnchorPoint: Bool
    ) -> GridPoint {
        if allowAnchorPoint, !contains(anchorPoint) {
            return anchorPoint
        }

        if let preferredDirection {
            for distance in 1...256 {
                let candidate = GridPoint(
                    x: anchorPoint.x + preferredDirection.deltaX * distance,
                    y: anchorPoint.y + preferredDirection.deltaY * distance
                )
                if !contains(candidate) {
                    return candidate
                }
            }
        }

        let immediateDirections: [NavigationDirection] = [.right, .down, .left, .up]
        for direction in immediateDirections {
            let candidate = anchorPoint.moved(direction)
            if !contains(candidate) {
                return candidate
            }
        }

        for radius in 1...256 {
            for candidate in ringPoints(around: anchorPoint, radius: radius) where !contains(candidate) {
                return candidate
            }
        }

        return GridPoint(x: anchorPoint.x + 1, y: anchorPoint.y + 1)
    }

    func nextFocus(from sourceTileID: UUID?, direction: NavigationDirection) -> UUID? {
        guard let sourceTileID,
              let sourceRect = rect(for: sourceTileID) else {
            return focusedTileID
        }

        let candidates = pointByTileID.compactMap { tileID, _ -> (UUID, GridRect)? in
            guard tileID != sourceTileID else { return nil }
            guard let rect = rect(for: tileID) else { return nil }
            switch direction {
            case .left where rect.maxX <= sourceRect.minX:
                return (tileID, rect)
            case .right where rect.minX >= sourceRect.maxX:
                return (tileID, rect)
            case .up where rect.maxY <= sourceRect.minY:
                return (tileID, rect)
            case .down where rect.minY >= sourceRect.maxY:
                return (tileID, rect)
            default:
                return nil
            }
        }

        return candidates.min(by: { lhs, rhs in
            let lhsScore = navigationScore(from: sourceRect, to: lhs.1, tileID: lhs.0, direction: direction)
            let rhsScore = navigationScore(from: sourceRect, to: rhs.1, tileID: rhs.0, direction: direction)
            return lhsScore < rhsScore
        })?.0
    }

    func nearestTile(to point: GridPoint) -> UUID? {
        pointByTileID.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.value.x - point.x) + abs(lhs.value.y - point.y)
            let rhsDistance = abs(rhs.value.x - point.x) + abs(rhs.value.y - point.y)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return (creationOrderByTileID[lhs.key] ?? 0) < (creationOrderByTileID[rhs.key] ?? 0)
        })?.key
    }

    private func navigationScore(
        from source: GridRect,
        to candidate: GridRect,
        tileID: UUID,
        direction: NavigationDirection
    ) -> (Double, Double, Int) {
        let distance: Double
        let perpendicularOffset: Double
        switch direction {
        case .left:
            distance = Double(source.minX - candidate.maxX)
            perpendicularOffset = abs(candidate.centerY - source.centerY)
        case .right:
            distance = Double(candidate.minX - source.maxX)
            perpendicularOffset = abs(candidate.centerY - source.centerY)
        case .up:
            distance = Double(source.minY - candidate.maxY)
            perpendicularOffset = abs(candidate.centerX - source.centerX)
        case .down:
            distance = Double(candidate.minY - source.maxY)
            perpendicularOffset = abs(candidate.centerX - source.centerX)
        }
        let creationOrder = creationOrderByTileID[tileID] ?? 0
        return (distance, perpendicularOffset, creationOrder)
    }

    private func occupiedPoints(origin: GridPoint, size: GridSize) -> [GridPoint] {
        guard size.width > 0, size.height > 0 else { return [] }
        var points: [GridPoint] = []
        for y in origin.y..<(origin.y + size.height) {
            for x in origin.x..<(origin.x + size.width) {
                points.append(GridPoint(x: x, y: y))
            }
        }
        return points
    }

    private func ringPoints(around origin: GridPoint, radius: Int) -> [GridPoint] {
        guard radius > 0 else { return [origin] }

        var points: [GridPoint] = []

        for dy in -radius...radius {
            points.append(GridPoint(x: origin.x + radius, y: origin.y + dy))
        }
        if radius > 0 {
            for dx in stride(from: radius - 1, through: -radius, by: -1) {
                points.append(GridPoint(x: origin.x + dx, y: origin.y + radius))
            }
            for dy in stride(from: radius - 1, through: -radius, by: -1) {
                points.append(GridPoint(x: origin.x - radius, y: origin.y + dy))
            }
            for dx in -radius + 1..<radius {
                points.append(GridPoint(x: origin.x + dx, y: origin.y - radius))
            }
        }

        return points
    }
}
