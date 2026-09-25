import Foundation
import XCTest
@testable import Codeboard

final class WorkspaceStateTests: XCTestCase {
    func testSchemaOneRoundTripPreservesStableIdentityAndViewport() throws {
        let id = UUID()
        let state = WorkspaceState(
            tiles: [WorkspaceTileState(
                id: id,
                kind: .terminal,
                index: 7,
                x: -2,
                y: 4,
                width: 2,
                height: 1,
                workingDirectory: "/tmp/project",
                browserURL: nil
            )],
            focusedTileID: id,
            zoomScale: 0.9,
            gridHalfSpan: 128,
            scrollOrigin: WorkspacePoint(CGPoint(x: 120, y: 240)),
            windowFrame: WorkspaceRect(CGRect(x: 10, y: 20, width: 800, height: 600))
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.tiles.first?.id, id)
        XCTAssertEqual(decoded.tiles.first?.workingDirectory, "/tmp/project")
        XCTAssertEqual(decoded.scrollOrigin, WorkspacePoint(CGPoint(x: 120, y: 240)))
        XCTAssertEqual(decoded.windowFrame, WorkspaceRect(CGRect(x: 10, y: 20, width: 800, height: 600)))
    }

    @MainActor
    func testTmuxSessionNamesAreStableAndExactMatchSafe() {
        let id = UUID(uuidString: "92c54a7d-66d8-420a-96d6-3e4fc419337a")!
        XCTAssertEqual(
            TmuxSessionManager.shared.sessionName(for: id),
            "cb-92c54a7d-66d8-420a-96d6-3e4fc419337a"
        )
        XCTAssertEqual(
            TmuxSessionManager.paneTarget(for: id),
            "=cb-92c54a7d-66d8-420a-96d6-3e4fc419337a:0.0"
        )
    }

    @MainActor
    func testPrivateTmuxConfigAdvertisesInnerAndOuterTrueColor() {
        let config = TmuxSessionManager.privateConfigContents

        XCTAssertTrue(config.contains("default-terminal tmux-256color"))
        XCTAssertTrue(config.contains("xterm-ghostty*:RGB:extkeys"))
        XCTAssertTrue(config.contains("set-environment -g COLORTERM truecolor"))
        XCTAssertTrue(config.contains("set-environment -gu NO_COLOR"))
    }

    func testPrivateTmuxConfigPreservesModifiedEnterWithCSIU() {
        let config = TmuxSessionManager.privateConfigContents

        XCTAssertTrue(config.contains("set -s extended-keys on"))
        XCTAssertTrue(config.contains("set -s extended-keys-format csi-u"))
        XCTAssertTrue(config.contains("xterm-ghostty*:RGB:extkeys"))
    }

    func testPrivateTmuxConfigBridgesCopyModeAndApplicationClipboardWritesToMacOS() {
        let config = TmuxSessionManager.privateConfigContents

        XCTAssertTrue(config.contains("set -s copy-command '/usr/bin/pbcopy'"))
        XCTAssertTrue(config.contains("set -s set-clipboard on"))
        XCTAssertTrue(config.contains("set-hook -gu pane-set-clipboard"))
        XCTAssertFalse(config.contains("run-shell \"tmux "))
    }

    func testTmuxProcessEnvironmentForcesColorCapabilities() {
        let environment = TmuxSessionManager.processEnvironment(from: [
            "NO_COLOR": "1",
            "COLORTERM": "",
            "PATH": "/usr/bin",
        ])

        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertNil(environment["NO_COLOR"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testNewSessionBootstrapRestoresWrapperPrecedenceAfterLoginShellStartup() {
        let wrapperDirectory = "/tmp/codeboard agent/bin"

        XCTAssertEqual(
            TmuxSessionManager.shellBootstrapInput(wrapperDirectory: wrapperDirectory, shellPath: "/bin/zsh"),
            " export PATH='/tmp/codeboard agent/bin':\"$PATH\"\n"
        )
        XCTAssertEqual(
            TmuxSessionManager.shellBootstrapInput(wrapperDirectory: wrapperDirectory, shellPath: "/opt/homebrew/bin/fish"),
            " set -gx PATH '/tmp/codeboard agent/bin' $PATH\n"
        )
        XCTAssertNil(
            TmuxSessionManager.shellBootstrapInput(wrapperDirectory: wrapperDirectory, shellPath: "/bin/unknown")
        )
    }

    func testTmuxLaunchCreatesOrAttachesAtTheOuterPTYSize() {
        let id = UUID(uuidString: "92c54a7d-66d8-420a-96d6-3e4fc419337a")!
        let arguments = TmuxSessionManager.launchArguments(
            executablePath: "/opt/homebrew/bin/tmux",
            tileID: id,
            workingDirectory: "/tmp/project with spaces",
            configPath: "/tmp/codeboard tmux.conf",
            inheritedEnvironment: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(arguments.prefix(6), [
            "/opt/homebrew/bin/tmux", "-L", "codeboard", "-f", "/tmp/codeboard tmux.conf", "new-session",
        ])
        XCTAssertTrue(arguments.contains("-A"))
        XCTAssertFalse(arguments.contains("-d"))
        XCTAssertTrue(arguments.contains("cb-92c54a7d-66d8-420a-96d6-3e4fc419337a"))
        XCTAssertTrue(arguments.contains("/tmp/project with spaces"))
    }

    func testTmuxWindowSizeTracksTheLargestAttachedHandoffClient() {
        XCTAssertTrue(TmuxSessionManager.privateConfigContents.contains("set -g window-size largest"))
        XCTAssertFalse(TmuxSessionManager.privateConfigContents.contains("set -g window-size latest"))
    }
}
