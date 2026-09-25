import Darwin
import Foundation

private let codeboardClaudeHookSettingsJSON = #"{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${CODEBOARD_CLAUDE_HOOK}\"","timeout":5}]}]}}"#

struct ConversationForkProcess: Equatable {
    let pid: Int32
    let parentPID: Int32
    let arguments: [String]
    let environment: [String: String]
}

struct ConversationForkLaunch: Equatable {
    let agentName: String
    let arguments: [String]

    var shellCommand: String {
        arguments.map(Self.shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ConversationForkError: LocalizedError, Equatable {
    case persistentSessionRequired
    case unsupportedAgent
    case missingSessionIdentity(String)

    var errorDescription: String? {
        switch self {
        case .persistentSessionRequired:
            return "This terminal is not attached to a persistent Codeboard session."
        case .unsupportedAgent:
            return "The focused terminal is not running a supported Claude or Wuwei conversation."
        case .missingSessionIdentity(let agent):
            return "Codeboard found \(agent), but could not identify its current conversation. Start a new \(agent) conversation in a newly created terminal and try again."
        }
    }
}

enum ConversationForkResolver {
    private struct Invocation {
        let process: ConversationForkProcess
        let executable: String
        let target: String?
        let tail: [String]
    }

    private enum AgentCandidate {
        case contextSurgeon(Invocation)
        case claude(Invocation)
        case wuwei(Invocation)

        var process: ConversationForkProcess {
            switch self {
            case .contextSurgeon(let invocation), .claude(let invocation), .wuwei(let invocation):
                return invocation.process
            }
        }
    }

    private static let claudeNames: Set<String> = ["claude", "claude-ev"]
    private static let inheritedClaudeEnvironmentKeys: Set<String> = [
        "ANTHROPIC_BASE_URL",
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_EV_CONFIG_DIR",
        "CLAUDE_MAIN_CONFIG_DIR",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_VERTEX",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
    ]
    private static let inheritedContextSurgeonEnvironmentKeys: Set<String> = [
        "CONTEXT_SURGEON_DEBUG",
        "CONTEXT_SURGEON_DISABLE_SURGERY",
        "CONTEXT_SURGEON_DIRECTIVES_PATH",
        "CONTEXT_SURGEON_MAX_TOKENS",
        "CONTEXT_SURGEON_SESSIONS_DIRECTORY",
        "CONTEXT_SURGEON_TUNNEL_STARTUP_TIMEOUT_MS",
        "CONTEXT_SURGEON_UPSTREAM_ANTHROPIC",
        "CONTEXT_SURGEON_UPSTREAM_CHATGPT",
        "CONTEXT_SURGEON_UPSTREAM_OPENAI",
    ]
    private static let inheritedWuweiEnvironmentKeys: Set<String> = [
        "WUWEI_SESSION_DIR",
        "WUWEI_THREAD_DIR",
        "WUWEI_WORKSPACE",
    ]

    static func resolve(
        panePID: Int32,
        processes: [ConversationForkProcess],
        readReceipt: (String) -> String? = { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        }
    ) throws -> ConversationForkLaunch {
        let processByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let descendants = processes.filter { isDescendant($0.pid, of: panePID, processByPID: processByPID) }
        let candidates = descendants.compactMap { process -> AgentCandidate? in
            if let invocation = contextSurgeonInvocation(process) {
                return .contextSurgeon(invocation)
            }
            if let invocation = wuweiInvocation(process) {
                return .wuwei(invocation)
            }
            if let invocation = claudeInvocation(process) {
                return .claude(invocation)
            }
            return nil
        }
        guard let candidate = candidates.min(by: {
            depth(of: $0.process.pid, from: panePID, processByPID: processByPID)
                < depth(of: $1.process.pid, from: panePID, processByPID: processByPID)
        }) else {
            throw ConversationForkError.unsupportedAgent
        }

        switch candidate {
        case .wuwei(let invocation):
            return try resolveWuwei(
                invocation,
                descendants: descendants,
                processByPID: processByPID,
                readReceipt: readReceipt
            )
        case .contextSurgeon(let invocation):
            return try resolveClaude(
                invocation,
                isContextSurgeon: true,
                descendants: descendants,
                processByPID: processByPID,
                readReceipt: readReceipt
            )
        case .claude(let invocation):
            return try resolveClaude(
                invocation,
                isContextSurgeon: false,
                descendants: descendants,
                processByPID: processByPID,
                readReceipt: readReceipt
            )
        }
    }

    private static func resolveClaude(
        _ invocation: Invocation,
        isContextSurgeon: Bool,
        descendants: [ConversationForkProcess],
        processByPID: [Int32: ConversationForkProcess],
        readReceipt: (String) -> String?
    ) throws -> ConversationForkLaunch {
        let subtree = descendants.filter {
            isDescendant($0.pid, of: invocation.process.pid, processByPID: processByPID)
        }
        let argumentSessionProcess = subtree
            .filter { claudeSessionID(in: $0.arguments) != nil }
            .max(by: {
                depth(of: $0.pid, from: invocation.process.pid, processByPID: processByPID)
                    < depth(of: $1.pid, from: invocation.process.pid, processByPID: processByPID)
            })
        let receiptProcess = subtree
            .filter { normalized($0.environment["CODEBOARD_CLAUDE_SESSION_FILE"]) != nil }
            .max(by: {
                depth(of: $0.pid, from: invocation.process.pid, processByPID: processByPID)
                    < depth(of: $1.pid, from: invocation.process.pid, processByPID: processByPID)
            })
        let receiptSessionID = receiptProcess
            .flatMap { normalized($0.environment["CODEBOARD_CLAUDE_SESSION_FILE"]) }
            .flatMap(readReceipt)
            .flatMap(normalized)
            .flatMap { UUID(uuidString: $0) == nil ? nil : $0.lowercased() }
        let argumentSessionID = argumentSessionProcess.flatMap { claudeSessionID(in: $0.arguments) }
        guard let sessionID = receiptSessionID ?? argumentSessionID else {
            let name = isContextSurgeon ? "Context Surgeon Claude" : (invocation.target ?? baseName(invocation.executable))
            throw ConversationForkError.missingSessionIdentity(name)
        }
        guard let preservedArguments = sanitizedClaudeArguments(invocation.tail) else {
            throw ConversationForkError.unsupportedAgent
        }

        let sessionProcess = receiptProcess ?? argumentSessionProcess ?? invocation.process
        let launcher = claudeLauncher(
            from: sessionProcess.environment,
            fallbackExecutable: invocation.executable
        )
        var environment = selectedEnvironment(
            from: sessionProcess.environment,
            keys: inheritedClaudeEnvironmentKeys
        )
        if isContextSurgeon {
            // Context Surgeon assigns a per-session loopback proxy to the child.
            // Reusing that URL would attach the fork to the old tunnel.
            environment.removeValue(forKey: "ANTHROPIC_BASE_URL")
            environment.merge(
                selectedEnvironment(
                    from: invocation.process.environment,
                    keys: inheritedContextSurgeonEnvironmentKeys
                ),
                uniquingKeysWith: { _, current in current }
            )
        }
        environment["CODEBOARD_CLAUDE_HOOK"] = AppPaths.agentWrapperDirectory
            .appendingPathComponent("codeboard-claude-hook", isDirectory: false)
            .path
        environment["CODEBOARD_CLAUDE_HOOK_INJECTED"] = "1"
        if !isContextSurgeon {
            environment["CODEBOARD_CLAUDE_LAUNCHER"] = launcher.name
            if let path = launcher.recordedPath {
                environment["CODEBOARD_CLAUDE_LAUNCHER_PATH"] = path
            }
        }

        var command = [isContextSurgeon ? invocation.executable : launcher.executable]
        if let target = invocation.target {
            command.append(target)
        }
        command.append(contentsOf: [
            "--settings", codeboardClaudeHookSettingsJSON,
            "--resume", sessionID,
            "--fork-session",
        ])
        command.append(contentsOf: preservedArguments)
        command = commandWithEnvironment(command, environment: environment)

        let variant = invocation.target ?? launcher.name
        let name = isContextSurgeon ? "Context Surgeon \(variant)" : variant
        return ConversationForkLaunch(agentName: name, arguments: command)
    }

    private static func resolveWuwei(
        _ invocation: Invocation,
        descendants: [ConversationForkProcess],
        processByPID: [Int32: ConversationForkProcess],
        readReceipt: (String) -> String?
    ) throws -> ConversationForkLaunch {
        let subtree = descendants.filter {
            isDescendant($0.pid, of: invocation.process.pid, processByPID: processByPID)
        }
        let receiptProcess = subtree
            .filter { normalized($0.environment["WUWEI_RESUME_FILE"]) != nil }
            .max(by: {
                depth(of: $0.pid, from: invocation.process.pid, processByPID: processByPID)
                    < depth(of: $1.pid, from: invocation.process.pid, processByPID: processByPID)
            })
        guard let receiptProcess,
              let receiptPath = normalized(receiptProcess.environment["WUWEI_RESUME_FILE"]),
              let threadID = normalized(readReceipt(receiptPath)),
              isValidWuweiThreadID(threadID) else {
            throw ConversationForkError.missingSessionIdentity("Wuwei")
        }

        var environment = selectedEnvironment(
            from: invocation.process.environment,
            keys: inheritedWuweiEnvironmentKeys
        )
        environment.merge(
            selectedEnvironment(from: receiptProcess.environment, keys: inheritedWuweiEnvironmentKeys),
            uniquingKeysWith: { _, current in current }
        )
        let command = commandWithEnvironment(
            [invocation.executable, "--fork", threadID],
            environment: environment
        )
        return ConversationForkLaunch(agentName: "Wuwei", arguments: command)
    }

    private static func contextSurgeonInvocation(_ process: ConversationForkProcess) -> Invocation? {
        for index in process.arguments.indices where baseName(process.arguments[index]) == "context-surgeon" {
            let targetIndex = index + 1
            guard targetIndex < process.arguments.count,
                  claudeNames.contains(process.arguments[targetIndex]) else {
                continue
            }
            return Invocation(
                process: process,
                executable: process.arguments[index],
                target: process.arguments[targetIndex],
                tail: Array(process.arguments.dropFirst(targetIndex + 1))
            )
        }
        return nil
    }

    private static func claudeInvocation(_ process: ConversationForkProcess) -> Invocation? {
        for index in process.arguments.indices {
            let name = baseName(process.arguments[index])
            guard claudeNames.contains(name) else { continue }
            return Invocation(
                process: process,
                executable: process.arguments[index],
                target: nil,
                tail: Array(process.arguments.dropFirst(index + 1))
            )
        }
        return nil
    }

    private static func wuweiInvocation(_ process: ConversationForkProcess) -> Invocation? {
        for index in process.arguments.indices {
            let name = baseName(process.arguments[index])
            guard name == "wuwei" || name == "wuwei.js" else { continue }
            return Invocation(
                process: process,
                executable: process.arguments[index],
                target: nil,
                tail: Array(process.arguments.dropFirst(index + 1))
            )
        }
        return nil
    }

    private static func claudeSessionID(in arguments: [String]) -> String? {
        let valueOptions: Set<String> = ["--session-id", "--resume", "-r"]
        for index in arguments.indices {
            let argument = arguments[index]
            for prefix in ["--session-id=", "--resume="] where argument.hasPrefix(prefix) {
                return normalized(String(argument.dropFirst(prefix.count)))
            }
            guard valueOptions.contains(argument), index + 1 < arguments.count else { continue }
            let candidate = arguments[index + 1]
            if !candidate.hasPrefix("-") {
                return normalized(candidate)
            }
        }
        return nil
    }

    private static func sanitizedClaudeArguments(_ arguments: [String]) -> [String]? {
        let valueOptions: Set<String> = [
            "--add-dir", "--agent", "--agents", "--allowedTools", "--allowed-tools",
            "--append-system-prompt", "--betas", "--dangerously-load-development-channels",
            "--debug-file", "--disallowedTools", "--disallowed-tools", "--effort",
            "--fallback-model", "--file", "--from-pr", "--input-format", "--json-schema",
            "--max-budget-usd", "--mcp-config", "--model", "-m", "--name", "-n", "--output-format",
            "--permission-mode", "--plugin-dir", "--plugin-url", "--remote-control-session-name-prefix",
            "--resume", "-r", "--session-id", "--setting-sources", "--settings",
            "--system-prompt", "--teammate-mode", "--tmux", "--tools", "--worktree", "-w",
        ]
        let variadicOptions: Set<String> = [
            "--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools",
            "--disallowed-tools", "--file", "--mcp-config", "--tools",
        ]
        let droppedOptions: Set<String> = [
            "--continue", "-c", "--fork-session", "--from-pr", "--resume", "-r",
            "--session-id", "--tmux", "--worktree", "-w",
        ]
        let droppedPrefixes = [
            "--fork-session=", "--from-pr=", "--resume=", "--session-id=", "--tmux=", "--worktree=",
        ]
        let rejectedOptions: Set<String> = ["--print", "-p", "--no-session-persistence"]
        let nonInteractiveCommands: Set<String> = [
            "agents", "auth", "auto-mode", "api-key", "config", "doctor", "install", "mcp",
            "gateway", "plugin", "plugins", "project", "rc", "setup-token", "ultrareview",
            "update", "upgrade",
        ]
        let optionalValueOptions: Set<String> = [
            "--debug", "--from-pr", "--prompt-suggestions", "--remote-control", "--resume", "-r",
            "--tmux", "--worktree", "-w",
        ]

        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            if !argument.hasPrefix("-") || argument == "-" {
                if nonInteractiveCommands.contains(argument) { return nil }
                break
            }
            if rejectedOptions.contains(argument) || rejectedOptions.contains(where: { argument.hasPrefix("\($0)=") }) {
                return nil
            }
            if argument == "--settings",
               index + 1 < arguments.count,
               arguments[index + 1] == codeboardClaudeHookSettingsJSON {
                index += 2
                continue
            }
            if argument == "--settings=\(codeboardClaudeHookSettingsJSON)" {
                index += 1
                continue
            }
            if droppedPrefixes.contains(where: { argument.hasPrefix($0) }) {
                index += 1
                continue
            }

            let width: Int
            if argument.contains("=") {
                width = 1
            } else if variadicOptions.contains(argument) {
                var end = index + 1
                while end < arguments.count, !arguments[end].hasPrefix("-") {
                    end += 1
                }
                width = max(1, end - index)
            } else if optionalValueOptions.contains(argument) {
                width = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-") ? 2 : 1
            } else if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                width = 2
            } else {
                width = 1
            }

            if droppedOptions.contains(argument) {
                index += width
                continue
            }
            result.append(contentsOf: arguments[index..<min(arguments.count, index + width)])
            index += width
        }
        return result
    }

    private static func commandWithEnvironment(
        _ arguments: [String],
        environment: [String: String]
    ) -> [String] {
        guard !environment.isEmpty else { return arguments }
        let values = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        return ["/usr/bin/env"] + values + arguments
    }

    private static func selectedEnvironment(
        from environment: [String: String],
        keys: Set<String>
    ) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = normalized(environment[key]) {
                result[key] = value
            }
        }
        return result
    }

    private static func isDescendant(
        _ pid: Int32,
        of ancestorPID: Int32,
        processByPID: [Int32: ConversationForkProcess]
    ) -> Bool {
        var current = pid
        var visited: Set<Int32> = []
        while visited.insert(current).inserted {
            if current == ancestorPID { return true }
            guard let process = processByPID[current], process.parentPID > 0 else { return false }
            current = process.parentPID
        }
        return false
    }

    private static func depth(
        of pid: Int32,
        from ancestorPID: Int32,
        processByPID: [Int32: ConversationForkProcess]
    ) -> Int {
        var current = pid
        var value = 0
        var visited: Set<Int32> = []
        while current != ancestorPID, visited.insert(current).inserted {
            guard let process = processByPID[current] else { return Int.max }
            current = process.parentPID
            value += 1
        }
        return current == ancestorPID ? value : Int.max
    }

    private static func isValidWuweiThreadID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128, value != ".", value != "..", !value.contains("..") else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
            && value.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } == true
    }

    private static func claudeLauncher(
        from environment: [String: String],
        fallbackExecutable: String
    ) -> (name: String, executable: String, recordedPath: String?) {
        guard let name = normalized(environment["CODEBOARD_CLAUDE_LAUNCHER"]),
              claudeNames.contains(name) else {
            let fallbackName = baseName(fallbackExecutable)
            return (fallbackName, fallbackExecutable, nil)
        }
        if let path = normalized(environment["CODEBOARD_CLAUDE_LAUNCHER_PATH"]),
           baseName(path) == name {
            return (name, path, path)
        }
        if name != baseName(fallbackExecutable) {
            return (name, name, nil)
        }
        return (name, fallbackExecutable, nil)
    }

    private static func baseName(_ value: String) -> String {
        URL(fileURLWithPath: value).lastPathComponent
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum SystemProcessInspector {
    private static let capturedEnvironmentKeys: Set<String> = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_EV_CONFIG_DIR",
        "CLAUDE_MAIN_CONFIG_DIR",
        "CONTEXT_SURGEON_DEBUG",
        "CONTEXT_SURGEON_DISABLE_SURGERY",
        "CONTEXT_SURGEON_DIRECTIVES_PATH",
        "CONTEXT_SURGEON_MAX_TOKENS",
        "CONTEXT_SURGEON_SESSIONS_DIRECTORY",
        "CONTEXT_SURGEON_TUNNEL_STARTUP_TIMEOUT_MS",
        "CONTEXT_SURGEON_UPSTREAM_ANTHROPIC",
        "CONTEXT_SURGEON_UPSTREAM_CHATGPT",
        "CONTEXT_SURGEON_UPSTREAM_OPENAI",
        "CODEBOARD_CLAUDE_SESSION_FILE",
        "CODEBOARD_CLAUDE_LAUNCHER",
        "CODEBOARD_CLAUDE_LAUNCHER_PATH",
        "WUWEI_RESUME_FILE",
        "WUWEI_SESSION_DIR",
        "WUWEI_THREAD_DIR",
        "WUWEI_WORKSPACE",
    ]

    static func descendants(of rootPID: Int32) -> [ConversationForkProcess] {
        let pairs = processPairs()
        var children: [Int32: [Int32]] = [:]
        for (pid, parentPID) in pairs {
            children[parentPID, default: []].append(pid)
        }

        var pending = [rootPID]
        var visited: Set<Int32> = []
        var result: [ConversationForkProcess] = []
        while let pid = pending.popLast() {
            guard visited.insert(pid).inserted else { continue }
            pending.append(contentsOf: children[pid] ?? [])
            guard let parentPID = pairs.first(where: { $0.pid == pid })?.parentPID,
                  let metadata = processMetadata(pid: pid) else {
                continue
            }
            result.append(ConversationForkProcess(
                pid: pid,
                parentPID: parentPID,
                arguments: metadata.arguments,
                environment: metadata.environment
            ))
        }
        return result
    }

    private static func processPairs() -> [(pid: Int32, parentPID: Int32)] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return []
            }
            return output.split(whereSeparator: \.isNewline).compactMap { line in
                let values = line.split(whereSeparator: \.isWhitespace)
                guard values.count >= 2,
                      let pid = Int32(values[0]),
                      let parentPID = Int32(values[1]) else {
                    return nil
                }
                return (pid, parentPID)
            }
        } catch {
            return []
        }
    }

    private static func processMetadata(pid: Int32) -> (arguments: [String], environment: [String: String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), nil, &size, nil, 0)
        }
        guard sizeResult == 0, size > MemoryLayout<Int32>.size else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        let readResult = mib.withUnsafeMutableBufferPointer { mibPointer in
            buffer.withUnsafeMutableBytes { bufferPointer in
                sysctl(
                    mibPointer.baseAddress,
                    u_int(mibPointer.count),
                    bufferPointer.baseAddress,
                    &size,
                    nil,
                    0
                )
            }
        }
        guard readResult == 0, size >= MemoryLayout<Int32>.size else { return nil }
        if size < buffer.count {
            buffer.removeSubrange(size..<buffer.count)
        }

        let argumentCount = buffer.withUnsafeBytes { pointer in
            Int(pointer.loadUnaligned(as: Int32.self))
        }
        guard argumentCount >= 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        consumeCString(in: buffer, index: &index)
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        for _ in 0..<argumentCount {
            guard let value = consumeCString(in: buffer, index: &index) else { break }
            arguments.append(value)
        }

        var environment: [String: String] = [:]
        while index < buffer.count {
            while index < buffer.count, buffer[index] == 0 { index += 1 }
            guard let entry = consumeCString(in: buffer, index: &index),
                  let separator = entry.firstIndex(of: "=") else {
                continue
            }
            let key = String(entry[..<separator])
            guard capturedEnvironmentKeys.contains(key) else { continue }
            environment[key] = String(entry[entry.index(after: separator)...])
        }
        return (arguments, environment)
    }

    @discardableResult
    private static func consumeCString(in buffer: [UInt8], index: inout Int) -> String? {
        guard index < buffer.count else { return nil }
        let start = index
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        let value = String(decoding: buffer[start..<index], as: UTF8.self)
        if index < buffer.count { index += 1 }
        return value
    }
}

