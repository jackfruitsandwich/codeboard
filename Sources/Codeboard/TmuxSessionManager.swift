import Foundation

struct TmuxCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

@MainActor
final class TmuxSessionManager {
    static let shared = TmuxSessionManager()

    nonisolated static let socketName = "codeboard"
    nonisolated static let sessionPrefix = "cb-"
    nonisolated static let privateConfigContents = """
    set -g status off
    set -g prefix None
    unbind-key C-b
    set -g mouse on
    set -s set-clipboard on
    set -s copy-command '/usr/bin/pbcopy'
    set-hook -gu pane-set-clipboard
    set -g default-terminal tmux-256color
    set -s extended-keys on
    set -s extended-keys-format csi-u
    set -as terminal-features ',xterm-ghostty*:RGB:extkeys'
    set-environment -g COLORTERM truecolor
    set-environment -gu NO_COLOR
    set -g focus-events on
    set -s escape-time 0
    set -g allow-passthrough on
    set -g window-size largest
    set -g history-limit 100000
    unbind-key -T root MouseDown3Pane
    unbind-key -T root M-MouseDown3Pane
    bind-key -T root MouseDown3Pane if-shell -F '#{mouse_any_flag}' 'send-keys -M' ''
    bind-key -T root M-MouseDown3Pane if-shell -F '#{mouse_any_flag}' 'send-keys -M' ''
    """

    private(set) var executableURL: URL?
    private(set) var startupError: String?
    private var sessionsNeedingShellBootstrap: Set<UUID> = []

    private init() {
        executableURL = Self.resolveExecutable()
        do {
            try writePrivateConfig()
        } catch {
            startupError = "Could not write Codeboard's private tmux config: \(error.localizedDescription)"
        }
    }

    var isAvailable: Bool {
        executableURL != nil && startupError == nil
    }

    func sessionName(for tileID: UUID) -> String {
        Self.sessionPrefix + tileID.uuidString.lowercased()
    }

    nonisolated static func paneTarget(for tileID: UUID) -> String {
        "=\(sessionPrefix)\(tileID.uuidString.lowercased()):0.0"
    }

    func launchCommand(for tileID: UUID, workingDirectory: String) -> String? {
        guard let executableURL else { return nil }
        // ghostty_surface_config_s.command is already executed by Ghostty's
        // login-shell launcher; unlike config-file commands, it does not pass
        // through Ghostty's `direct:` command parser.
        return Self.launchArguments(
            executablePath: executableURL.path,
            tileID: tileID,
            workingDirectory: workingDirectory,
            configPath: AppPaths.tmuxConfigURL.path,
            inheritedEnvironment: ProcessInfo.processInfo.environment
        )
        .map(shellQuoted)
        .joined(separator: " ")
    }

    @discardableResult
    func prepareSession(for tileID: UUID) -> Bool {
        guard isAvailable else { return false }
        if hasSession(for: tileID) {
            sessionsNeedingShellBootstrap.remove(tileID)
            _ = run(["-L", Self.socketName, "source-file", AppPaths.tmuxConfigURL.path])
            return true
        }

        let serverIsRunning = run(["-L", Self.socketName, "list-sessions"]).succeeded
        if serverIsRunning {
            _ = run(["-L", Self.socketName, "source-file", AppPaths.tmuxConfigURL.path])
        }

        let claudeSessionURL = AppPaths.claudeSessionURL(for: tileID)
        try? FileManager.default.createDirectory(
            at: AppPaths.agentSessionDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: claudeSessionURL)
        sessionsNeedingShellBootstrap.insert(tileID)
        return true
    }

    func consumeShellBootstrapInput(for tileID: UUID) -> String? {
        guard sessionsNeedingShellBootstrap.remove(tileID) != nil else { return nil }
        return Self.shellBootstrapInput(
            wrapperDirectory: AppPaths.agentWrapperDirectory.path,
            shellPath: ProcessInfo.processInfo.environment["SHELL"]
        )
    }

    nonisolated static func launchArguments(
        executablePath: String,
        tileID: UUID,
        workingDirectory: String,
        configPath: String,
        inheritedEnvironment: [String: String]
    ) -> [String] {
        let sessionName = sessionPrefix + tileID.uuidString.lowercased()
        let claudeSessionPath = AppPaths.claudeSessionURL(for: tileID).path
        let environment = sessionEnvironment(from: inheritedEnvironment)
        return [
            executablePath,
            "-L", socketName,
            "-f", configPath,
            "new-session", "-A",
            "-e", "COLORTERM=truecolor",
            "-e", "CODEBOARD_TILE_ID=\(tileID.uuidString.lowercased())",
            "-e", "CODEBOARD_CLAUDE_SESSION_FILE=\(claudeSessionPath)",
            "-e", "PATH=\(environment["PATH"] ?? "")",
            "-s", sessionName,
            "-c", workingDirectory,
        ]
    }

    func hasSession(for tileID: UUID) -> Bool {
        run(["-L", Self.socketName, "has-session", "-t", "=\(sessionName(for: tileID))"]).succeeded
    }

    func currentPath(for tileID: UUID) -> String? {
        value(for: tileID, format: "#{pane_current_path}")
    }

