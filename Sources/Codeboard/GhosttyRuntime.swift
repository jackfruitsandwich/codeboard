import AppKit
import Foundation
import GhosttyKit

struct GhosttySurfaceTemplate {
    var fontSize: Float32 = 0
    var workingDirectory: String?
    var command: String?
    var environment: [String: String] = [:]
    var initialInput: String?
    var waitAfterCommand = false

    init() {}

    init(cConfig: ghostty_surface_config_s) {
        fontSize = cConfig.font_size
        waitAfterCommand = cConfig.wait_after_command

        if let workingDirectory = cConfig.working_directory {
            self.workingDirectory = String(cString: workingDirectory)
        }
        if let command = cConfig.command {
            self.command = String(cString: command)
        }
        if let initialInput = cConfig.initial_input {
            self.initialInput = String(cString: initialInput)
        }

        guard cConfig.env_var_count > 0, let envVars = cConfig.env_vars else { return }
        for index in 0..<Int(cConfig.env_var_count) {
            let item = envVars[index]
            environment[String(cString: item.key)] = String(cString: item.value)
        }
    }
}

private func ghostCanvasRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyRuntime.shared.readClipboard(userdata: userdata, location: location, state: state)
}

private func ghostCanvasRuntimeActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    GhosttyRuntime.shared.handleAction(target: target, action: action)
}

final class GhosttyRuntime: @unchecked Sendable {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var appObservers: [NSObjectProtocol] = []

    private let tickLock = NSLock()
    private var tickScheduled = false

    private init() {}

    @MainActor
    func start(configURL: URL) -> Bool {
        guard app == nil else { return true }

        configureEnvironment()

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            print("codeboard: ghostty_init failed with code \(initResult)")
            return false
        }

