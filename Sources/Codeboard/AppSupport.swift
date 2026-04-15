import AppKit
import Foundation

enum AppPaths {
    static let bundleIdentifier = "com.jackdigilov.codeboard"
    static let configFilename = "config.ghostty"

    static var appSupportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var configURL: URL {
        appSupportDirectory.appendingPathComponent(configFilename, isDirectory: false)
    }

    static func ensureConfigFileExists() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: configURL.path) else { return }

        let template = """
        # codeboard Ghostty config
        #
        # Copy settings you want from your main Ghostty config into this file.
        # Examples:
        # theme = TokyoNight
        # font-size = 14
        # font-family = JetBrainsMono Nerd Font
        """

        try? template.write(to: configURL, atomically: true, encoding: .utf8)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class CanvasDocumentView: FlippedView {
    var cellSize: CGSize = .zero {
        didSet { needsDisplay = true }
    }

    var onMagnifyGesture: ((CGFloat) -> Void)?
    var onZoomScroll: ((CGFloat) -> Void)?
    var onBackgroundMouseDown: (() -> Void)?

    private var panStartPoint: NSPoint?
    private var panStartOrigin: CGPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        dirtyRect.fill()

        guard cellSize.width > 0, cellSize.height > 0 else { return }

        NSColor(calibratedWhite: 1, alpha: 0.05).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1

        let startColumn = Int(floor(dirtyRect.minX / cellSize.width))
        let endColumn = Int(ceil(dirtyRect.maxX / cellSize.width))
        for column in startColumn...endColumn {
            let x = CGFloat(column) * cellSize.width
            path.move(to: NSPoint(x: x, y: dirtyRect.minY))
            path.line(to: NSPoint(x: x, y: dirtyRect.maxY))
        }

        let startRow = Int(floor(dirtyRect.minY / cellSize.height))
        let endRow = Int(ceil(dirtyRect.maxY / cellSize.height))
        for row in startRow...endRow {
            let y = CGFloat(row) * cellSize.height
            path.move(to: NSPoint(x: dirtyRect.minX, y: y))
            path.line(to: NSPoint(x: dirtyRect.maxX, y: y))
        }

        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundMouseDown?()
        panStartPoint = event.locationInWindow
        panStartOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panStartPoint,
              let scrollView = enclosingScrollView else {
            super.mouseDragged(with: event)
            return
        }

        let point = event.locationInWindow
        let deltaX = panStartPoint.x - point.x
        let deltaY = panStartPoint.y - point.y
        let maxX = max(0, bounds.width - scrollView.contentView.bounds.width)
        let maxY = max(0, bounds.height - scrollView.contentView.bounds.height)
        let nextOrigin = CGPoint(
            x: min(max(0, panStartOrigin.x + deltaX), maxX),
            y: min(max(0, panStartOrigin.y + deltaY), maxY)
        )
        scrollView.contentView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        panStartPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option) {
            onZoomScroll?(-event.scrollingDeltaY * 0.01)
            return
        }

        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
            return
        }

        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onMagnifyGesture?(event.magnification)
    }
}
