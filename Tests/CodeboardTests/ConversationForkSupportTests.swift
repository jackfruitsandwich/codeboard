import Darwin
import Foundation
import XCTest
@testable import Codeboard

final class ConversationForkSupportTests: XCTestCase {
    func testDirectClaudeForkPreservesVariantAndSafeRuntimeOptions() throws {
        let processes = [
            process(10, 1, ["/bin/zsh"]),
            process(
                11,
                10,
                [
                    "/Users/example/.local/bin/claude",
                    "--session-id", "claude-session-1",
                    "--settings", AgentWrapperInstaller.hookSettingsJSON,
                    "--model", "claude-fable-5",
                    "--effort", "max",
                    "--prompt-suggestions", "false",
                    "--plugin-url", "/tmp/plugin.zip",
                    "initial prompt is not replayed",
                ],
                [
                    "CLAUDE_CONFIG_DIR": "/Users/example/.claude-ev",
                    "CLAUDE_EV_CONFIG_DIR": "/Users/example/.accounts/ev",
                    "CLAUDE_MAIN_CONFIG_DIR": "/Users/example/.accounts/main",
                    "CODEBOARD_CLAUDE_LAUNCHER": "claude-ev",
                    "CODEBOARD_CLAUDE_LAUNCHER_PATH": "/Users/example/.local/bin/claude-ev",
                ]
            ),
        ]

        let launch = try ConversationForkResolver.resolve(panePID: 10, processes: processes)

        XCTAssertEqual(launch.agentName, "claude-ev")
        XCTAssertEqual(launch.arguments, [
            "/usr/bin/env",
            "CLAUDE_CONFIG_DIR=/Users/example/.claude-ev",
            "CLAUDE_EV_CONFIG_DIR=/Users/example/.accounts/ev",
            "CLAUDE_MAIN_CONFIG_DIR=/Users/example/.accounts/main",
            "CODEBOARD_CLAUDE_HOOK=\(claudeHookPath)",
            "CODEBOARD_CLAUDE_HOOK_INJECTED=1",
            "CODEBOARD_CLAUDE_LAUNCHER=claude-ev",
            "CODEBOARD_CLAUDE_LAUNCHER_PATH=/Users/example/.local/bin/claude-ev",
            "/Users/example/.local/bin/claude-ev",
            "--settings", AgentWrapperInstaller.hookSettingsJSON,
            "--resume", "claude-session-1",
            "--fork-session",
            "--model", "claude-fable-5",
            "--effort", "max",
            "--prompt-suggestions", "false",
            "--plugin-url", "/tmp/plugin.zip",
        ])
    }

    func testClaudeHookReceiptWinsWhenForkProcessStillNamesItsParent() throws {
        let childSessionID = "7b931c2a-e2af-4a95-b60f-4f6d2ed7ae80"
        let processes = [
            process(12, 1, ["/bin/zsh"]),
            process(
                13,
                12,
                [
                    "/Users/example/.local/bin/claude",
                    "--resume", "1f4973e3-257c-40ee-893b-5a35630177f4",
                    "--fork-session",
                    "--model", "sonnet",
                ],
                ["CODEBOARD_CLAUDE_SESSION_FILE": "/tmp/codeboard-child-session"]
            ),
        ]

        let launch = try ConversationForkResolver.resolve(
            panePID: 12,
            processes: processes,
            readReceipt: { path in
                XCTAssertEqual(path, "/tmp/codeboard-child-session")
                return childSessionID.uppercased()
            }
        )

        XCTAssertEqual(launch.arguments, [
            "/usr/bin/env",
            "CODEBOARD_CLAUDE_HOOK=\(claudeHookPath)",
            "CODEBOARD_CLAUDE_HOOK_INJECTED=1",
            "CODEBOARD_CLAUDE_LAUNCHER=claude",
            "/Users/example/.local/bin/claude",
            "--settings", AgentWrapperInstaller.hookSettingsJSON,
            "--resume", childSessionID,
            "--fork-session",
            "--model", "sonnet",
        ])
    }