@MainActor
enum ConversationForkSupport {
    static func launch(for tile: TerminalTile) throws -> ConversationForkLaunch {
        guard tile.usesPersistentSession,
              let panePID = TmuxSessionManager.shared.panePID(for: tile.id) else {
            throw ConversationForkError.persistentSessionRequired
        }
        return try ConversationForkResolver.resolve(
            panePID: panePID,
            processes: SystemProcessInspector.descendants(of: panePID)
        )
    }
}

enum AgentWrapperInstaller {
    static let hookSettingsJSON = codeboardClaudeHookSettingsJSON

    static var wrapperScript: String {
        #"""
    #!/bin/bash
    set -e

    target="$(basename "$0")"
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    real_cli=""
    old_ifs="$IFS"
    IFS=:
    for directory in ${PATH:-}; do
        [[ "$directory" == "$self_dir" ]] && continue
        candidate="$directory/$target"
        if [[ -x "$candidate" && ! "$candidate" -ef "$0" ]]; then
            real_cli="$candidate"
            break
        fi
    done
    IFS="$old_ifs"
    if [[ -z "$real_cli" ]]; then
        echo "codeboard: $target was not found behind the session wrapper" >&2
        exit 127
    fi

    if [[ "${CODEBOARD_CLAUDE_HOOK_INJECTED:-}" == "1" ]]; then
        unset CODEBOARD_CLAUDE_HOOK_INJECTED
        unset CLAUDECODE
        exec "$real_cli" "$@"
    fi

    if [[ "$target" == "claude-ev" ]]; then
        case "${1:-}" in
            --forget-token|--init|--login|--status|--store-token)
                exec "$real_cli" "$@"
                ;;
        esac
    fi