        guard let primaryConfig = loadConfig(from: configURL) else {
            print("codeboard: failed to create Ghostty config")
            return false
        }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = { _ in
            GhosttyRuntime.shared.scheduleTick()
        }
        runtime.action_cb = ghostCanvasRuntimeActionCallback
        runtime.read_clipboard_cb = ghostCanvasRuntimeReadClipboardCallback
        runtime.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let tile = GhosttyRuntime.tile(from: userdata),
                  let surface = tile.surface,
                  let content else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }
        runtime.write_clipboard_cb = { _, location, content, len, _ in
            GhosttyRuntime.shared.writeClipboard(location: location, content: content, len: len)
        }
        runtime.close_surface_cb = { userdata, _ in
            GhosttyRuntime.shared.closeSurface(userdata: userdata)
        }

        if let createdApp = ghostty_app_new(&runtime, primaryConfig) {
            app = createdApp
            config = primaryConfig
        } else {
            ghostty_config_free(primaryConfig)
            guard let fallbackConfig = ghostty_config_new() else { return false }
            ghostty_config_finalize(fallbackConfig)
            guard let createdApp = ghostty_app_new(&runtime, fallbackConfig) else {
                ghostty_config_free(fallbackConfig)
                return false
            }
            app = createdApp
            config = fallbackConfig
        }

        installApplicationObservers()
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        return true
    }

    @MainActor
    func reloadConfig(from configURL: URL) {
        guard let app else { return }
        guard let newConfig = loadConfig(from: configURL) else { return }
        ghostty_app_update_config(app, newConfig)
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
    }

    @MainActor
    func shutdown() {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appObservers.removeAll()

        if let app {
            ghostty_app_free(app)
            self.app = nil
        }

        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
    }

    @MainActor
    func makeSurface(
        hostView: NSView,
        options: TerminalLaunchOptions,
        owner: TerminalTile,
        template: GhosttySurfaceTemplate?
    ) -> ghostty_surface_t? {
        guard let app else { return nil }

        var surfaceConfig = ghostty_surface_config_new()
        if let template {
            surfaceConfig.font_size = template.fontSize
            surfaceConfig.wait_after_command = template.waitAfterCommand
        }
        surfaceConfig.userdata = Unmanaged.passUnretained(owner).toOpaque()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(hostView).toOpaque()
            )
        )
        surfaceConfig.scale_factor = Double(hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        surfaceConfig.context = options.context

        let mergedEnvironment = mergedEnvironment(template: template, overrides: options.environment)

        var envVars: [ghostty_env_var_s] = []
        var envStorage: [UnsafeMutablePointer<CChar>] = []
        for (key, value) in mergedEnvironment.sorted(by: { $0.key < $1.key }) {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            envStorage.append(keyPtr)
            envStorage.append(valuePtr)
            envVars.append(ghostty_env_var_s(key: UnsafePointer(keyPtr), value: UnsafePointer(valuePtr)))
        }

        defer {
            envStorage.forEach { free($0) }
        }

        let resolvedCommand = nonEmpty(options.command) ?? template?.command
        let resolvedWorkingDirectory = nonEmpty(options.workingDirectory) ?? template?.workingDirectory
        let resolvedInitialInput = nonEmpty(options.initialInput) ?? template?.initialInput

        let createSurface = {
            if envVars.isEmpty {
                return ghostty_surface_new(app, &surfaceConfig)
            }

            let envVarCount = envVars.count
            return envVars.withUnsafeMutableBufferPointer { buffer -> ghostty_surface_t? in
                surfaceConfig.env_vars = buffer.baseAddress
                surfaceConfig.env_var_count = envVarCount
                return ghostty_surface_new(app, &surfaceConfig)
            }
        }

        return withOptionalCString(resolvedCommand) { commandPtr in
            surfaceConfig.command = commandPtr
            return withOptionalCString(resolvedWorkingDirectory) { workingDirectoryPtr in
                surfaceConfig.working_directory = workingDirectoryPtr
                return withOptionalCString(resolvedInitialInput) { inputPtr in
                    surfaceConfig.initial_input = inputPtr
                    return createSurface()
                }
            }
        }
    }

    @MainActor
    func tickNow() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func destroySurface(_ surface: ghostty_surface_t) {
        ghostty_surface_free(surface)
    }

    private func loadConfig(from url: URL) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            ghostty_config_load_recursive_files(config)
        }
        ghostty_config_finalize(config)
        logDiagnostics(for: config)
        return config
    }

    private func scheduleTick() {
        tickLock.lock()
        if tickScheduled {
            tickLock.unlock()
            return
        }
        tickScheduled = true
        tickLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickLock.lock()
            self.tickScheduled = false
            self.tickLock.unlock()
            if let app = self.app {
                ghostty_app_tick(app)
            }
        }
    }

    fileprivate func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let tile = Self.tile(from: userdata),
              let surface = tile.surface else { return false }

        let pasteboard: NSPasteboard
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION:
            pasteboard = NSPasteboard(name: NSPasteboard.Name("codeboard.selection"))
        default:
            pasteboard = .general
        }

        let contents = pasteboard.string(forType: .string) ?? ""
        contents.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
        return true
    }

    private func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        guard let content, len > 0 else { return }

        let pasteboard: NSPasteboard
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION:
            pasteboard = NSPasteboard(name: NSPasteboard.Name("codeboard.selection"))
        default:
            pasteboard = .general
        }

        let buffer = UnsafeBufferPointer(start: content, count: len)
        let plainText = buffer.compactMap { item -> String? in
            guard let data = item.data else { return nil }
            if let mime = item.mime, String(cString: mime).hasPrefix("text/plain") {
                return String(cString: data)
            }
            return nil
        }.first ?? buffer.first.flatMap { item in
            item.data.map { String(cString: $0) }
        }

        guard let plainText else { return }
        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
    }

    private func closeSurface(userdata: UnsafeMutableRawPointer?) {
        guard let tile = Self.tile(from: userdata) else { return }
        DispatchQueue.main.async {
            tile.runtimeDidClose()
        }
    }

    private func configureEnvironment() {
        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            let installedGhosttyResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
            if FileManager.default.fileExists(atPath: installedGhosttyResources) {
                setenv("GHOSTTY_RESOURCES_DIR", installedGhosttyResources, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-ghostty", 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }
    }

    private func installApplicationObservers() {
        let center = NotificationCenter.default

        appObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
    }

    private func logDiagnostics(for config: ghostty_config_t) {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else { return }
        for index in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(config, UInt32(index))
            let message = diagnostic.message.map { String(cString: $0) } ?? "unknown Ghostty config error"
            print("codeboard config: \(message)")
        }
    }

    private static func tile(from userdata: UnsafeMutableRawPointer?) -> TerminalTile? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalTile>.fromOpaque(userdata).takeUnretainedValue()
    }

    fileprivate func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            return handleOpenURL(target: target, action: action.action.open_url)
        default:
            return false
        }
    }

    private func handleOpenURL(target: ghostty_target_s, action: ghostty_action_open_url_s) -> Bool {
        guard let urlPointer = action.url else { return false }
        let rawData = Data(bytes: urlPointer, count: Int(action.len))
        guard let rawValue = String(data: rawData, encoding: .utf8), !rawValue.isEmpty else {
            return false
        }

        let resolvedURL: URL
        if let candidate = URL(string: rawValue), candidate.scheme != nil {
            resolvedURL = candidate
        } else {
            let expandedPath = NSString(string: rawValue).standardizingPath
            resolvedURL = URL(fileURLWithPath: expandedPath)
        }

        let sourceTileUserdata: UnsafeMutableRawPointer?
        if target.tag == GHOSTTY_TARGET_SURFACE {
            sourceTileUserdata = ghostty_surface_userdata(target.target.surface)
        } else {
            sourceTileUserdata = nil
        }

        DispatchQueue.main.async {
            let sourceTileID = Self.tile(from: sourceTileUserdata)?.id
            if let appDelegate = AppDelegate.shared {
                appDelegate.openURLFromTerminal(resolvedURL, sourceTileID: sourceTileID)
            } else {
                NSWorkspace.shared.open(resolvedURL)
            }
        }

        return true
    }

    private func mergedEnvironment(
        template: GhosttySurfaceTemplate?,
        overrides: [String: String]
    ) -> [String: String] {
        var result = template?.environment ?? [:]
        for (key, value) in overrides {
            result[key] = value
        }
        return result
    }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let value else {
        return body(nil)
    }
    return value.withCString(body)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}
