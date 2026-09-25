import XCTest
@testable import Codeboard

final class TerminalResizeSignalRelayTests: XCTestCase {
    func testWorkItemExecutesOnUtilityQueue() {
        let workItem = TerminalResizeSignalRelay.workItem(for: Int32.max)

        DispatchQueue.global(qos: .utility).async(execute: workItem)

        XCTAssertEqual(workItem.wait(timeout: .now() + 5), .success)
    }

    func testFindsOnlyDetachedDirectChildOfContextSurgeon() {
        let processes = [
            process(100, 1, ["/bin/zsh"]),
            process(110, 100, ["node", "/opt/homebrew/bin/context-surgeon", "claude-ev"]),
            process(120, 110, ["/opt/homebrew/bin/claude-ev"]),
            process(121, 120, ["caffeinate"]),
            process(130, 100, ["vim"]),
            process(200, 1, ["node", "/opt/homebrew/bin/context-surgeon", "claude"]),
            process(210, 200, ["/opt/homebrew/bin/claude"]),
        ]
        let processGroups: [Int32: Int32] = [
            100: 100,
            110: 110,
            120: 120,
            121: 120,
            130: 130,
            200: 200,
            210: 210,
        ]

        let result = TerminalResizeSignalRelay.detachedContextSurgeonProcessGroups(
            panePID: 100,
            processes: processes,
            processGroupID: { processGroups[$0] }
        )

        XCTAssertEqual(result, [120])
    }

    func testIgnoresDirectClaudeAndNonDetachedContextSurgeonChild() {
        let processes = [
            process(300, 1, ["/bin/zsh"]),
            process(310, 300, ["/opt/homebrew/bin/claude"]),
            process(320, 300, ["node", "/opt/homebrew/bin/context-surgeon", "claude"]),
            process(330, 320, ["/opt/homebrew/bin/claude"]),
        ]
        let processGroups: [Int32: Int32] = [
            300: 300,
            310: 310,
            320: 320,
            330: 320,
        ]

        let result = TerminalResizeSignalRelay.detachedContextSurgeonProcessGroups(
            panePID: 300,
            processes: processes,
            processGroupID: { processGroups[$0] }
        )

        XCTAssertTrue(result.isEmpty)
    }

    private func process(_ pid: Int32, _ parentPID: Int32, _ arguments: [String]) -> ConversationForkProcess {
        ConversationForkProcess(pid: pid, parentPID: parentPID, arguments: arguments, environment: [:])
    }
}