    case "${1:-}" in
        agents|auth|auto-mode|api-key|config|doctor|gateway|install|mcp|plugin|plugins|project|rc|remote-control|setup-token|ultrareview|update|upgrade)
            exec "$real_cli" "$@"
            ;;
    esac

    skip_session_id=false
    for argument in "$@"; do
        case "$argument" in
            --help|-h|--version|-v)
                unset CLAUDECODE
                exec "$real_cli" "$@"
                ;;
            --continue|-c|--resume|--resume=*|-r|--session-id|--session-id=*)
                skip_session_id=true
                ;;
        esac
    done

    if [[ -z "${CODEBOARD_CLAUDE_LAUNCHER:-}" ]]; then
        export CODEBOARD_CLAUDE_LAUNCHER="$target"
        export CODEBOARD_CLAUDE_LAUNCHER_PATH="$real_cli"
    fi
    export CODEBOARD_CLAUDE_HOOK="$self_dir/codeboard-claude-hook"
    hooks_json='\#(hookSettingsJSON)'
    unset CLAUDECODE
    if [[ "$skip_session_id" == true ]]; then
        exec "$real_cli" --settings "$hooks_json" "$@"
    fi

    session_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
    exec "$real_cli" --session-id "$session_id" --settings "$hooks_json" "$@"
    """#
    }

    static let hookScript = #"""
    #!/bin/bash
    set -e
    umask 077

    session_file="${CODEBOARD_CLAUDE_SESSION_FILE:-}"
    [[ -n "$session_file" ]] || exit 0
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    support_dir="$(cd "$self_dir/.." && pwd)"
    case "$session_file" in
        "$support_dir/agent-sessions/"*) ;;
        *) exit 0 ;;
    esac

    payload="$(/bin/cat)"
    session_id="$(printf '%s' "$payload" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null || true)"
    [[ "$session_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || exit 0

    /bin/mkdir -p "$(dirname "$session_file")"
    temp_file="$session_file.$$.$RANDOM"
    printf '%s\n' "$session_id" | /usr/bin/tr '[:upper:]' '[:lower:]' > "$temp_file"
    /bin/chmod 600 "$temp_file"
    /bin/mv -f "$temp_file" "$session_file"
    """#

    static func ensureInstalled(fileManager: FileManager = .default) throws {
        let directory = AppPaths.agentWrapperDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fileManager.createDirectory(at: AppPaths.agentSessionDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.agentSessionDirectory.path)
        for name in ["claude", "claude-ev"] {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            try wrapperScript.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let hookURL = directory.appendingPathComponent("codeboard-claude-hook", isDirectory: false)
        try hookScript.write(to: hookURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }
}
