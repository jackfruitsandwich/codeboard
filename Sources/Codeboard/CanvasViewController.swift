import AppKit
import Foundation
import GhosttyKit

private enum FocusViewportMode: Int {
    case centerOnFocus
    case revealFocusedTile

    var controlLabel: String {
        switch self {
        case .centerOnFocus:
            return "Focus Mode: Center"
        case .revealFocusedTile:
            return "Focus Mode: Reveal"
        }
    }
}

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
    static let initialContentSize = NSSize(width: 1480, height: 920)

    private let scrollView = NSScrollView(frame: .zero)
    private let documentView = CanvasDocumentView(frame: .zero)
    private let model = CanvasModel()
    private let focusModeOverlay = NSView(frame: .zero)
    private let focusModeButton = NSButton(title: "", target: nil, action: nil)

    private var tiles: [UUID: CanvasTile] = [:]
    private let baseTileSize = CGSize(width: 920, height: 620)
    private var zoomScale: CGFloat = 1.0
    private let minZoomScale: CGFloat = 0.55
    private let maxZoomScale: CGFloat = 1.8
    private var gridHalfSpan = 64
    private let canvasInset: CGFloat = 60
    private let focusModeOverlayInset = CGPoint(x: 14, y: 14)
    private let focusModeOverlayHeight: CGFloat = 34
    private let focusModeOverlayWidth: CGFloat = 154
    private var focusViewportMode: FocusViewportMode = .centerOnFocus {
        didSet {
            updateFocusModeButtonTitle()
        }
    }

    private var didCenterInitialViewport = false
    private var isApplyingFocus = false
    private var activeResizeSessions: [UUID: TileResizeSession] = [:]

    private var tileSize: CGSize {
        CGSize(width: baseTileSize.width * zoomScale, height: baseTileSize.height * zoomScale)
    }

    private var tileGap: CGFloat {
        max(12, 20 * zoomScale)
    }

    override func loadView() {
        view = FlippedView(frame: NSRect(origin: .zero, size: Self.initialContentSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear

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
        configureFocusModeOverlay()
        view.addSubview(focusModeOverlay, positioned: .above, relativeTo: scrollView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scrollView.frame = view.bounds
        focusModeOverlay.frame = CGRect(
            x: focusModeOverlayInset.x,
            y: focusModeOverlayInset.y,
            width: focusModeOverlayWidth,
            height: focusModeOverlayHeight
        )
        focusModeButton.frame = focusModeOverlay.bounds.insetBy(dx: 4, dy: 4)
        if !didCenterInitialViewport {
            didCenterInitialViewport = true
            centerOnGridPoint(.origin)
        }
    }

    func bootstrapInitialTileIfNeeded() {
        guard tiles.isEmpty else { return }
        spawnTile()
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
        launchOptions.command = nil
        launchOptions.initialInput = nil

        let tile = TerminalTile(
            index: nextTileIndex(),
            position: point,
            launchOptions: launchOptions,
            configTemplate: configTemplate
        )
        tile.onFocusRequested = { [weak self] tileID in
            self?.focus(tileID: tileID, makeFirstResponder: true, viewportBehavior: self?.currentFocusViewportBehavior() ?? .center)
        }
        tile.onCloseRequested = { [weak self] tileID in
            self?.removeTile(tileID)
        }
        tile.onResizeRequested = { [weak self] tileID, edges, delta, ended in
            self?.resizeTile(tileID, edges: edges, delta: delta, ended: ended)
        }

        tiles[tile.id] = tile
        model.register(tileID: tile.id, at: point, size: tile.span)
        documentView.addSubview(tile.containerView)
        layout(tile: tile)
        tile.containerView.layoutSubtreeIfNeeded()
        focus(tileID: tile.id, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
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
        launchOptions.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        let configTemplate = sourceTile.surface
            .map { GhosttySurfaceTemplate(cConfig: ghostty_surface_inherited_config($0, launchOptions.context)) }

        if let inheritedWorkingDirectory = configTemplate?.workingDirectory, !inheritedWorkingDirectory.isEmpty {
            launchOptions.workingDirectory = inheritedWorkingDirectory
        }
        launchOptions.command = nil
        launchOptions.initialInput = nil

        let tile = TerminalTile(
            index: nextTileIndex(),
            position: point,
            span: sourceTile.span,
            launchOptions: launchOptions,
            configTemplate: configTemplate
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
        if model.focusedTileID == nil, let fallbackID = model.nearestTile(to: .origin) {
            focus(tileID: fallbackID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
            return
        }

        guard let nextID = model.nextFocus(from: model.focusedTileID, direction: direction) else { return }
        focus(tileID: nextID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
    }

    func closeFocusedTile() {
        guard let focusedTileID = model.focusedTileID else { return }
        guard confirmCloseIfNeeded(for: focusedTileID) else { return }
        removeTile(focusedTileID)
    }

    func centerOnFocusedTile() {
        guard let focusedTileID = model.focusedTileID else {
            centerOnGridPoint(.origin)
            return
        }
        applyViewportBehavior(currentFocusViewportBehavior(), to: focusedTileID)
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

    private func removeTile(_ tileID: UUID) {
        guard let tile = tiles.removeValue(forKey: tileID) else { return }
        let removedPoint = model.remove(tileID: tileID)
        tile.destroy()
        tile.containerView.removeFromSuperview()

        if let fallbackID = removedPoint.flatMap({ model.nearestTile(to: $0) }) {
            focus(tileID: fallbackID, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
        } else {
            model.focus(tileID: nil)
        }
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
    }

    private func addTile(_ tile: CanvasTile) {
        tiles[tile.id] = tile
        model.register(tileID: tile.id, at: tile.position, size: tile.span)
        documentView.addSubview(tile.containerView)
        layout(tile: tile)
        tile.containerView.layoutSubtreeIfNeeded()
        focus(tileID: tile.id, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
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

        model.focus(tileID: tileID)
        for (id, tile) in tiles {
            tile.setFocused(id == tileID)
        }
        if makeFirstResponder {
            tiles[tileID]?.activate()
        }
        applyViewportBehavior(viewportBehavior, to: tileID)
    }

    private func clearFocusedTile() {
        model.focus(tileID: nil)
        for tile in tiles.values {
            tile.setFocused(false)
        }
        view.window?.makeFirstResponder(nil)
    }

    private func defaultInitialWorkingDirectory() -> String {
        let homePath = ProcessInfo.processInfo.environment["HOME"]
        if let homePath, !homePath.isEmpty {
            return homePath
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
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
        tile.containerView.frame = frame(for: tile.position, span: tile.span)
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
        tiles.values.contains(where: { $0.needsConfirmClose() })
    }

    private func confirmCloseIfNeeded(for tileID: UUID) -> Bool {
        guard let tile = tiles[tileID], tile.needsConfirmClose() else { return true }

        let alert = NSAlert()
        alert.messageText = "Close this terminal?"
        alert.informativeText = "The shell in this tile is still running. Closing it will end that terminal session."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Terminal")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
        tile.onFocusRequested = { [weak self] tileID in
            self?.focus(tileID: tileID, makeFirstResponder: true, viewportBehavior: self?.currentFocusViewportBehavior() ?? .center)
        }
        tile.onCloseRequested = { [weak self] tileID in
            self?.removeTile(tileID)
        }
        tile.onResizeRequested = { [weak self] tileID, edges, delta, ended in
            self?.resizeTile(tileID, edges: edges, delta: delta, ended: ended)
        }

        tiles[tile.id] = tile
        model.register(tileID: tile.id, at: point, size: tile.span)
        documentView.addSubview(tile.containerView)
        layout(tile: tile)
        tile.containerView.layoutSubtreeIfNeeded()
        focus(tileID: tile.id, makeFirstResponder: true, viewportBehavior: currentFocusViewportBehavior())
    }

    private func focusedBrowserTile() -> BrowserTile? {
        guard let focusedTileID = model.focusedTileID else { return nil }
        return tiles[focusedTileID] as? BrowserTile
    }

    private func resizeTile(_ tileID: UUID, edges: TileResizeEdges, delta: CGPoint, ended: Bool) {
        guard let tile = tiles[tileID], !edges.isEmpty else { return }
        let session: TileResizeSession
        if let existingSession = activeResizeSessions[tileID] {
            session = existingSession
        } else {
            session = TileResizeSession(origin: tile.position, span: tile.span, frame: tile.containerView.frame)
            activeResizeSessions[tileID] = session
        }

        if !ended {
            tile.containerView.frame = previewResizeFrame(for: session, edges: edges, delta: delta)
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
            }
        } else {
            layout(tile: tile)
            tile.containerView.layoutSubtreeIfNeeded()
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

    private func configureFocusModeOverlay() {
        focusModeOverlay.wantsLayer = true
        focusModeOverlay.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.82).cgColor
        focusModeOverlay.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.24).cgColor
        focusModeOverlay.layer?.borderWidth = 1
        focusModeOverlay.layer?.cornerRadius = 10
        focusModeOverlay.layer?.zPosition = 1_000

        focusModeButton.isBordered = false
        focusModeButton.target = self
        focusModeButton.action = #selector(toggleFocusViewportMode(_:))
        focusModeButton.font = .systemFont(ofSize: 12, weight: .semibold)
        focusModeButton.contentTintColor = NSColor(calibratedWhite: 1, alpha: 0.94)
        updateFocusModeButtonTitle()
        focusModeOverlay.addSubview(focusModeButton)
    }

    private func updateFocusModeButtonTitle() {
        focusModeButton.title = focusViewportMode.controlLabel
    }

    private func currentFocusViewportBehavior() -> FocusViewportBehavior {
        switch focusViewportMode {
        case .centerOnFocus:
            return .center
        case .revealFocusedTile:
            return .revealIfNeeded
        }
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

    @objc private func toggleFocusViewportMode(_ sender: Any?) {
        switch focusViewportMode {
        case .centerOnFocus:
            focusViewportMode = .revealFocusedTile
        case .revealFocusedTile:
            focusViewportMode = .centerOnFocus
        }
    }
}