    func currentPaths(for tileIDs: Set<UUID>) -> [UUID: String] {
        guard !tileIDs.isEmpty else { return [:] }
        let result = run([
            "-L", Self.socketName,
            "list-panes", "-a",
            "-F", "#{session_name}|#{pane_current_path}",
        ])
        guard result.succeeded else { return [:] }

        var paths: [UUID: String] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "|") else { continue }
            let name = line[..<separator]
            guard name.hasPrefix(Self.sessionPrefix),
                  let tileID = UUID(uuidString: String(name.dropFirst(Self.sessionPrefix.count))),
                  tileIDs.contains(tileID) else {
                continue
            }
            paths[tileID] = String(line[line.index(after: separator)...])
        }
        return paths
    }

    func paneSummaries(for tileIDs: Set<UUID>) -> [UUID: (path: String, command: String)] {
        guard !tileIDs.isEmpty else { return [:] }
        let result = run([
            "-L", Self.socketName,
            "list-panes", "-a",
            "-F", "#{session_name}|#{pane_current_command}|#{pane_current_path}",
        ])
        guard result.succeeded else { return [:] }

        var summaries: [UUID: (path: String, command: String)] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[0].hasPrefix(Self.sessionPrefix),
                  let tileID = UUID(uuidString: String(fields[0].dropFirst(Self.sessionPrefix.count))),
                  tileIDs.contains(tileID) else {
                continue
            }
            summaries[tileID] = (path: String(fields[2]), command: String(fields[1]))
        }
        return summaries
    }

    func currentCommand(for tileID: UUID) -> String? {
        value(for: tileID, format: "#{pane_current_command}")
    }

    func panePID(for tileID: UUID) -> Int32? {
        guard let rawValue = value(for: tileID, format: "#{pane_pid}"),
              let value = Int32(rawValue) else {
            return nil
        }
        return value
    }

    func paneAcceptsMouseInput(for tileID: UUID) -> Bool? {
        guard let rawValue = value(for: tileID, format: "#{mouse_any_flag}") else {
            return nil
        }
        switch rawValue {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }

    func cancelCopyMode(for tileID: UUID) {
        _ = run([
            "-L", Self.socketName,
            "send-keys", "-t", Self.paneTarget(for: tileID),
            "-X", "cancel",
        ])
    }

    @discardableResult
    func copySelectionFromCopyMode(for tileID: UUID) -> Bool {
        guard value(for: tileID, format: "#{pane_in_mode}|#{selection_present}") == "1|1" else {
            return false
        }
        return run([
            "-L", Self.socketName,
            "send-keys", "-t", Self.paneTarget(for: tileID),
            "-X", "copy-pipe-and-cancel",
        ]).succeeded
    }

    @discardableResult
    func killSession(for tileID: UUID) -> Bool {
        let result = run(["-L", Self.socketName, "kill-session", "-t", "=\(sessionName(for: tileID))"])
        try? FileManager.default.removeItem(at: AppPaths.claudeSessionURL(for: tileID))
        return result.succeeded
    }

    func existingTileIDs() -> [UUID] {
        let result = run(["-L", Self.socketName, "list-sessions", "-F", "#{session_name}"])
        guard result.succeeded else { return [] }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { name -> UUID? in
                guard name.hasPrefix(Self.sessionPrefix) else { return nil }
                return UUID(uuidString: String(name.dropFirst(Self.sessionPrefix.count)))
            }
    }

    nonisolated static func processEnvironment(from inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["COLORTERM"] = "truecolor"
        environment.removeValue(forKey: "NO_COLOR")
        return environment
    }

    nonisolated static func sessionEnvironment(from inherited: [String: String]) -> [String: String] {
        var environment = processEnvironment(from: inherited)
        let wrapperDirectory = AppPaths.agentWrapperDirectory.path
        let pathParts = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        environment["PATH"] = ([wrapperDirectory] + pathParts.filter { $0 != wrapperDirectory })
            .joined(separator: ":")
        return environment
    }

    nonisolated static func shellBootstrapInput(wrapperDirectory: String, shellPath: String?) -> String? {
        let quotedDirectory = "'" + wrapperDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch shellPath.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
        case "fish":
            return " set -gx PATH \(quotedDirectory) $PATH\n"
        case "csh", "tcsh":
            return " setenv PATH \(quotedDirectory):$PATH\n"
        case "bash", "dash", "ksh", "sh", "zsh", nil:
            return " export PATH=\(quotedDirectory):\"$PATH\"\n"
        default:
            return nil
        }
    }

    private func value(for tileID: UUID, format: String) -> String? {
        let result = run([
            "-L", Self.socketName,
            "display-message", "-p",
            "-t", Self.paneTarget(for: tileID),
            format,
        ])
        guard result.succeeded else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func run(_ arguments: [String]) -> TmuxCommandResult {
        guard let executableURL else {
            return TmuxCommandResult(status: 127, stdout: "", stderr: "tmux was not found")
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.processEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return TmuxCommandResult(status: 126, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return TmuxCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func writePrivateConfig() throws {
        try FileManager.default.createDirectory(at: AppPaths.appSupportDirectory, withIntermediateDirectories: true)
        try Self.privateConfigContents.write(to: AppPaths.tmuxConfigURL, atomically: true, encoding: .utf8)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func resolveExecutable() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEBOARD_TMUX_PATH"],
            Bundle.main.url(forResource: "tmux", withExtension: nil)?.path,
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ].compactMap { $0 }

        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("tmux")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
