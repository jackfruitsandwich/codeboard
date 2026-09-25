import Foundation

struct WorkspacePoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct WorkspaceRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum WorkspaceTileKind: String, Codable {
    case terminal
    case browser
}

struct WorkspaceTileState: Codable {
    let id: UUID
    let kind: WorkspaceTileKind
    let index: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let workingDirectory: String?
    let browserURL: String?
}

struct WorkspaceState: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let tiles: [WorkspaceTileState]
    let focusedTileID: UUID?
    let zoomScale: Double
    let gridHalfSpan: Int
    let scrollOrigin: WorkspacePoint
    let windowFrame: WorkspaceRect?

    init(
        tiles: [WorkspaceTileState],
        focusedTileID: UUID?,
        zoomScale: Double,
        gridHalfSpan: Int,
        scrollOrigin: WorkspacePoint,
        windowFrame: WorkspaceRect?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.tiles = tiles
        self.focusedTileID = focusedTileID
        self.zoomScale = zoomScale
        self.gridHalfSpan = gridHalfSpan
        self.scrollOrigin = scrollOrigin
        self.windowFrame = windowFrame
    }
}

@MainActor
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: AppPaths.workspaceStateURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: AppPaths.workspaceStateURL)
            let state = try decoder.decode(WorkspaceState.self, from: data)
            guard state.schemaVersion == WorkspaceState.currentSchemaVersion else {
                throw WorkspaceStoreError.unsupportedSchema(state.schemaVersion)
            }
            return state
        } catch {
            preserveCorruptState()
            NSLog("codeboard: could not restore workspace: %@", error.localizedDescription)
            return nil
        }
    }

    func save(_ state: WorkspaceState) throws {
        try FileManager.default.createDirectory(at: AppPaths.appSupportDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: AppPaths.workspaceStateURL, options: .atomic)
    }

    private func preserveCorruptState() {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = AppPaths.appSupportDirectory
            .appendingPathComponent("workspace.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: AppPaths.workspaceStateURL, to: destination)
    }
}

private enum WorkspaceStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported workspace schema \(version)"
        }
    }
}
