import Darwin
import Foundation

/// A command an agent sent through the control directory. Tile references are
/// unresolved tokens: a full id, a unique id prefix, or a tile index.
enum CanvasControlCommand {
    struct Placement {
        let tile: String
        let origin: GridPoint
        let span: GridSize?
    }

    case state
    case newTerminal(origin: GridPoint?, span: GridSize, workingDirectory: String?, command: String?, focus: Bool)
    case newBrowser(origin: GridPoint?, span: GridSize, url: URL?, focus: Bool)
    case place([Placement])
    case focus(tile: String, center: Bool)
    case close(tile: String)
    case zoom(Double)
    case fit(tiles: [String], margin: Double)

    static func parse(name: String, arguments: [String: Any]) throws -> CanvasControlCommand {
        switch name {
        case "state":
            return .state
        case "new-terminal":
            return .newTerminal(
                origin: try optionalPoint(arguments),
                span: try span(arguments) ?? .one,
                workingDirectory: arguments["cwd"] as? String,
                command: arguments["command"] as? String,
                focus: arguments["focus"] as? Bool ?? false
            )
        case "new-browser":
            var url: URL?
            if let rawURL = arguments["url"] as? String {
                guard let parsed = URL(string: rawURL), parsed.scheme != nil else {
                    throw CanvasControlError.invalidArgument("\(rawURL) is not an absolute URL.")
                }
                url = parsed
            }
            return .newBrowser(
                origin: try optionalPoint(arguments),
                span: try span(arguments) ?? .one,
                url: url,
                focus: arguments["focus"] as? Bool ?? false
            )
        case "place":
            guard let rawPlacements = arguments["tiles"] as? [[String: Any]], !rawPlacements.isEmpty else {
                throw CanvasControlError.invalidArgument("place needs a non-empty \"tiles\" array.")
            }
            let placements = try rawPlacements.map { raw -> Placement in
                guard let point = try optionalPoint(raw) else {
                    throw CanvasControlError.invalidArgument("Every placement needs integer x and y.")
                }
                return Placement(tile: try tileToken(raw["tile"]), origin: point, span: try span(raw))
            }
            return .place(placements)
        case "focus":
            return .focus(tile: try tileToken(arguments["tile"]), center: arguments["center"] as? Bool ?? false)
        case "close":
            return .close(tile: try tileToken(arguments["tile"]))
        case "zoom":
            guard let scale = arguments["scale"] as? Double else {
                throw CanvasControlError.invalidArgument("zoom needs a numeric \"scale\".")
            }
            return .zoom(scale)
        case "fit":
            let tiles = try (arguments["tiles"] as? [Any] ?? []).map(tileToken)
            return .fit(tiles: tiles, margin: arguments["margin"] as? Double ?? 24)
        default:
            throw CanvasControlError.invalidArgument("Unknown command \"\(name)\".")
        }
    }

    private static func optionalPoint(_ arguments: [String: Any]) throws -> GridPoint? {
        let x = arguments["x"], y = arguments["y"]
        if x == nil, y == nil { return nil }
        guard let x = x as? Int, let y = y as? Int else {
            throw CanvasControlError.invalidArgument("x and y must both be integers.")
        }
        return GridPoint(x: x, y: y)
    }

    private static func span(_ arguments: [String: Any]) throws -> GridSize? {
        let width = arguments["width"], height = arguments["height"]
        if width == nil, height == nil { return nil }
        guard let width = width as? Int, let height = height as? Int else {
            throw CanvasControlError.invalidArgument("width and height must both be integers.")
        }
        return GridSize(width: width, height: height)
    }

    private static func tileToken(_ value: Any?) throws -> String {
        if let token = value as? String, !token.isEmpty { return token }
        if let index = value as? Int { return String(index) }
        throw CanvasControlError.invalidArgument("Missing tile reference.")
    }
}

/// Lets agents drive the canvas. A client writes `<id>.request.json` into the
/// control directory (write a dotfile, then rename it into place); Codeboard
/// answers with `<id>.response.json`. Same idiom as reload requests.
@MainActor
final class CanvasControlServer {
    static let shared = CanvasControlServer()

    nonisolated static let requestSuffix = ".request.json"
    nonisolated static let responseSuffix = ".response.json"
    /// Requests left behind while Codeboard was not running are refused rather
    /// than replayed against a canvas the sender never saw.
    nonisolated static let maximumRequestAge: TimeInterval = 30

