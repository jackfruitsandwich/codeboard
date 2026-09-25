import AppKit
import Darwin
import Foundation

private struct DevelopmentReloadRequest: Codable {
    let pid: Int32
    let nonce: UUID
}

@MainActor
final class DevelopmentReloadCoordinator {
    static let shared = DevelopmentReloadCoordinator()

    private(set) var isDevelopmentReload = false
    private var directoryDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    private init() {}

    func start(onReloadRequested: @escaping @MainActor () -> Void) {
        do {
            try FileManager.default.createDirectory(at: AppPaths.reloadRequestDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("codeboard: could not create reload request directory: %@", error.localizedDescription)
            return
        }

        directoryDescriptor = open(AppPaths.reloadRequestDirectory.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.consumeRequest(onReloadRequested: onReloadRequested)
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryDescriptor >= 0 else { return }
            close(self.directoryDescriptor)
            self.directoryDescriptor = -1
        }
        self.source = source
        source.resume()
        consumeRequest(onReloadRequested: onReloadRequested)
    }

    func publishReadinessIfRequested() {
        guard let path = Self.argumentValue(after: "--codeboard-ready-token") else { return }
        let url = URL(fileURLWithPath: path)
        let contents = "{\"pid\":\(ProcessInfo.processInfo.processIdentifier)}\n"
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("codeboard: could not publish reload readiness: %@", error.localizedDescription)
        }
    }

    private func consumeRequest(onReloadRequested: @escaping @MainActor () -> Void) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let requestURL = AppPaths.reloadRequestDirectory.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(DevelopmentReloadRequest.self, from: data),
              request.pid == pid else {
            return
        }

        try? FileManager.default.removeItem(at: requestURL)
        isDevelopmentReload = true
        onReloadRequested()
    }

    private static func argumentValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