    func testContextSurgeonForkKeepsClaudeEVAndDirectiveStore() throws {
        let processes = [
            process(20, 1, ["/bin/zsh"]),
            process(
                21,
                20,
                ["node", "/opt/homebrew/bin/context-surgeon", "claude-ev", "--model", "sonnet"],
                [
                    "CONTEXT_SURGEON_DEBUG": "1",
                    "CONTEXT_SURGEON_DIRECTIVES_PATH": "/tmp/surgery directives.json",
                    "CONTEXT_SURGEON_SESSIONS_DIRECTORY": "/tmp/surgeon sessions",
                ]
            ),
            process(
                22,
                21,
                ["/Users/example/.local/bin/claude-ev", "--session-id", "claude-session-2"],
                [
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:1234/anthropic",
                    "CLAUDE_CONFIG_DIR": "/Users/example/.claude-ev",
                ]
            ),
        ]

        let launch = try ConversationForkResolver.resolve(panePID: 20, processes: processes)

        XCTAssertEqual(launch.agentName, "Context Surgeon claude-ev")
        XCTAssertEqual(launch.arguments, [
            "/usr/bin/env",
            "CLAUDE_CONFIG_DIR=/Users/example/.claude-ev",
            "CODEBOARD_CLAUDE_HOOK=\(claudeHookPath)",
            "CODEBOARD_CLAUDE_HOOK_INJECTED=1",
            "CONTEXT_SURGEON_DEBUG=1",
            "CONTEXT_SURGEON_DIRECTIVES_PATH=/tmp/surgery directives.json",
            "CONTEXT_SURGEON_SESSIONS_DIRECTORY=/tmp/surgeon sessions",
            "/opt/homebrew/bin/context-surgeon", "claude-ev",
            "--settings", AgentWrapperInstaller.hookSettingsJSON,
            "--resume", "claude-session-2", "--fork-session",
            "--model", "sonnet",
        ])
        XCTAssertFalse(launch.arguments.contains(where: { $0.contains("127.0.0.1:1234") }))
    }

    func testWuweiForkUsesSupervisorReceiptAndThreadDirectory() throws {
        let processes = [
            process(30, 1, ["/bin/zsh"]),
            process(
                31,
                30,
                ["bun", "/Users/example/.bun/bin/wuwei"],
                ["WUWEI_THREAD_DIR": "/tmp/wuwei threads"]
            ),
            process(
                32,
                31,
                ["bun", "/repo/wuwei/src/tui/main.tsx"],
                [
                    "WUWEI_RESUME_FILE": "/tmp/wuwei-supervise/thread",
                    "WUWEI_THREAD_DIR": "/tmp/wuwei threads",
                ]
            ),
        ]

        let launch = try ConversationForkResolver.resolve(
            panePID: 30,
            processes: processes,
            readReceipt: { path in
                XCTAssertEqual(path, "/tmp/wuwei-supervise/thread")
                return "2026-07-15-01-02-03-abcd\n"
            }
        )

        XCTAssertEqual(launch.agentName, "Wuwei")
        XCTAssertEqual(launch.arguments, [
            "/usr/bin/env",
            "WUWEI_THREAD_DIR=/tmp/wuwei threads",
            "/Users/example/.bun/bin/wuwei",
            "--fork", "2026-07-15-01-02-03-abcd",
        ])
    }

    func testRecognizedClaudeWithoutExactSessionFailsClosed() {
        let processes = [
            process(40, 1, ["/bin/zsh"]),
            process(41, 40, ["/Users/example/.local/bin/claude", "--continue"]),
        ]

        XCTAssertThrowsError(try ConversationForkResolver.resolve(panePID: 40, processes: processes)) { error in
            XCTAssertEqual(error as? ConversationForkError, .missingSessionIdentity("claude"))
        }
    }

    func testUnsupportedTerminalFailsClosed() {
        let processes = [
            process(50, 1, ["/bin/zsh"]),
            process(51, 50, ["vim", "README.md"]),
        ]

        XCTAssertThrowsError(try ConversationForkResolver.resolve(panePID: 50, processes: processes)) { error in
            XCTAssertEqual(error as? ConversationForkError, .unsupportedAgent)
        }
    }

