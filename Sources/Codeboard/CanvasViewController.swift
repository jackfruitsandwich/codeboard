import AppKit
import Foundation
import GhosttyKit

private enum FocusViewportBehavior {
    case center
    case revealIfNeeded
}

private struct TileResizeSession {
    let origin: GridPoint
    let span: GridSize
    let frame: CGRect
}

private enum PendingDirectionalAction {
    case spawnTerminal
    case duplicateTile
}

@MainActor
protocol CanvasCommandHandling: AnyObject {
    func spawnTile()
    func spawnTile(in direction: NavigationDirection)
    func duplicateFocusedTile()
    func duplicateFocusedTile(in direction: NavigationDirection)
    func forkFocusedConversation()
    func spawnIndependentTile()
    func spawnBrowserTile()
    func focusTile(in direction: NavigationDirection)
    func closeFocusedTile()
    func centerOnFocusedTile()
    func zoomIn()
    func zoomOut()
    func adjustZoom(magnificationDelta: CGFloat)
}

@MainActor
final class CanvasWindow: NSWindow {
    weak var canvasCommandHandler: CanvasCommandHandling?
    private var pendingDirectionalAction: PendingDirectionalAction?
    private var pendingDirectionalWorkItem: DispatchWorkItem?
    private let directionalSpawnDelay: TimeInterval = 0.25

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = normalizedFlags(for: event)
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleCommandKeyDown(event) {
            return
        }

        super.sendEvent(event)
    }

    private func handleCommandKeyDown(_ event: NSEvent) -> Bool {
        let flags = normalizedFlags(for: event)

        if pendingDirectionalAction != nil {
            if isPlainCommandShortcut(flags), let direction = Self.direction(for: event.keyCode) {
                completeDirectionalAction(in: direction)
                return true
            }
        }

        guard isPlainCommandShortcut(flags) else {
            return false
        }

        switch event.keyCode {
        case 123:
            canvasCommandHandler?.focusTile(in: .left)
            return true
        case 124:
            canvasCommandHandler?.focusTile(in: .right)
            return true
        case 125:
            canvasCommandHandler?.focusTile(in: .down)
            return true
        case 126:
            canvasCommandHandler?.focusTile(in: .up)
            return true
        case 51, 117:
            canvasCommandHandler?.closeFocusedTile()
            return true
        case 24:
            canvasCommandHandler?.zoomIn()
            return true
        case 27:
            canvasCommandHandler?.zoomOut()
            return true
        default:
            return false
        }
    }

    private func normalizedFlags(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
    }

    private func isPlainCommandShortcut(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags == [.command]
    }

    func beginSpawnShortcut() {
        armDirectionalAction(.spawnTerminal)
    }

    func beginDuplicateShortcut() {
        armDirectionalAction(.duplicateTile)
    }

    private func armDirectionalAction(_ action: PendingDirectionalAction) {
        pendingDirectionalWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDirectionalWorkItem = nil
            let action = self.pendingDirectionalAction
            self.pendingDirectionalAction = nil
            self.performDirectionalAction(action, direction: nil)
        }
        pendingDirectionalAction = action
        pendingDirectionalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + directionalSpawnDelay, execute: workItem)
    }

    private func completeDirectionalAction(in direction: NavigationDirection) {
        pendingDirectionalWorkItem?.cancel()
        pendingDirectionalWorkItem = nil
        let action = pendingDirectionalAction
        pendingDirectionalAction = nil
        performDirectionalAction(action, direction: direction)
    }

    private func finalizePendingDirectionalSpawn() {
        guard pendingDirectionalAction != nil else { return }
        pendingDirectionalWorkItem?.cancel()
        pendingDirectionalWorkItem = nil
        let action = pendingDirectionalAction
        pendingDirectionalAction = nil
        performDirectionalAction(action, direction: nil)
    }

    private func performDirectionalAction(_ action: PendingDirectionalAction?, direction: NavigationDirection?) {
        switch (action, direction) {
        case (.spawnTerminal, .some(let direction)):
            canvasCommandHandler?.spawnTile(in: direction)
        case (.spawnTerminal, .none):
            canvasCommandHandler?.spawnTile()
        case (.duplicateTile, .some(let direction)):
            canvasCommandHandler?.duplicateFocusedTile(in: direction)
        case (.duplicateTile, .none):
            canvasCommandHandler?.duplicateFocusedTile()
        case (.none, _):
            break
        }
    }

    private static func direction(for keyCode: UInt16) -> NavigationDirection? {
        switch keyCode {
        case 123:
            return .left
        case 124:
            return .right
        case 125:
            return .down
        case 126:
            return .up
        default:
            return nil
        }
    }
}

@MainActor
final class CanvasViewController: NSViewController, CanvasCommandHandling {
    private struct KeyboardExpansion {
        let tileID: UUID
        let direction: NavigationDirection
        let originalRect: GridRect
        let expandedRect: GridRect
        let timestamp: TimeInterval
    }

    static let initialContentSize = NSSize(width: 1480, height: 920)
    private static let defaultZoomScale: CGFloat = 0.75421142578125

    private let fullscreenBackgroundView = NSImageView(frame: .zero)
    private let backdropView = NSVisualEffectView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let documentView = CanvasDocumentView(frame: .zero)
    private let model = CanvasModel()

    private var tiles: [UUID: CanvasTile] = [:]
    private let baseTileSize = CGSize(width: 920, height: 620)
    private var zoomScale: CGFloat = CanvasViewController.defaultZoomScale
    private let minZoomScale: CGFloat = 0.4
    private let maxZoomScale: CGFloat = 1.8
    private var gridHalfSpan = 64
    private let canvasInset: CGFloat = 60

    private var didCenterInitialViewport = false
    private var isApplyingFocus = false
    private var activeResizeSessions: [UUID: TileResizeSession] = [:]
    private var recentKeyboardExpansion: KeyboardExpansion?
    private var didPresentTmuxFailure = false
    private var pendingWorkspaceSave: DispatchWorkItem?
    private var isRestoringWorkspace = false
    private var scrollBoundsObserver: NSObjectProtocol?

    private var tileSize: CGSize {
        CGSize(width: baseTileSize.width * zoomScale, height: baseTileSize.height * zoomScale)
    }

    private var tileGap: CGFloat {
        max(6, 10 * zoomScale)
    }

