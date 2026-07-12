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

        // Translucent tint over the behind-window blur; tiles supply their own
        // darker glass so the canvas floor must stay lighter than tile interiors.
        NSColor.black.withAlphaComponent(0.34).setFill()
        dirtyRect.fill()

        guard cellSize.width > 0, cellSize.height > 0 else { return }

        let subdivisions: CGFloat = 8
        let stepX = cellSize.width / subdivisions
        let stepY = cellSize.height / subdivisions
        guard stepX > 4, stepY > 4 else { return }

        let dotColor = NSColor(calibratedWhite: 1, alpha: 0.06)
        let anchorColor = NSColor(calibratedWhite: 1, alpha: 0.14)

        let startColumn = Int(floor(dirtyRect.minX / stepX))
        let endColumn = Int(ceil(dirtyRect.maxX / stepX))
        let startRow = Int(floor(dirtyRect.minY / stepY))
        let endRow = Int(ceil(dirtyRect.maxY / stepY))

        for column in startColumn...endColumn {
            for row in startRow...endRow {
                let isAnchor = column % Int(subdivisions) == 0 && row % Int(subdivisions) == 0
                let radius: CGFloat = isAnchor ? 1.5 : 1
                (isAnchor ? anchorColor : dotColor).setFill()
                let dotRect = NSRect(
                    x: CGFloat(column) * stepX - radius,
                    y: CGFloat(row) * stepY - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
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