    private weak var canvas: CanvasViewController?
    private var directoryDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    private init() {}

    func start(canvas: CanvasViewController) {
        self.canvas = canvas
        guard source == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.controlDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("codeboard: could not create control directory: %@", error.localizedDescription)
            return
        }

        directoryDescriptor = open(AppPaths.controlDirectory.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.drainRequests()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryDescriptor >= 0 else { return }
            close(self.directoryDescriptor)
            self.directoryDescriptor = -1
        }
        self.source = source
        source.resume()
        drainRequests()
    }

    private func drainRequests() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: AppPaths.controlDirectory.path) else { return }
        for name in names.sorted() where name.hasSuffix(Self.requestSuffix) && !name.hasPrefix(".") {
            let requestURL = AppPaths.controlDirectory.appendingPathComponent(name)
            let requestID = String(name.dropLast(Self.requestSuffix.count))
            guard let data = try? Data(contentsOf: requestURL) else { continue }
            try? fileManager.removeItem(at: requestURL)
            writeResponse(respond(to: data), requestID: requestID)
        }
    }

    private func respond(to data: Data) -> [String: Any] {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = request["command"] as? String else {
                throw CanvasControlError.invalidArgument("Requests must be JSON objects with a \"command\".")
            }
            if let createdAt = request["createdAt"] as? Double,
               Date().timeIntervalSince1970 - createdAt > Self.maximumRequestAge {
                throw CanvasControlError.invalidArgument("Request is stale; it was written while Codeboard was not listening.")
            }
            let command = try CanvasControlCommand.parse(name: name, arguments: request["args"] as? [String: Any] ?? [:])
            return ["ok": true, "result": try execute(command)]
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ["ok": false, "error": message]
        }
    }

    private func execute(_ command: CanvasControlCommand) throws -> Any {
        guard let canvas else {
            throw CanvasControlError.invalidArgument("The canvas is not ready.")
        }
        switch command {
        case .state:
            return canvas.controlSnapshot()
        case .newTerminal(let origin, let span, let workingDirectory, let shellCommand, let focus):
            let tileID = try canvas.controlNewTerminal(
                origin: origin,
                span: span,
                workingDirectory: workingDirectory,
                command: shellCommand,
                focus: focus
            )
            return ["id": tileID.uuidString.lowercased()]
        case .newBrowser(let origin, let span, let url, let focus):
            let tileID = try canvas.controlNewBrowser(origin: origin, span: span, url: url, focus: focus)
            return ["id": tileID.uuidString.lowercased()]
        case .place(let placements):
            var rects: [UUID: GridRect] = [:]
            for placement in placements {
                let tileID = try canvas.controlResolveTileID(placement.tile)
                guard rects[tileID] == nil else {
                    throw CanvasControlError.invalidArgument("Tile \(placement.tile) is placed twice.")
                }
                let span = placement.span ?? canvas.controlRect(for: tileID)?.size ?? .one
                rects[tileID] = GridRect(origin: placement.origin, size: span)
            }
            try canvas.controlPlace(rects)
            return ["moved": rects.count]
        case .focus(let tile, let center):
            let tileID = try canvas.controlResolveTileID(tile)
            canvas.controlFocus(tileID: tileID, center: center)
            return ["focused": tileID.uuidString.lowercased()]
        case .close(let tile):
            let tileID = try canvas.controlResolveTileID(tile)
            canvas.controlClose(tileID: tileID)
            return ["closed": tileID.uuidString.lowercased()]
        case .zoom(let scale):
            return ["zoom": canvas.controlSetZoom(scale)]
        case .fit(let tiles, let margin):
            let tileIDs = try tiles.map(canvas.controlResolveTileID)
            return ["zoom": try canvas.controlFit(tileIDs: tileIDs, margin: margin)]
        }
    }

    private func writeResponse(_ response: [String: Any], requestID: String) {
        let responseURL = AppPaths.controlDirectory.appendingPathComponent(requestID + Self.responseSuffix)
        let temporaryURL = AppPaths.controlDirectory.appendingPathComponent(".\(requestID).\(UUID().uuidString).tmp")
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: temporaryURL)
            guard rename(temporaryURL.path, responseURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            NSLog("codeboard: could not answer control request %@: %@", requestID, error.localizedDescription)
        }
    }
}