    override func loadView() {
        view = FlippedView(frame: NSRect(origin: .zero, size: Self.initialContentSize))
        view.wantsLayer = true

        fullscreenBackgroundView.imageScaling = .scaleAxesIndependently
        fullscreenBackgroundView.imageAlignment = .alignCenter
        fullscreenBackgroundView.isHidden = true
        view.addSubview(fullscreenBackgroundView)

        backdropView.material = .hudWindow
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        view.addSubview(backdropView)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleWorkspaceSave()
            }
        }

        documentView.onMagnifyGesture = { [weak self] delta in
            self?.adjustZoom(magnificationDelta: delta)
        }
        documentView.onZoomScroll = { [weak self] delta in
            self?.adjustZoom(magnificationDelta: delta)
        }
        documentView.onBackgroundMouseDown = { [weak self] in
            self?.clearFocusedTile()
        }

        updateDocumentMetrics()
        scrollView.documentView = documentView
        view.addSubview(scrollView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fullscreenBackgroundView.frame = view.bounds
        backdropView.frame = view.bounds
        scrollView.frame = view.bounds
        if !didCenterInitialViewport {
            didCenterInitialViewport = true
            centerOnGridPoint(.origin)
        }
    }

    func setFullscreenAppearance(_ isFullscreen: Bool) {
        loadViewIfNeeded()

        if isFullscreen, let image = NSImage(contentsOf: AppPaths.fullscreenDesktopURL) {
            fullscreenBackgroundView.image = image
            fullscreenBackgroundView.isHidden = false
            backdropView.blendingMode = .withinWindow
            return
        }

        backdropView.blendingMode = .behindWindow
        fullscreenBackgroundView.isHidden = true
        fullscreenBackgroundView.image = nil
    }

    func bootstrapInitialTileIfNeeded() {
        guard tiles.isEmpty else { return }
        spawnTile()
    }

    @discardableResult
    func restoreWorkspace(_ state: WorkspaceState) -> Bool {
        guard state.schemaVersion == WorkspaceState.currentSchemaVersion, !state.tiles.isEmpty else { return false }
        loadViewIfNeeded()
        pendingWorkspaceSave?.cancel()
        pendingWorkspaceSave = nil
        isRestoringWorkspace = true
        defer {
            isRestoringWorkspace = false
            scheduleWorkspaceSave()
        }

        zoomScale = min(max(CGFloat(state.zoomScale), minZoomScale), maxZoomScale)
        gridHalfSpan = max(64, state.gridHalfSpan)
        updateDocumentMetrics()

        for savedTile in state.tiles.sorted(by: { $0.index < $1.index }) {
            let point = GridPoint(x: savedTile.x, y: savedTile.y)
            let span = GridSize(width: max(1, savedTile.width), height: max(1, savedTile.height))
            ensureCapacity(for: point)
            ensureCapacity(for: GridPoint(x: point.x + span.width - 1, y: point.y + span.height - 1))

            switch savedTile.kind {
            case .terminal:
                let workingDirectory = savedTile.workingDirectory ?? defaultInitialWorkingDirectory()
                let persistent = preparePersistentSession(tileID: savedTile.id)
                var options = TerminalLaunchOptions(
                    workingDirectory: workingDirectory,
                    command: persistent
                        ? TmuxSessionManager.shared.launchCommand(for: savedTile.id, workingDirectory: workingDirectory)
                        : nil,
                    context: tiles.isEmpty ? GHOSTTY_SURFACE_CONTEXT_WINDOW : GHOSTTY_SURFACE_CONTEXT_SPLIT
                )
                options.initialInput = persistent
                    ? TmuxSessionManager.shared.consumeShellBootstrapInput(for: savedTile.id)
                    : nil
                let tile = TerminalTile(
                    id: savedTile.id,
                    index: savedTile.index,
                    position: point,
                    span: span,
                    launchOptions: options,
                    usesPersistentSession: persistent
                )
                installTileCallbacks(tile)
                addTile(tile, focusAfterAdding: false)
            case .browser:
                let tile = BrowserTile(
                    id: savedTile.id,
                    index: savedTile.index,
                    position: point,
                    span: span,
                    initialURL: savedTile.browserURL.flatMap(URL.init(string:))
                )
                installTileCallbacks(tile)
                addTile(tile, focusAfterAdding: false)
            }
        }

        didCenterInitialViewport = true
        if let focusedID = state.focusedTileID, tiles[focusedID] != nil {
            focus(tileID: focusedID, makeFirstResponder: true, viewportBehavior: .revealIfNeeded)
        } else if let firstID = state.tiles.sorted(by: { $0.index < $1.index }).first?.id {
            focus(tileID: firstID, makeFirstResponder: true, viewportBehavior: .revealIfNeeded)
        }

        let scrollOrigin = state.scrollOrigin.cgPoint
        let restoredTerminalIDs = Set(state.tiles.filter { $0.kind == .terminal }.map(\.id))
        let unmatchedSessions = TmuxSessionManager.shared.existingTileIDs().filter { !restoredTerminalIDs.contains($0) }
        if !unmatchedSessions.isEmpty {
            NSLog("codeboard: preserving %d unmatched private tmux session(s): %@", unmatchedSessions.count, unmatchedSessions.map(\.uuidString).joined(separator: ", "))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollView.contentView.scroll(to: self.clampedScrollOrigin(scrollOrigin))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
        return !tiles.isEmpty
    }

    func saveWorkspaceNow(windowFrame: CGRect? = nil) {
        guard !isRestoringWorkspace else { return }
        pendingWorkspaceSave?.cancel()
        pendingWorkspaceSave = nil
        let persistentTerminalIDs = Set(tiles.values.compactMap { tile -> UUID? in
            guard let terminal = tile as? TerminalTile, terminal.usesPersistentSession else { return nil }
            return terminal.id
        })
        let liveWorkingDirectories = TmuxSessionManager.shared.currentPaths(for: persistentTerminalIDs)
        let savedTiles = tiles.values.sorted(by: { $0.index < $1.index }).map { tile in
            if let terminal = tile as? TerminalTile {
                return WorkspaceTileState(
                    id: terminal.id,
                    kind: .terminal,
                    index: terminal.index,
                    x: terminal.position.x,
                    y: terminal.position.y,
                    width: terminal.span.width,
                    height: terminal.span.height,
                    workingDirectory: terminal.usesPersistentSession
                        ? (liveWorkingDirectories[terminal.id] ?? terminal.launchOptions.workingDirectory)
                        : terminal.launchOptions.workingDirectory,
                    browserURL: nil
                )
            }
            let browser = tile as? BrowserTile
            return WorkspaceTileState(
                id: tile.id,
                kind: .browser,
                index: tile.index,
                x: tile.position.x,
                y: tile.position.y,
                width: tile.span.width,
                height: tile.span.height,
                workingDirectory: nil,
                browserURL: browser?.currentURL?.absoluteString
            )
        }
        let state = WorkspaceState(
            tiles: savedTiles,
            focusedTileID: model.focusedTileID,
            zoomScale: Double(zoomScale),
            gridHalfSpan: gridHalfSpan,
            scrollOrigin: WorkspacePoint(scrollView.contentView.bounds.origin),
            windowFrame: (windowFrame ?? view.window?.frame).map(WorkspaceRect.init)
        )
        do {
            try WorkspaceStore.shared.save(state)
        } catch {
            NSLog("codeboard: could not save workspace: %@", error.localizedDescription)
        }
    }

    func scheduleWorkspaceSave() {
        guard !isRestoringWorkspace else { return }
        pendingWorkspaceSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveWorkspaceNow() }
        pendingWorkspaceSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    func spawnTile() {
        spawnTile(preferredDirection: nil)
    }

    func spawnTile(in direction: NavigationDirection) {
        spawnTile(preferredDirection: direction)
    }

    func spawnIndependentTile() {
        spawnTile(preferredDirection: nil, anchorID: nil, inheritContext: false)
    }

    func duplicateFocusedTile() {
        duplicateFocusedTile(preferredDirection: nil)
    }

    func duplicateFocusedTile(in direction: NavigationDirection) {
        duplicateFocusedTile(preferredDirection: direction)
    }

    func forkFocusedConversation() {
        guard let focusedTileID = model.focusedTileID else {
            presentConversationForkFailure(ConversationForkError.unsupportedAgent)
            return
        }
        forkConversation(from: focusedTileID)
    }

    func hasFocusedTerminal() -> Bool {
        guard let focusedTileID = model.focusedTileID else { return false }
        return tiles[focusedTileID] is TerminalTile
    }

    func spawnBrowserTile() {
        spawnBrowserTile(preferredDirection: nil, anchorID: model.focusedTileID, initialURL: nil)
    }

    private func spawnTile(preferredDirection: NavigationDirection?) {
        spawnTile(preferredDirection: preferredDirection, anchorID: model.focusedTileID, inheritContext: true)
    }

    private func spawnTile(
        preferredDirection: NavigationDirection?,
        anchorID: UUID?,
        inheritContext: Bool
    ) {
        let point: GridPoint
        if let anchorID {
            point = model.nextSpawnPoint(near: anchorID, preferredDirection: preferredDirection)
        } else {
            point = model.nextSpawnPoint(around: visibleCenterGridPoint(), preferredDirection: preferredDirection)
        }
        ensureCapacity(for: point)

        let anchorTerminal = anchorID.flatMap { tiles[$0] as? TerminalTile }

        var launchOptions = inheritContext
            ? (anchorTerminal?.launchOptions ?? TerminalLaunchOptions())
            : TerminalLaunchOptions()
        if launchOptions.workingDirectory == nil {
            launchOptions.workingDirectory = defaultInitialWorkingDirectory()
        }
        if let anchorTerminal,
           anchorTerminal.usesPersistentSession,
           let livePath = TmuxSessionManager.shared.currentPath(for: anchorTerminal.id) {
            launchOptions.workingDirectory = livePath
        }
        launchOptions.context = tiles.isEmpty ? GHOSTTY_SURFACE_CONTEXT_WINDOW : GHOSTTY_SURFACE_CONTEXT_SPLIT
        let configTemplate = inheritContext
            ? anchorTerminal
                .flatMap { $0.surface }
                .map { GhosttySurfaceTemplate(cConfig: ghostty_surface_inherited_config($0, launchOptions.context)) }
            : nil

        // `cmd+t` should mean "new shell in the same folder", not "repeat the
        // prior launch command". Prefer Ghostty's live inherited working
        // directory when available so `cd` changes are respected.
        if let inheritedWorkingDirectory = configTemplate?.workingDirectory, !inheritedWorkingDirectory.isEmpty {
            launchOptions.workingDirectory = inheritedWorkingDirectory
        }
        let tileID = UUID()
        let workingDirectory = launchOptions.workingDirectory ?? defaultInitialWorkingDirectory()
        let usesPersistentSession = preparePersistentSession(tileID: tileID)
        launchOptions.command = usesPersistentSession
            ? TmuxSessionManager.shared.launchCommand(for: tileID, workingDirectory: workingDirectory)
            : nil
        launchOptions.initialInput = usesPersistentSession
            ? TmuxSessionManager.shared.consumeShellBootstrapInput(for: tileID)
            : nil

        let tile = TerminalTile(
            id: tileID,
            index: nextTileIndex(),
            position: point,
            launchOptions: launchOptions,
            configTemplate: configTemplate,
            usesPersistentSession: usesPersistentSession
        )
        installTileCallbacks(tile)
        addTile(tile)
    }

    private func duplicateFocusedTile(preferredDirection: NavigationDirection?) {
        guard let focusedTileID = model.focusedTileID,
              let sourceTile = tiles[focusedTileID],
              let point = duplicateSpawnPoint(near: focusedTileID, span: sourceTile.span, preferredDirection: preferredDirection) else {
            return
        }

        ensureCapacity(for: point)
        ensureCapacity(for: GridPoint(
            x: point.x + sourceTile.span.width - 1,
            y: point.y + sourceTile.span.height - 1
        ))

        if let sourceTerminal = sourceTile as? TerminalTile {
            duplicateTerminal(sourceTerminal, at: point)
            return
        }

        if let sourceBrowser = sourceTile as? BrowserTile {
            duplicateBrowser(sourceBrowser, at: point)
        }
    }

    private func duplicateTerminal(_ sourceTile: TerminalTile, at point: GridPoint) {
        var launchOptions = sourceTile.launchOptions
        if launchOptions.workingDirectory == nil {
            launchOptions.workingDirectory = defaultInitialWorkingDirectory()
        }
        let liveWorkingDirectory = sourceTile.usesPersistentSession
            ? TmuxSessionManager.shared.currentPath(for: sourceTile.id)
            : nil
        launchOptions.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        let configTemplate = sourceTile.surface
            .map { GhosttySurfaceTemplate(cConfig: ghostty_surface_inherited_config($0, launchOptions.context)) }

        if let inheritedWorkingDirectory = configTemplate?.workingDirectory, !inheritedWorkingDirectory.isEmpty {
            launchOptions.workingDirectory = inheritedWorkingDirectory
        }
        if let liveWorkingDirectory {
            launchOptions.workingDirectory = liveWorkingDirectory
        }
        let tileID = UUID()
        let workingDirectory = launchOptions.workingDirectory ?? defaultInitialWorkingDirectory()
        let usesPersistentSession = preparePersistentSession(tileID: tileID)
        launchOptions.command = usesPersistentSession
            ? TmuxSessionManager.shared.launchCommand(for: tileID, workingDirectory: workingDirectory)
            : nil
        launchOptions.initialInput = usesPersistentSession
            ? TmuxSessionManager.shared.consumeShellBootstrapInput(for: tileID)
            : nil

        let tile = TerminalTile(
            id: tileID,
            index: nextTileIndex(),
            position: point,
            span: sourceTile.span,
            launchOptions: launchOptions,
            configTemplate: configTemplate,
            usesPersistentSession: usesPersistentSession
        )
        installTileCallbacks(tile)
        addTile(tile)
    }

    private func forkConversation(from sourceTileID: UUID) {
        guard let sourceTile = tiles[sourceTileID] as? TerminalTile else {
            presentConversationForkFailure(ConversationForkError.unsupportedAgent)
            return
        }

        let forkLaunch: ConversationForkLaunch
        do {
            forkLaunch = try ConversationForkSupport.launch(for: sourceTile)
        } catch {
            presentConversationForkFailure(error)
            return
        }

        guard let point = duplicateSpawnPoint(
            near: sourceTileID,
            span: sourceTile.span,
            preferredDirection: .right
        ) else {
            NSSound.beep()
            return
        }
        ensureCapacity(for: point)
        ensureCapacity(for: GridPoint(
            x: point.x + sourceTile.span.width - 1,
            y: point.y + sourceTile.span.height - 1
        ))

        var launchOptions = sourceTile.launchOptions
        let liveWorkingDirectory = sourceTile.usesPersistentSession
            ? TmuxSessionManager.shared.currentPath(for: sourceTile.id)
            : nil
        if launchOptions.workingDirectory == nil {
            launchOptions.workingDirectory = defaultInitialWorkingDirectory()
        }
        launchOptions.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        let configTemplate = sourceTile.surface
            .map { GhosttySurfaceTemplate(cConfig: ghostty_surface_inherited_config($0, launchOptions.context)) }
        if let inheritedWorkingDirectory = configTemplate?.workingDirectory,
           !inheritedWorkingDirectory.isEmpty {
            launchOptions.workingDirectory = inheritedWorkingDirectory
        }
        if let liveWorkingDirectory {
            launchOptions.workingDirectory = liveWorkingDirectory
        }

        let tileID = UUID()
        let workingDirectory = launchOptions.workingDirectory ?? defaultInitialWorkingDirectory()
        let usesPersistentSession = preparePersistentSession(tileID: tileID)
        launchOptions.command = usesPersistentSession
            ? TmuxSessionManager.shared.launchCommand(for: tileID, workingDirectory: workingDirectory)
            : nil
        let shellBootstrap = usesPersistentSession
            ? (TmuxSessionManager.shared.consumeShellBootstrapInput(for: tileID) ?? "")
            : ""
        launchOptions.initialInput = shellBootstrap + forkLaunch.shellCommand + "\n"

        let tile = TerminalTile(
            id: tileID,
            index: nextTileIndex(),
            position: point,
            span: sourceTile.span,
            launchOptions: launchOptions,
            configTemplate: configTemplate,
            usesPersistentSession: usesPersistentSession
        )
        installTileCallbacks(tile)
        addTile(tile)
    }

    private func duplicateBrowser(_ sourceTile: BrowserTile, at point: GridPoint) {
        let tile = BrowserTile(
            index: nextTileIndex(),
            position: point,
            span: sourceTile.span,
            initialURL: sourceTile.currentURL
        )
        installTileCallbacks(tile)
        addTile(tile)
    }

    func openBrowserTile(from sourceTileID: UUID?, url: URL) {
        spawnBrowserTile(preferredDirection: .right, anchorID: sourceTileID, initialURL: url)
    }

    func browserGoBack() {
        focusedBrowserTile()?.goBack()
    }

    func browserGoForward() {
        focusedBrowserTile()?.goForward()
    }

    func browserReload() {
        focusedBrowserTile()?.reload()
    }

    func openFocusedBrowserInDefaultBrowser() {
        focusedBrowserTile()?.openCurrentPageInDefaultBrowser()
    }

    func hasFocusedBrowser() -> Bool {
        focusedBrowserTile() != nil
    }

    func canGoBackInFocusedBrowser() -> Bool {
        focusedBrowserTile()?.canGoBack == true
    }

    func canGoForwardInFocusedBrowser() -> Bool {
        focusedBrowserTile()?.canGoForward == true
    }

    func canReloadFocusedBrowser() -> Bool {
        focusedBrowserTile()?.canReload == true
    }

    func canOpenFocusedBrowserInDefaultBrowser() -> Bool {
        focusedBrowserTile()?.canOpenInDefaultBrowser == true
    }

    func focusTile(in direction: NavigationDirection) {
        let expansion = recentKeyboardExpansion
        recentKeyboardExpansion = nil
        if let expansion,
           ProcessInfo.processInfo.systemUptime - expansion.timestamp <= 2,
           model.focusedTileID == expansion.tileID,
           direction.deltaX == -expansion.direction.deltaX,
           direction.deltaY == -expansion.direction.deltaY,
           activeResizeSessions[expansion.tileID] == nil,
           model.rect(for: expansion.tileID) == expansion.expandedRect,
           let tile = tiles[expansion.tileID],
           model.update(tileID: expansion.tileID, to: expansion.originalRect.origin, size: expansion.originalRect.size) {
            tile.position = expansion.originalRect.origin
            tile.span = expansion.originalRect.size
            layout(tile: tile)
            tile.containerView.layoutSubtreeIfNeeded()
            scheduleWorkspaceSave()
            focus(tileID: expansion.tileID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
            return
        }

        if model.focusedTileID == nil, let fallbackID = model.nearestTile(to: .origin) {
            focus(tileID: fallbackID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
            return
        }

        if let nextID = model.nextFocus(from: model.focusedTileID, direction: direction) {
            focus(tileID: nextID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
            return
        }

        guard let focusedTileID = model.focusedTileID,
              let originalRect = model.rect(for: focusedTileID),
              activeResizeSessions[focusedTileID] == nil else { return }
        let edge: TileResizeEdges
        let delta: CGPoint
        switch direction {
        case .left:
            edge = .left
            delta = CGPoint(x: -tileSize.width, y: 0)
        case .right:
            edge = .right
            delta = CGPoint(x: tileSize.width, y: 0)
        case .up:
            edge = .top
            delta = CGPoint(x: 0, y: tileSize.height)
        case .down:
            edge = .bottom
            delta = CGPoint(x: 0, y: -tileSize.height)
        }
        resizeTile(focusedTileID, edges: edge, delta: delta, ended: true)
        if let expandedRect = model.rect(for: focusedTileID), expandedRect != originalRect {
            recentKeyboardExpansion = KeyboardExpansion(
                tileID: focusedTileID,
                direction: direction,
                originalRect: originalRect,
                expandedRect: expandedRect,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        }
        focus(tileID: focusedTileID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
    }

    func closeFocusedTile() {
        guard let focusedTileID = model.focusedTileID else { return }
        removeTile(focusedTileID, killPersistentSession: true)
    }

    func centerOnFocusedTile() {
        guard let focusedTileID = model.focusedTileID else {
            centerOnGridPoint(.origin)
            return
        }
        centerOn(tileID: focusedTileID)
    }

    func zoomIn() {
        setZoomScale(zoomScale + 0.12)
    }

    func zoomOut() {
        setZoomScale(zoomScale - 0.12)
    }

    func adjustZoom(magnificationDelta: CGFloat) {
        setZoomScale(zoomScale + magnificationDelta)
    }

    private func removeTile(_ tileID: UUID, killPersistentSession: Bool = false) {
        guard let tile = tiles.removeValue(forKey: tileID) else { return }
        let removedPoint = model.remove(tileID: tileID)
        if killPersistentSession, let terminal = tile as? TerminalTile, terminal.usesPersistentSession {
            _ = TmuxSessionManager.shared.killSession(for: terminal.id)
        }
        tile.destroy()
        tile.containerView.removeFromSuperview()

        if let fallbackID = removedPoint.flatMap({ model.nearestTile(to: $0) }) {
            focus(tileID: fallbackID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
        } else {
            model.focus(tileID: nil)
        }
        scheduleWorkspaceSave()
    }

    private func installTileCallbacks(_ tile: CanvasTile) {
        tile.onFocusRequested = { [weak self] tileID in
            self?.focus(tileID: tileID, makeFirstResponder: true, viewportBehavior: self?.currentFocusViewportBehavior() ?? .center)
        }
        tile.onCloseRequested = { [weak self] tileID in
            self?.removeTile(tileID)
        }
        tile.onResizeRequested = { [weak self] tileID, edges, delta, ended in
            self?.resizeTile(tileID, edges: edges, delta: delta, ended: ended)
        }
        if let terminal = tile as? TerminalTile {
            terminal.onForkConversationRequested = { [weak self] tileID in
                self?.forkConversation(from: tileID)
            }
        }
        if let browser = tile as? BrowserTile {
            browser.onStateChanged = { [weak self] in
                self?.scheduleWorkspaceSave()
            }
        }
    }

    private func presentConversationForkFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Cannot Fork Conversation"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? "Codeboard could not fork the focused conversation."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func addTile(_ tile: CanvasTile, focusAfterAdding: Bool = true) {
        tiles[tile.id] = tile
        model.register(tileID: tile.id, at: tile.position, size: tile.span)
        documentView.addSubview(tile.containerView)
        layout(tile: tile)
        tile.containerView.layoutSubtreeIfNeeded()
        if focusAfterAdding {
            focus(tileID: tile.id, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
        }
        scheduleWorkspaceSave()
    }

    private func duplicateSpawnPoint(
        near anchorID: UUID,
        span: GridSize,
        preferredDirection: NavigationDirection?
    ) -> GridPoint? {
        guard let anchorRect = model.rect(for: anchorID) else { return nil }
        let directions = preferredDirection.map { [$0] } ?? [.right, .down, .left, .up]
        let probeID = UUID()

        for direction in directions {
            for offset in 0...256 {
                let candidate = adjacentPoint(to: anchorRect, span: span, direction: direction, offset: offset)
                if model.canPlace(tileID: probeID, at: candidate, size: span) {
                    return candidate
                }
            }
        }

        let center = anchorRect.origin
        for radius in 1...256 {
            for y in (center.y - radius)...(center.y + radius) {
                for x in (center.x - radius)...(center.x + radius) {
                    guard x == center.x - radius || x == center.x + radius || y == center.y - radius || y == center.y + radius else {
                        continue
                    }
                    let candidate = GridPoint(x: x, y: y)
                    if model.canPlace(tileID: probeID, at: candidate, size: span) {
                        return candidate
                    }
                }
            }
        }

        return nil
    }

    private func adjacentPoint(
        to rect: GridRect,
        span: GridSize,
        direction: NavigationDirection,
        offset: Int
    ) -> GridPoint {
        switch direction {
        case .left:
            return GridPoint(x: rect.minX - span.width - offset, y: rect.minY)
        case .right:
            return GridPoint(x: rect.maxX + offset, y: rect.minY)
        case .up:
            return GridPoint(x: rect.minX, y: rect.minY - span.height - offset)
        case .down:
            return GridPoint(x: rect.minX, y: rect.maxY + offset)
        }
    }

    private func focus(tileID: UUID, makeFirstResponder: Bool, viewportBehavior: FocusViewportBehavior) {
        guard tiles[tileID] != nil else { return }
        if isApplyingFocus, model.focusedTileID == tileID {
            return
        }
        if model.focusedTileID == tileID {
            applyViewportBehavior(viewportBehavior, to: tileID)
            return
        }

        isApplyingFocus = true
        defer { isApplyingFocus = false }

        recentKeyboardExpansion = nil
        model.focus(tileID: tileID)
        for (id, tile) in tiles {
            tile.setFocused(id == tileID)
        }
        if makeFirstResponder {
            tiles[tileID]?.activate()
        }
        applyViewportBehavior(viewportBehavior, to: tileID)
        scheduleWorkspaceSave()
    }

    private func clearFocusedTile() {
        recentKeyboardExpansion = nil
        model.focus(tileID: nil)
        for tile in tiles.values {
            tile.setFocused(false)
        }
        view.window?.makeFirstResponder(nil)
        scheduleWorkspaceSave()
    }

    private func defaultInitialWorkingDirectory() -> String {
        let homePath = ProcessInfo.processInfo.environment["HOME"]
        if let homePath, !homePath.isEmpty {
            return homePath
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func preparePersistentSession(tileID: UUID) -> Bool {
        let manager = TmuxSessionManager.shared
        guard manager.prepareSession(for: tileID) else {
            if !didPresentTmuxFailure {
                didPresentTmuxFailure = true
                let alert = NSAlert()
                alert.messageText = "Persistent terminals are unavailable"
                alert.informativeText = manager.startupError
                    ?? "Codeboard could not start its private tmux session. This terminal will run directly and will not survive an app reload."
                alert.alertStyle = .warning
                alert.runModal()
            }
            return false
        }
        return true
    }

    private func nextTileIndex() -> Int {
        (tiles.values.map(\.index).max() ?? 0) + 1
    }

    private func visibleCenterGridPoint() -> GridPoint {
        let visibleBounds = scrollView.contentView.bounds
        let pointX = Int(round((visibleBounds.midX - canvasInset) / tileSize.width)) - gridHalfSpan
        let pointY = Int(round((visibleBounds.midY - canvasInset) / tileSize.height)) - gridHalfSpan
        return GridPoint(x: pointX, y: pointY)
    }

    private func ensureCapacity(for point: GridPoint) {
        let threshold = gridHalfSpan - 6
        guard abs(point.x) > threshold || abs(point.y) > threshold else { return }

        gridHalfSpan += 64
        updateDocumentMetrics()
        for tile in tiles.values {
            layout(tile: tile)
        }
    }

    private func updateDocumentMetrics() {
        let columns = CGFloat(gridHalfSpan * 2 + 1)
        let rows = CGFloat(gridHalfSpan * 2 + 1)
        documentView.cellSize = tileSize
        documentView.frame = CGRect(
            x: 0,
            y: 0,
            width: canvasInset * 2 + columns * tileSize.width,
            height: canvasInset * 2 + rows * tileSize.height
        )
    }

    private func layout(tile: CanvasTile) {
        tile.containerView.setCanvasFrame(frame(for: tile.position, span: tile.span))
    }

    private func frame(for point: GridPoint) -> CGRect {
        frame(for: point, span: .one)
    }

    private func frame(for rect: GridRect) -> CGRect {
        frame(for: rect.origin, span: rect.size)
    }

    private func frame(for point: GridPoint, span: GridSize) -> CGRect {
        CGRect(
            x: canvasInset + CGFloat(point.x + gridHalfSpan) * tileSize.width,
            y: canvasInset + CGFloat(point.y + gridHalfSpan) * tileSize.height,
            width: tileSize.width * CGFloat(span.width) - tileGap,
            height: tileSize.height * CGFloat(span.height) - tileGap
        )
    }

    private func centerOn(tileID: UUID) {
        guard let rect = model.rect(for: tileID) else { return }
        centerOnFrame(frame(for: rect))
    }

    private func centerOnGridPoint(_ point: GridPoint) {
        let frame = frame(for: point)
        centerOnFrame(frame)
    }

    private func centerOnFrame(_ frame: CGRect) {
        let visibleRect = scrollView.contentView.bounds.size
        let maxX = max(0, documentView.bounds.width - visibleRect.width)
        let maxY = max(0, documentView.bounds.height - visibleRect.height)
        let origin = CGPoint(
            x: min(max(0, frame.midX - visibleRect.width / 2), maxX),
            y: min(max(0, frame.midY - visibleRect.height / 2), maxY)
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func setZoomScale(_ candidate: CGFloat) {
        let clamped = min(max(candidate, minZoomScale), maxZoomScale)
        guard abs(clamped - zoomScale) > 0.001 else { return }

        let previousTileSize = tileSize
        let visibleBounds = scrollView.contentView.bounds
        let unitCenter = CGPoint(
            x: previousTileSize.width > 0 ? (visibleBounds.midX - canvasInset) / previousTileSize.width : 0,
            y: previousTileSize.height > 0 ? (visibleBounds.midY - canvasInset) / previousTileSize.height : 0
        )

        zoomScale = clamped
        updateDocumentMetrics()
        for tile in tiles.values {
            layout(tile: tile)
        }

        let targetCenter = CGPoint(
            x: canvasInset + unitCenter.x * tileSize.width,
            y: canvasInset + unitCenter.y * tileSize.height
        )
        centerViewport(onDocumentPoint: targetCenter)
        scheduleWorkspaceSave()
    }

    private func centerViewport(onDocumentPoint point: CGPoint) {
        let visibleRect = scrollView.contentView.bounds.size
        let maxX = max(0, documentView.bounds.width - visibleRect.width)
        let maxY = max(0, documentView.bounds.height - visibleRect.height)
        let origin = CGPoint(
            x: min(max(0, point.x - visibleRect.width / 2), maxX),
            y: min(max(0, point.y - visibleRect.height / 2), maxY)
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func needsQuitConfirmation() -> Bool {
        tiles.values.contains { tile in
            guard let terminal = tile as? TerminalTile else { return false }
            return !terminal.usesPersistentSession && terminal.needsConfirmClose()
        }
    }

    private func spawnBrowserTile(
        preferredDirection: NavigationDirection?,
        anchorID: UUID?,
        initialURL: URL?
    ) {
        let point: GridPoint
        if let anchorID {
            point = model.nextSpawnPoint(near: anchorID, preferredDirection: preferredDirection)
        } else {
            point = model.nextSpawnPoint(around: visibleCenterGridPoint(), preferredDirection: preferredDirection)
        }
        ensureCapacity(for: point)

        let tile = BrowserTile(
            index: nextTileIndex(),
            position: point,
            initialURL: initialURL
        )
        installTileCallbacks(tile)
        addTile(tile)
    }

    private func focusedBrowserTile() -> BrowserTile? {
        guard let focusedTileID = model.focusedTileID else { return nil }
        return tiles[focusedTileID] as? BrowserTile
    }

    private func resizeTile(_ tileID: UUID, edges: TileResizeEdges, delta: CGPoint, ended: Bool) {
        guard let tile = tiles[tileID], !edges.isEmpty else { return }
        recentKeyboardExpansion = nil
        let session: TileResizeSession
        if let existingSession = activeResizeSessions[tileID] {
            session = existingSession
        } else {
            session = TileResizeSession(origin: tile.position, span: tile.span, frame: tile.containerView.frame)
            activeResizeSessions[tileID] = session
        }

        if !ended {
            if tile is TerminalTile {
                tile.containerView.setContentResizeDeferred(true)
            }
            tile.containerView.setCanvasFrame(previewResizeFrame(for: session, edges: edges, delta: delta))
            tile.containerView.layoutSubtreeIfNeeded()
            return
        }

        if let candidate = snappedResize(for: tileID, session: session, edges: edges, delta: delta) {
            ensureCapacity(for: candidate.origin)
            ensureCapacity(for: GridPoint(
                x: candidate.origin.x + candidate.span.width - 1,
                y: candidate.origin.y + candidate.span.height - 1
            ))
            if model.update(tileID: tileID, to: candidate.origin, size: candidate.span) {
                tile.position = candidate.origin
                tile.span = candidate.span
                layout(tile: tile)
                tile.containerView.layoutSubtreeIfNeeded()
                scheduleWorkspaceSave()
            }
        } else {
            layout(tile: tile)
            tile.containerView.layoutSubtreeIfNeeded()
        }

        if tile is TerminalTile {
            tile.containerView.setContentResizeDeferred(false)
        }

        activeResizeSessions.removeValue(forKey: tileID)
    }

    private func previewResizeFrame(for session: TileResizeSession, edges: TileResizeEdges, delta: CGPoint) -> CGRect {
        let canvasDeltaY = -delta.y
        let minimumWidth = max(80, tileSize.width - tileGap)
        let minimumHeight = max(80, tileSize.height - tileGap)
        var frame = session.frame

        if edges.contains(.left) {
            let proposedX = min(session.frame.maxX - minimumWidth, session.frame.minX + delta.x)
            frame.origin.x = proposedX
            frame.size.width = session.frame.maxX - proposedX
        } else if edges.contains(.right) {
            frame.size.width = max(minimumWidth, session.frame.width + delta.x)
        }

        if edges.contains(.top) {
            let proposedY = min(session.frame.maxY - minimumHeight, session.frame.minY + canvasDeltaY)
            frame.origin.y = proposedY
            frame.size.height = session.frame.maxY - proposedY
        } else if edges.contains(.bottom) {
            frame.size.height = max(minimumHeight, session.frame.height + canvasDeltaY)
        }

        return frame
    }

    private func snappedResize(
        for tileID: UUID,
        session: TileResizeSession,
        edges: TileResizeEdges,
        delta: CGPoint
    ) -> (origin: GridPoint, span: GridSize)? {
        let startLeft = session.origin.x
        let startTop = session.origin.y
        let startRight = startLeft + session.span.width
        let startBottom = startTop + session.span.height

        let horizontalDelta = Double(delta.x / tileSize.width)
        // AppKit window coordinates are y-up, while the canvas grid is y-down.
        let verticalDelta = Double(-delta.y / tileSize.height)

        var left = startLeft
        var right = startRight
        var top = startTop
        var bottom = startBottom

        if edges.contains(.left) {
            left = Int((Double(startLeft) + horizontalDelta).rounded())
            left = min(left, startRight - 1)
        } else if edges.contains(.right) {
            right = Int((Double(startRight) + horizontalDelta).rounded())
            right = max(right, startLeft + 1)
        }

        if edges.contains(.top) {
            top = Int((Double(startTop) + verticalDelta).rounded())
            top = min(top, startBottom - 1)
        } else if edges.contains(.bottom) {
            bottom = Int((Double(startBottom) + verticalDelta).rounded())
            bottom = max(bottom, startTop + 1)
        }

        let origin = GridPoint(x: left, y: top)
        let span = GridSize(width: right - left, height: bottom - top)
        guard model.canPlace(tileID: tileID, at: origin, size: span) else { return nil }
        return (origin, span)
    }

    private func currentFocusViewportBehavior() -> FocusViewportBehavior {
        .revealIfNeeded
    }

    private func applyViewportBehavior(_ behavior: FocusViewportBehavior, to tileID: UUID) {
        switch behavior {
        case .center:
            centerOn(tileID: tileID)
        case .revealIfNeeded:
            revealFullyIfNeeded(tileID: tileID)
        }
    }

    private func revealFullyIfNeeded(tileID: UUID) {
        guard let rect = model.rect(for: tileID) else { return }
        revealFullyIfNeeded(frame(for: rect))
    }

    private func revealFullyIfNeeded(_ frame: CGRect) {
        let visibleRect = scrollView.contentView.bounds
        if visibleRect.contains(frame) {
            return
        }

        let maxX = max(0, documentView.bounds.width - visibleRect.width)
        let maxY = max(0, documentView.bounds.height - visibleRect.height)

        var origin = visibleRect.origin

        if frame.minX < visibleRect.minX {
            origin.x = frame.minX
        } else if frame.maxX > visibleRect.maxX {
            origin.x += frame.maxX - visibleRect.maxX
        }

        if frame.minY < visibleRect.minY {
            origin.y = frame.minY
        } else if frame.maxY > visibleRect.maxY {
            origin.y += frame.maxY - visibleRect.maxY
        }

        if frame.width > visibleRect.width {
            origin.x = frame.minX
        }
        if frame.height > visibleRect.height {
            origin.y = frame.minY
        }

        let clampedOrigin = CGPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        )
        scrollView.contentView.scroll(to: clampedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func clampedScrollOrigin(_ point: CGPoint) -> CGPoint {
        let visibleSize = scrollView.contentView.bounds.size
        return CGPoint(
            x: min(max(0, point.x), max(0, documentView.bounds.width - visibleSize.width)),
            y: min(max(0, point.y), max(0, documentView.bounds.height - visibleSize.height))
        )
    }

}

// MARK: - Agent control

enum CanvasControlError: LocalizedError {
    case unknownTile(String)
    case ambiguousTile(String)
    case occupied(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .unknownTile(let token):
            return "No tile matches \"\(token)\"."
        case .ambiguousTile(let token):
            return "More than one tile matches \"\(token)\"; use a longer id."
        case .occupied(let detail):
            return detail
        case .invalidArgument(let detail):
            return detail
        }
    }
}

extension CanvasViewController {
    /// Grid coordinates an agent may address; keeps the document size sane.
    static let controlCoordinateLimit = 512

    func controlResolveTileID(_ token: String) throws -> UUID {
        let normalized = token.trimmingCharacters(in: .whitespaces).lowercased()
        if let id = UUID(uuidString: normalized), tiles[id] != nil {
            return id
        }
        if let index = Int(normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized),
           let tile = tiles.values.first(where: { $0.index == index }) {
            return tile.id
        }
        guard normalized.count >= 4 else { throw CanvasControlError.unknownTile(token) }
        let matches = tiles.keys.filter { $0.uuidString.lowercased().hasPrefix(normalized) }
        guard !matches.isEmpty else { throw CanvasControlError.unknownTile(token) }
        guard matches.count == 1 else { throw CanvasControlError.ambiguousTile(token) }
        return matches[0]
    }

    func controlRect(for tileID: UUID) -> GridRect? {
        model.rect(for: tileID)
    }

    func controlSnapshot() -> [String: Any] {
        let persistentIDs = Set(tiles.values.compactMap { tile -> UUID? in
            guard let terminal = tile as? TerminalTile, terminal.usesPersistentSession else { return nil }
            return terminal.id
        })
        let panes = TmuxSessionManager.shared.paneSummaries(for: persistentIDs)
        let tileStates: [[String: Any]] = tiles.values.sorted(by: { $0.index < $1.index }).map { tile in
            var state: [String: Any] = [
                "id": tile.id.uuidString.lowercased(),
                "index": tile.index,
                "x": tile.position.x,
                "y": tile.position.y,
                "width": tile.span.width,
                "height": tile.span.height,
                "focused": model.focusedTileID == tile.id,
                "title": tile.displayTitle,
            ]
            if let terminal = tile as? TerminalTile {
                state["kind"] = "terminal"
                state["persistent"] = terminal.usesPersistentSession
                state["cwd"] = panes[terminal.id]?.path ?? terminal.launchOptions.workingDirectory ?? NSNull()
                state["command"] = panes[terminal.id]?.command ?? NSNull()
                let sessionFile = AppPaths.claudeSessionURL(for: terminal.id)
                if let sessionID = try? String(contentsOf: sessionFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
                    state["claudeSessionID"] = sessionID
                }
            } else if let browser = tile as? BrowserTile {
                state["kind"] = "browser"
                state["url"] = browser.currentURL?.absoluteString ?? NSNull()
            }
            return state
        }

        let visible = scrollView.contentView.bounds
        let viewport: [String: Any] = [
            "x": Double((visible.minX - canvasInset) / tileSize.width) - Double(gridHalfSpan),
            "y": Double((visible.minY - canvasInset) / tileSize.height) - Double(gridHalfSpan),
            "width": Double(visible.width / tileSize.width),
            "height": Double(visible.height / tileSize.height),
            "pointWidth": Double(visible.width),
            "pointHeight": Double(visible.height),
        ]
        return [
            "tiles": tileStates,
            "focusedTileID": model.focusedTileID.map { $0.uuidString.lowercased() } ?? NSNull(),
            "zoom": Double(zoomScale),
            "minZoom": Double(minZoomScale),
            "maxZoom": Double(maxZoomScale),
            "tilePointSizeAtZoom1": ["width": Double(baseTileSize.width), "height": Double(baseTileSize.height)],
            "viewport": viewport,
        ]
    }

    func controlNewTerminal(
        origin: GridPoint?,
        span: GridSize,
        workingDirectory: String?,
        command: String?,
        focus: Bool
    ) throws -> UUID {
        let point = try controlPlacementPoint(requested: origin, span: span)
        let directory = try controlWorkingDirectory(workingDirectory)
        controlEnsureCapacity(for: GridRect(origin: point, size: span))

        var launchOptions = TerminalLaunchOptions()
        launchOptions.workingDirectory = directory
        launchOptions.context = tiles.isEmpty ? GHOSTTY_SURFACE_CONTEXT_WINDOW : GHOSTTY_SURFACE_CONTEXT_SPLIT

        let tileID = UUID()
        let usesPersistentSession = preparePersistentSession(tileID: tileID)
        launchOptions.command = usesPersistentSession
            ? TmuxSessionManager.shared.launchCommand(for: tileID, workingDirectory: directory)
            : nil
        let shellBootstrap = usesPersistentSession
            ? (TmuxSessionManager.shared.consumeShellBootstrapInput(for: tileID) ?? "")
            : ""
        if let command, !command.isEmpty {
            launchOptions.initialInput = shellBootstrap + command + "\n"
        } else {
            launchOptions.initialInput = shellBootstrap.isEmpty ? nil : shellBootstrap
        }

        let tile = TerminalTile(
            id: tileID,
            index: nextTileIndex(),
            position: point,
            span: span,
            launchOptions: launchOptions,
            usesPersistentSession: usesPersistentSession
        )
        installTileCallbacks(tile)
        addTile(tile, focusAfterAdding: focus)
        return tileID
    }

    func controlNewBrowser(origin: GridPoint?, span: GridSize, url: URL?, focus: Bool) throws -> UUID {
        let point = try controlPlacementPoint(requested: origin, span: span)
        controlEnsureCapacity(for: GridRect(origin: point, size: span))
        let tile = BrowserTile(index: nextTileIndex(), position: point, span: span, initialURL: url)
        installTileCallbacks(tile)
        addTile(tile, focusAfterAdding: focus)
        return tile.id
    }

    func controlPlace(_ placements: [UUID: GridRect]) throws {
        for (tileID, rect) in placements {
            guard tiles[tileID] != nil else { throw CanvasControlError.unknownTile(tileID.uuidString) }
            try controlValidate(rect)
        }
        guard activeResizeSessions.isEmpty else {
            throw CanvasControlError.occupied("A tile is being resized by hand; try again in a moment.")
        }
        for rect in placements.values {
            controlEnsureCapacity(for: rect)
        }
        guard model.updateAll(placements) else {
            throw CanvasControlError.occupied("Those rects overlap each other or a tile that is not being moved.")
        }
        recentKeyboardExpansion = nil
        for (tileID, rect) in placements {
            guard let tile = tiles[tileID] else { continue }
            tile.position = rect.origin
            tile.span = rect.size
            layout(tile: tile)
            tile.containerView.layoutSubtreeIfNeeded()
        }
        scheduleWorkspaceSave()
    }

    func controlFocus(tileID: UUID, center: Bool) {
        focus(tileID: tileID, makeFirstResponder: true, viewportBehavior: center ? .center : .revealIfNeeded)
    }

    func controlClose(tileID: UUID) {
        removeTile(tileID, killPersistentSession: true)
    }

    @discardableResult
    func controlSetZoom(_ scale: Double) -> Double {
        setZoomScale(CGFloat(scale))
        return Double(zoomScale)
    }

    /// Zooms and scrolls so the given tiles (all tiles when empty) fill the window.
    @discardableResult
    func controlFit(tileIDs: [UUID], margin: Double) throws -> Double {
        let ids = tileIDs.isEmpty ? Array(tiles.keys) : tileIDs
        let rects = try ids.map { tileID -> GridRect in
            guard let rect = model.rect(for: tileID) else { throw CanvasControlError.unknownTile(tileID.uuidString) }
            return rect
        }
        guard let first = rects.first else { return Double(zoomScale) }
        var minX = first.minX, minY = first.minY, maxX = first.maxX, maxY = first.maxY
        for rect in rects.dropFirst() {
            minX = min(minX, rect.minX)
            minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        let bounds = GridRect(origin: GridPoint(x: minX, y: minY), size: GridSize(width: maxX - minX, height: maxY - minY))
        let visible = scrollView.contentView.bounds.size
        let inset = CGFloat(max(0, margin))
        let fitScale = min(
            (visible.width - inset * 2) / (CGFloat(bounds.size.width) * baseTileSize.width),
            (visible.height - inset * 2) / (CGFloat(bounds.size.height) * baseTileSize.height)
        )
        setZoomScale(fitScale)
        centerOnFrame(frame(for: bounds))
        scheduleWorkspaceSave()
        return Double(zoomScale)
    }

    private func controlPlacementPoint(requested: GridPoint?, span: GridSize) throws -> GridPoint {
        let probeID = UUID()
        if let requested {
            let rect = GridRect(origin: requested, size: span)
            try controlValidate(rect)
            guard model.canPlace(tileID: probeID, at: requested, size: span) else {
                throw CanvasControlError.occupied("Cells \(requested.x),\(requested.y) \(span.width)x\(span.height) are already occupied.")
            }
            return requested
        }
        try controlValidate(GridRect(origin: .origin, size: span))
        if let focusedTileID = model.focusedTileID,
           let point = duplicateSpawnPoint(near: focusedTileID, span: span, preferredDirection: nil) {
            return point
        }
        let center = visibleCenterGridPoint()
        for radius in 0...64 {
            for y in (center.y - radius)...(center.y + radius) {
                for x in (center.x - radius)...(center.x + radius) {
                    guard radius == 0 || x == center.x - radius || x == center.x + radius
                        || y == center.y - radius || y == center.y + radius else { continue }
                    let candidate = GridPoint(x: x, y: y)
                    if model.canPlace(tileID: probeID, at: candidate, size: span) {
                        return candidate
                    }
                }
            }
        }
        throw CanvasControlError.occupied("No free cells near the viewport for a \(span.width)x\(span.height) tile.")
    }

    private func controlValidate(_ rect: GridRect) throws {
        let limit = Self.controlCoordinateLimit
        guard rect.size.width >= 1, rect.size.height >= 1, rect.size.width <= 16, rect.size.height <= 16 else {
            throw CanvasControlError.invalidArgument("Tile spans must be between 1 and 16 grid units.")
        }
        guard abs(rect.minX) <= limit, abs(rect.minY) <= limit, abs(rect.maxX) <= limit, abs(rect.maxY) <= limit else {
            throw CanvasControlError.invalidArgument("Grid coordinates must stay within ±\(limit).")
        }
    }

    private func controlEnsureCapacity(for rect: GridRect) {
        let farCorner = GridPoint(x: rect.maxX - 1, y: rect.maxY - 1)
        for point in [rect.origin, farCorner] {
            while abs(point.x) > gridHalfSpan - 6 || abs(point.y) > gridHalfSpan - 6 {
                ensureCapacity(for: point)
            }
        }
    }

    private func controlWorkingDirectory(_ requested: String?) throws -> String {
        guard let requested, !requested.isEmpty else { return defaultInitialWorkingDirectory() }
        let expanded = (requested as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CanvasControlError.invalidArgument("Working directory \(requested) does not exist.")
        }
        return expanded
    }
}
