import AppKit
import Foundation
import GhosttyKit

struct TerminalLaunchOptions {
    var workingDirectory: String?
    var command: String?
    var environment: [String: String] = [:]
    var initialInput: String?
    var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT
}

struct TileResizeEdges: OptionSet {
    let rawValue: Int

    static let left = TileResizeEdges(rawValue: 1 << 0)
    static let right = TileResizeEdges(rawValue: 1 << 1)
    static let top = TileResizeEdges(rawValue: 1 << 2)
    static let bottom = TileResizeEdges(rawValue: 1 << 3)
}

@MainActor
class CanvasTile: NSObject {
    let id = UUID()
    let index: Int
    var position: GridPoint
    var span: GridSize
    let containerView: CanvasTileContainerView

    private(set) var isFocused = false

    var onFocusRequested: ((UUID) -> Void)?
    var onCloseRequested: ((UUID) -> Void)?
    var onResizeRequested: ((UUID, TileResizeEdges, CGPoint, Bool) -> Void)?

    init(index: Int, position: GridPoint, span: GridSize = .one, title: String, contentView: NSView) {
        self.index = index
        self.position = position
        self.span = span
        self.containerView = CanvasTileContainerView(title: title, contentView: contentView)
        super.init()

        containerView.onSelect = { [weak self] in
            self?.requestFocus()
        }
        containerView.onResize = { [weak self] edges, delta, ended in
            guard let self else { return }
            self.onResizeRequested?(self.id, edges, delta, ended)
        }
    }

    func requestFocus() {
        onFocusRequested?(id)
    }

    func activate() {
        requestFocus()
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        containerView.setFocused(focused)
        didUpdateFocus(focused)
    }

    func setDisplayTitle(_ title: String) {
        containerView.setTitle(title)
    }

    func needsConfirmClose() -> Bool {
        false
    }

    func destroy() {}

    func didUpdateFocus(_ focused: Bool) {}
}

@MainActor
final class TerminalTile: CanvasTile {
    var launchOptions: TerminalLaunchOptions
    var configTemplate: GhosttySurfaceTemplate?

    let terminalView: GhosttyTerminalView

    nonisolated(unsafe) var surface: ghostty_surface_t?

    init(
        index: Int,
        position: GridPoint,
        span: GridSize = .one,
        launchOptions: TerminalLaunchOptions,
        configTemplate: GhosttySurfaceTemplate? = nil
    ) {
        self.launchOptions = launchOptions
        self.configTemplate = configTemplate
        self.terminalView = GhosttyTerminalView(frame: .zero)

        super.init(
            index: index,
            position: position,
            span: span,
            title: "Terminal \(index)",
            contentView: terminalView
        )

        terminalView.attach(to: self)
    }

    override func activate() {
        requestFocus()
        terminalView.applyFocusedState(true, makeFirstResponder: true)
    }

    override func didUpdateFocus(_ focused: Bool) {
        terminalView.applyFocusedState(focused, makeFirstResponder: false)
    }

    func runtimeDidClose() {
        onCloseRequested?(id)
    }

    override func needsConfirmClose() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    override func destroy() {
        terminalView.detachFromTile()
        if let surface {
            GhosttyRuntime.shared.destroySurface(surface)
            self.surface = nil
        }
    }
}

@MainActor
final class CanvasTileContainerView: FlippedView {
    private static let unfocusedBorderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
    private static let focusedBorderColor = NSColor.systemBlue.cgColor
    private static let focusedShadowColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
    private static let titleBarBackgroundColor = NSColor(calibratedWhite: 1, alpha: 0.05).cgColor

    private let titleBarView = NSView(frame: .zero)
    private let titleLabel: NSTextField
    private let contentView: NSView
    private let resizeOverlayView = TileResizeOverlayView(frame: .zero)
    private let rootLayer = CALayer()

    var onSelect: (() -> Void)?
    var onResize: ((TileResizeEdges, CGPoint, Bool) -> Void)?

    private let titleBarHeight: CGFloat = 26
    private let contentInset: CGFloat = 8

    init(title: String, contentView: NSView) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.contentView = contentView
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func makeBackingLayer() -> CALayer {
        rootLayer
    }

