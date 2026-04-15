import AppKit
import Foundation
import GhosttyKit
import QuartzCore

final class GhosttyTerminalView: NSView, NSMenuItemValidation {
    weak var tile: TerminalTile?

    private var trackingArea: NSTrackingArea?
    private var lastDrawableSize = CGSize.zero

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = false
        return layer
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
        updateTrackingAreas()
    }

    func attach(to tile: TerminalTile) {
        self.tile = tile
        createSurfaceIfPossible()
    }

    func detachFromTile() {
        tile = nil
    }

    func applyFocusedState(_ focused: Bool, makeFirstResponder: Bool) {
        guard let surface = tile?.surface else { return }
        ghostty_surface_set_focus(surface, focused)
        if makeFirstResponder, focused, window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = ensureSurface() else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createSurfaceIfPossible()
        syncSurfaceGeometry()
        applyAppearanceColorScheme()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSurfaceGeometry()
    }

    override func layout() {
        super.layout()
        createSurfaceIfPossible()
        syncSurfaceGeometry()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        tile?.requestFocus()
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        tile?.requestFocus()
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        tile?.requestFocus()
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: mouseButton(for: event))
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: mouseButton(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = ensureSurface() else {
            super.scrollWheel(with: event)
            return
        }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }

        var scrollMods: Int32 = 0
        if precise {
            scrollMods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        scrollMods |= momentum << 1

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(scrollMods)
        )
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragOperation(for: sender).contains(.copy)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        tile?.requestFocus()
        window?.makeFirstResponder(self)
        insertDroppedPaths(urls)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = ensureSurface() else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            super.keyDown(with: event)
            return
        }

        var keyEvent = ghosttyKeyEvent(
            for: event,
            surface: surface,
            action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        )
        if let text = textForKeyEvent(event), shouldSendText(text) {
            text.withCString { pointer in
                keyEvent.text = pointer
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = ensureSurface() else {
            super.keyUp(with: event)
            return
        }

        var keyEvent = ghosttyKeyEvent(for: event, surface: surface, action: GHOSTTY_ACTION_RELEASE)
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = ensureSurface() else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghosttyKeyEvent(for: event, surface: surface, action: GHOSTTY_ACTION_PRESS)
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
        sendMousePosition(event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            tile?.requestFocus()
            applyFocusedState(true, makeFirstResponder: false)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            applyFocusedState(false, makeFirstResponder: false)
        }
        return resigned
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColorScheme()
    }

    @IBAction func copy(_ sender: Any?) {
        guard let surface = ensureSurface(), ghostty_surface_has_selection(surface) else { return }
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            guard let surface = ensureSurface() else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }

    private func createSurfaceIfPossible() {
        guard let tile, tile.surface == nil, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        tile.surface = GhosttyRuntime.shared.makeSurface(
            hostView: self,
            options: tile.launchOptions,
            owner: tile,
            template: tile.configTemplate
        )
        tile.configTemplate = nil
        syncSurfaceGeometry()
        applyAppearanceColorScheme()
        if let surface = tile.surface {
            syncSurfaceDisplayID(surface)
            ghostty_surface_set_focus(surface, tile.isFocused)
            ghostty_surface_refresh(surface)
            GhosttyRuntime.shared.tickNow()
            if tile.isFocused {
                window?.makeFirstResponder(self)
            }
        }
    }

    private func ensureSurface() -> ghostty_surface_t? {
        createSurfaceIfPossible()
        return tile?.surface
    }

    private func syncSurfaceGeometry() {
        guard let surface = tile?.surface,
              let window,
              bounds.width > 0,
              bounds.height > 0 else { return }

        let backing = convertToBacking(bounds).size
        guard backing.width > 0, backing.height > 0 else { return }

        let xScale = backing.width / bounds.width
        let yScale = backing.height / bounds.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        ghostty_surface_set_size(surface, UInt32(max(1, Int(backing.width))), UInt32(max(1, Int(backing.height))))
        syncSurfaceDisplayID(surface)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        if let metalLayer = layer as? CAMetalLayer {
            let drawableSize = CGSize(width: floor(backing.width), height: floor(backing.height))
            if lastDrawableSize != drawableSize {
                metalLayer.drawableSize = drawableSize
                lastDrawableSize = drawableSize
            }
        }
        CATransaction.commit()
    }

    private func applyAppearanceColorScheme() {
        guard let surface = tile?.surface else { return }
        let scheme: ghostty_color_scheme_e = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    private func ghosttyKeyEvent(
        for event: NSEvent,
        surface: ghostty_surface_t,
        action: ghostty_input_action_e
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = modsFromEvent(event)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = unshiftedCodepoint(from: event)
        keyEvent.composing = false
        keyEvent.consumed_mods = consumedMods(for: event, surface: surface)
        return keyEvent
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        let flags = event.modifierFlags
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters,
              let scalar = chars.unicodeScalars.first else {
            return 0
        }
        return scalar.value
    }

    private func consumedMods(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_mods_e {
        let translatedMods = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var raw = GHOSTTY_MODS_NONE.rawValue
        if (translatedMods.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0 {
            raw |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if (translatedMods.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0 {
            raw |= GHOSTTY_MODS_ALT.rawValue
        }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        guard chars.count == 1, let scalar = chars.unicodeScalars.first else {
            return chars
        }

        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
            return nil
        }

        if scalar.value < 0x20 || scalar.value == 0x7F {
            if event.modifierFlags.contains(.control) {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            return nil
        }

        return chars
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return true }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }

    private func mouseButton(for event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 0:
            return GHOSTTY_MOUSE_LEFT
        case 1:
            return GHOSTTY_MOUSE_RIGHT
        case 2:
            return GHOSTTY_MOUSE_MIDDLE
        case 3:
            return GHOSTTY_MOUSE_FOUR
        case 4:
            return GHOSTTY_MOUSE_FIVE
        default:
            return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private func syncSurfaceDisplayID(_ surface: ghostty_surface_t) {
        guard let displayID = (window?.screen ?? NSScreen.main)?.ghostCanvasDisplayID,
              displayID != 0 else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface = ensureSurface() else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, modsFromEvent(event))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface = ensureSurface() else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard ensureSurface() != nil else { return [] }
        return droppedFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    private func insertDroppedPaths(_ urls: [URL]) {
        guard let surface = ensureSurface() else { return }
        let text = urls
            .map(\.path)
            .map(shellEscapedPath)
            .joined(separator: " ") + " "
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    private func shellEscapedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "''" }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension NSScreen {
    var ghostCanvasDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let value = deviceDescription[key] as? UInt32 { return value }
        if let value = deviceDescription[key] as? Int { return UInt32(value) }
        if let value = deviceDescription[key] as? NSNumber { return value.uint32Value }
        return nil
    }
}