    func testClaudeWrapperInjectsIdentityButLeavesResumeModesAlone() {
        let wrapper = AgentWrapperInstaller.wrapperScript

        XCTAssertTrue(wrapper.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(wrapper.contains("--session-id \"$session_id\""))
        XCTAssertTrue(wrapper.contains("--resume|--resume=*"))
        XCTAssertTrue(wrapper.contains("target=\"$(basename \"$0\")\""))
        XCTAssertTrue(wrapper.contains("CODEBOARD_CLAUDE_HOOK_INJECTED"))
        XCTAssertTrue(wrapper.contains(AgentWrapperInstaller.hookSettingsJSON))
    }

    func testClaudeWrapperIsValidBash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeboard-claude-wrapper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try AgentWrapperInstaller.wrapperScript.write(to: url, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testClaudeEVWrapperTracksVariantAndLeavesMaintenanceCommandsUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeboard-claude-ev-wrapper-\(UUID().uuidString)", isDirectory: true)
        let wrapperDirectory = root.appendingPathComponent("wrapper", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let wrapper = wrapperDirectory.appendingPathComponent("claude-ev")
        let real = realDirectory.appendingPathComponent("claude-ev")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try AgentWrapperInstaller.wrapperScript.write(to: wrapper, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/bash
        printf 'launcher=%s\n' "${CODEBOARD_CLAUDE_LAUNCHER:-}"
        printf 'launcher_path=%s\n' "${CODEBOARD_CLAUDE_LAUNCHER_PATH:-}"
        for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
        """#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let normal = try runWrapper(
            wrapper,
            arguments: ["--model", "sonnet"],
            path: "\(wrapperDirectory.path):\(realDirectory.path):/usr/bin:/bin"
        )
        XCTAssertTrue(normal.contains("launcher=claude-ev"))
        XCTAssertTrue(normal.contains("launcher_path=\(real.path)"))
        XCTAssertTrue(normal.contains("arg=--session-id"))
        XCTAssertTrue(normal.contains("arg=\(AgentWrapperInstaller.hookSettingsJSON)"))

        let maintenance = try runWrapper(
            wrapper,
            arguments: ["--status"],
            path: "\(wrapperDirectory.path):\(realDirectory.path):/usr/bin:/bin"
        )
        XCTAssertEqual(maintenance, ["launcher=", "launcher_path=", "arg=--status"])
    }

    func testClaudeSessionHookWritesOnlyInsideAgentSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeboard-hook-test-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("agent-bin", isDirectory: true)
        let sessions = root.appendingPathComponent("agent-sessions", isDirectory: true)
        let hook = bin.appendingPathComponent("codeboard-claude-hook")
        let receipt = sessions.appendingPathComponent("claude-test.session")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try AgentWrapperInstaller.hookScript.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let sessionID = "92c54a7d-66d8-420a-96d6-3e4fc419337a"
        let input = Pipe()
        input.fileHandleForWriting.write(Data("{\"session_id\":\"\(sessionID.uppercased())\"}".utf8))
        input.fileHandleForWriting.closeFile()

        let process = Process()
        process.executableURL = hook
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CODEBOARD_CLAUDE_SESSION_FILE": receipt.path,
        ], uniquingKeysWith: { _, current in current })
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: receipt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            sessionID
        )
    }

    func testTmuxSessionEnvironmentPrependsWrapperExactlyOnce() {
        let wrapperPath = AppPaths.agentWrapperDirectory.path
        let environment = TmuxSessionManager.sessionEnvironment(from: [
            "PATH": "/usr/bin:\(wrapperPath):/bin",
            "NO_COLOR": "1",
        ])

        XCTAssertEqual(environment["PATH"], "\(wrapperPath):/usr/bin:/bin")
        XCTAssertNil(environment["NO_COLOR"])
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
    }

    func testSystemProcessInspectorReadsExactCurrentProcessArguments() {
        let pid = getpid()
        let current = SystemProcessInspector.descendants(of: pid).first { $0.pid == pid }

        XCTAssertNotNil(current)
        XCTAssertFalse(current?.arguments.isEmpty ?? true)
    }

    private var claudeHookPath: String {
        AppPaths.agentWrapperDirectory
            .appendingPathComponent("codeboard-claude-hook", isDirectory: false)
            .path
    }

    private func runWrapper(_ executable: URL, arguments: [String], path: String) throws -> [String] {
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment.removeValue(forKey: "CODEBOARD_CLAUDE_HOOK_INJECTED")
        environment.removeValue(forKey: "CODEBOARD_CLAUDE_LAUNCHER")
        environment.removeValue(forKey: "CODEBOARD_CLAUDE_LAUNCHER_PATH")
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    private func process(
        _ pid: Int32,
        _ parentPID: Int32,
        _ arguments: [String],
        _ environment: [String: String] = [:]
    ) -> ConversationForkProcess {
        ConversationForkProcess(
            pid: pid,
            parentPID: parentPID,
            arguments: arguments,
            environment: environment
        )
    }
}