    override func layout() {
        super.layout()

        titleBarView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: titleBarHeight)
        titleLabel.frame = CGRect(
            x: 10,
            y: 4,
            width: max(0, bounds.width - 20),
            height: titleBarHeight - 8
        )

        contentView.frame = CGRect(
            x: contentInset,
            y: titleBarHeight + contentInset,
            width: max(0, bounds.width - contentInset * 2),
            height: max(0, bounds.height - titleBarHeight - contentInset * 2)
        )
        resizeOverlayView.frame = bounds
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func setFocused(_ focused: Bool) {
        rootLayer.borderColor = focused ? Self.focusedBorderColor : Self.unfocusedBorderColor
        rootLayer.shadowColor = focused ? Self.focusedShadowColor : nil
        rootLayer.shadowRadius = focused ? 12 : 0
        rootLayer.shadowOpacity = focused ? 0.35 : 0
        rootLayer.shadowOffset = .zero
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        super.mouseDown(with: event)
    }

    private func setup() {
        wantsLayer = true
        rootLayer.cornerRadius = 12
        rootLayer.borderWidth = 2
        rootLayer.borderColor = Self.unfocusedBorderColor
        rootLayer.backgroundColor = NSColor.clear.cgColor

        titleBarView.wantsLayer = true
        titleBarView.layer?.backgroundColor = Self.titleBarBackgroundColor
        addSubview(titleBarView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.88)
        addSubview(titleLabel)

        addSubview(contentView)
        resizeOverlayView.onResize = { [weak self] edges, delta, ended in
            self?.onResize?(edges, delta, ended)
        }
        addSubview(resizeOverlayView)
    }
}

@MainActor
private final class TileResizeOverlayView: NSView {
    var onResize: ((TileResizeEdges, CGPoint, Bool) -> Void)?

    private let resizeZone: CGFloat = 12
    private var activeEdges: TileResizeEdges?
    private var dragStartPoint: NSPoint = .zero

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        resizeEdges(at: point).isEmpty ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(at: point)
        guard !edges.isEmpty else {
            super.mouseDown(with: event)
            return
        }

        activeEdges = edges
        dragStartPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeEdges else {
            super.mouseDragged(with: event)
            return
        }

        let point = event.locationInWindow
        onResize?(activeEdges, CGPoint(x: point.x - dragStartPoint.x, y: point.y - dragStartPoint.y), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let activeEdges else {
            super.mouseUp(with: event)
            return
        }

        let point = event.locationInWindow
        onResize?(activeEdges, CGPoint(x: point.x - dragStartPoint.x, y: point.y - dragStartPoint.y), true)
        self.activeEdges = nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let middleWidth = max(0, bounds.width - resizeZone * 2)
        let middleHeight = max(0, bounds.height - resizeZone * 2)

        addCursorRect(NSRect(x: 0, y: 0, width: resizeZone, height: resizeZone), cursor: .crosshair)
        addCursorRect(NSRect(x: bounds.width - resizeZone, y: 0, width: resizeZone, height: resizeZone), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: bounds.height - resizeZone, width: resizeZone, height: resizeZone), cursor: .crosshair)
        addCursorRect(NSRect(x: bounds.width - resizeZone, y: bounds.height - resizeZone, width: resizeZone, height: resizeZone), cursor: .crosshair)

        addCursorRect(NSRect(x: 0, y: resizeZone, width: resizeZone, height: middleHeight), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - resizeZone, y: resizeZone, width: resizeZone, height: middleHeight), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: resizeZone, y: 0, width: middleWidth, height: resizeZone), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: resizeZone, y: bounds.height - resizeZone, width: middleWidth, height: resizeZone), cursor: .resizeUpDown)
    }

    private func resizeEdges(at point: NSPoint) -> TileResizeEdges {
        guard bounds.contains(point) else { return [] }

        var edges: TileResizeEdges = []
        if point.x <= resizeZone {
            edges.insert(.left)
        } else if point.x >= bounds.width - resizeZone {
            edges.insert(.right)
        }

        if point.y <= resizeZone {
            edges.insert(.top)
        } else if point.y >= bounds.height - resizeZone {
            edges.insert(.bottom)
        }

        return edges
    }
}
