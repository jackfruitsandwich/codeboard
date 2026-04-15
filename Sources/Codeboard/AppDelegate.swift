import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate?

    private var window: CanvasWindow?
    private let canvasController = CanvasViewController()
    private var didStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GhosttyRuntime.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard canvasController.needsQuitConfirmation() else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit codeboard?"
        alert.informativeText = "One or more terminals still have running shells. Quitting will close them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        Self.shared = self

        AppPaths.ensureConfigFileExists()
        guard GhosttyRuntime.shared.start(configURL: AppPaths.configURL) else {
            presentStartupFailureAlert()
            NSApp.terminate(nil)
            return
        }

        buildMenu()
        buildWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.canvasController.bootstrapInitialTileIfNeeded()
        }
    }

    @objc func newTerminal(_ sender: Any?) {
        if let window {
            window.beginSpawnShortcut()
        } else {
            canvasController.spawnTile()
        }
    }

    @objc func newIndependentTerminal(_ sender: Any?) {
        if let window {
            window.beginDuplicateShortcut()
        } else {
            canvasController.duplicateFocusedTile()
        }
    }

    @objc func newBrowser(_ sender: Any?) {
        canvasController.spawnBrowserTile()
    }

    @objc func closeFocusedTerminal(_ sender: Any?) {
        canvasController.closeFocusedTile()
    }

    @objc func browserGoBack(_ sender: Any?) {
        canvasController.browserGoBack()
    }

    @objc func browserGoForward(_ sender: Any?) {
        canvasController.browserGoForward()
    }

    @objc func browserReload(_ sender: Any?) {
        canvasController.browserReload()
    }

    @objc func openFocusedBrowserInDefaultBrowser(_ sender: Any?) {
        canvasController.openFocusedBrowserInDefaultBrowser()
    }

    @objc func centerCanvasOnFocusedTile(_ sender: Any?) {
        canvasController.centerOnFocusedTile()
    }

    @objc func zoomCanvasIn(_ sender: Any?) {
        canvasController.zoomIn()
    }

    @objc func zoomCanvasOut(_ sender: Any?) {
        canvasController.zoomOut()
    }

    @objc func reloadConfig(_ sender: Any?) {
        GhosttyRuntime.shared.reloadConfig(from: AppPaths.configURL)
    }

    @objc func revealConfig(_ sender: Any?) {
        AppPaths.ensureConfigFileExists()
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configURL])
    }

    func openURLFromTerminal(_ url: URL, sourceTileID: UUID?) {
        if BrowserURLSupport.isLocalDevelopmentURL(url) {
            canvasController.openBrowserTile(from: sourceTileID, url: url)
            return
        }

        NSWorkspace.shared.open(url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(browserGoBack(_:)):
            return canvasController.canGoBackInFocusedBrowser()
        case #selector(browserGoForward(_:)):
            return canvasController.canGoForwardInFocusedBrowser()
        case #selector(browserReload(_:)):
            return canvasController.canReloadFocusedBrowser()
        case #selector(openFocusedBrowserInDefaultBrowser(_:)):
            return canvasController.canOpenFocusedBrowserInDefaultBrowser()
        default:
            return true
        }
    }

    private func buildWindow() {
        let initialContentSize = CanvasViewController.initialContentSize
        let window = CanvasWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "codeboard"
        window.contentViewController = canvasController
        window.setContentSize(initialContentSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.canvasCommandHandler = canvasController
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func buildMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        NSApp.mainMenu = mainMenu

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "codeboard")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About codeboard", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit codeboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.target = nil
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.target = nil
        editMenu.addItem(pasteItem)

        let pastePlainItem = NSMenuItem(title: "Paste as Plain Text", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlainItem.keyEquivalentModifierMask = [.command, .shift]
        pastePlainItem.target = nil
        editMenu.addItem(pastePlainItem)

        let canvasMenuItem = NSMenuItem()
        mainMenu.addItem(canvasMenuItem)
        let canvasMenu = NSMenu(title: "Canvas")
        canvasMenuItem.submenu = canvasMenu

        let newTerminal = NSMenuItem(title: "New Terminal", action: #selector(self.newTerminal(_:)), keyEquivalent: "t")
        newTerminal.target = self
        canvasMenu.addItem(newTerminal)

        let newIndependentTerminal = NSMenuItem(title: "Duplicate Focused Tile", action: #selector(self.newIndependentTerminal(_:)), keyEquivalent: "d")
        newIndependentTerminal.target = self
        canvasMenu.addItem(newIndependentTerminal)

        let newBrowser = NSMenuItem(title: "New Browser", action: #selector(self.newBrowser(_:)), keyEquivalent: "b")
        newBrowser.target = self
        canvasMenu.addItem(newBrowser)

        let closeTile = NSMenuItem(title: "Close Focused Tile", action: #selector(self.closeFocusedTerminal(_:)), keyEquivalent: "")
        closeTile.target = self
        canvasMenu.addItem(closeTile)

        canvasMenu.addItem(.separator())

        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(self.zoomCanvasIn(_:)), keyEquivalent: "=")
        zoomIn.target = self
        canvasMenu.addItem(zoomIn)

        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(self.zoomCanvasOut(_:)), keyEquivalent: "-")
        zoomOut.target = self
        canvasMenu.addItem(zoomOut)

        canvasMenu.addItem(.separator())

        let centerCanvas = NSMenuItem(title: "Center on Focused Tile", action: #selector(self.centerCanvasOnFocusedTile(_:)), keyEquivalent: "0")
        centerCanvas.target = self
        canvasMenu.addItem(centerCanvas)

        let browserMenuItem = NSMenuItem()
        mainMenu.addItem(browserMenuItem)
        let browserMenu = NSMenu(title: "Browser")
        browserMenuItem.submenu = browserMenu

        let backItem = NSMenuItem(title: "Back", action: #selector(self.browserGoBack(_:)), keyEquivalent: "[")
        backItem.target = self
        browserMenu.addItem(backItem)

        let forwardItem = NSMenuItem(title: "Forward", action: #selector(self.browserGoForward(_:)), keyEquivalent: "]")
        forwardItem.target = self
        browserMenu.addItem(forwardItem)

        let reloadItem = NSMenuItem(title: "Reload", action: #selector(self.browserReload(_:)), keyEquivalent: "r")
        reloadItem.target = self
        browserMenu.addItem(reloadItem)

        browserMenu.addItem(.separator())

        let openDefaultItem = NSMenuItem(title: "Open in Default Browser", action: #selector(self.openFocusedBrowserInDefaultBrowser(_:)), keyEquivalent: "")
        openDefaultItem.target = self
        browserMenu.addItem(openDefaultItem)

        let configMenuItem = NSMenuItem()
        mainMenu.addItem(configMenuItem)
        let configMenu = NSMenu(title: "Config")
        configMenuItem.submenu = configMenu

        let revealConfig = NSMenuItem(title: "Reveal Config", action: #selector(self.revealConfig(_:)), keyEquivalent: "")
        revealConfig.target = self
        configMenu.addItem(revealConfig)

        let reloadConfig = NSMenuItem(title: "Reload Config", action: #selector(self.reloadConfig(_:)), keyEquivalent: "")
        reloadConfig.target = self
        configMenu.addItem(reloadConfig)
    }

    private func presentStartupFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Ghostty runtime failed to start"
        alert.informativeText = """
        Build GhosttyKit first, then run the app again.

        1. Select full Xcode
        2. Install zig
        3. Run ./scripts/setup-ghosttykit.sh
        """
        alert.alertStyle = .critical
        alert.runModal()
    }
}
