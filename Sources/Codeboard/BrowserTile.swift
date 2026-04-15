import AppKit
import Foundation
import WebKit

enum BrowserURLSupport {
    static func normalizedURL(fromInput rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }

        if looksLikeExplicitScheme(trimmed) {
            return URL(string: trimmed)
        }

        if isLocalHostString(trimmed) {
            return URL(string: "http://\(trimmed)")
        }

        return URL(string: "https://\(trimmed)")
    }

    static func isLocalDevelopmentURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
    }

    private static func looksLikeExplicitScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":") else { return false }
        let prefix = value[..<colonIndex]
        guard !prefix.isEmpty else { return false }
        return prefix.allSatisfy { character in
            character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
        }
    }

    private static func isLocalHostString(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("localhost")
            || lowercased.hasPrefix("127.0.0.1")
            || lowercased.hasPrefix("[::1]")
            || lowercased.hasPrefix("::1")
            || lowercased.hasPrefix("0.0.0.0")
    }
}

@MainActor
final class BrowserTile: CanvasTile, WKNavigationDelegate, WKUIDelegate {
    private let defaultTitle: String
    private let browserContentView: BrowserTileContentView
    private let webView: BrowserWebView
    private var observations: [NSKeyValueObservation] = []
    private var shouldFocusURLBarOnNextActivation: Bool

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var canReload: Bool { webView.url != nil || webView.isLoading }
    var canOpenInDefaultBrowser: Bool { currentURL != nil }
    var currentURL: URL? { webView.url }

    init(index: Int, position: GridPoint, span: GridSize = .one, initialURL: URL? = nil) {
        self.webView = BrowserStore.shared.makeWebView()
        self.browserContentView = BrowserTileContentView(webView: webView)
        self.defaultTitle = "Browser \(index)"
        self.shouldFocusURLBarOnNextActivation = initialURL == nil

        super.init(index: index, position: position, span: span, title: defaultTitle, contentView: browserContentView)

        webView.browserTile = self
        webView.navigationDelegate = self
        webView.uiDelegate = self

        browserContentView.onNavigate = { [weak self] value in
            self?.navigate(fromInput: value)
        }
        browserContentView.onBack = { [weak self] in
            self?.goBack()
        }
        browserContentView.onForward = { [weak self] in
            self?.goForward()
        }
        browserContentView.onReload = { [weak self] in
            self?.reload()
        }
        browserContentView.onOpenInDefaultBrowser = { [weak self] in
            self?.openCurrentPageInDefaultBrowser()
        }
        browserContentView.onInteraction = { [weak self] in
            self?.requestFocus()
        }

        installObservers()
        if let initialURL {
            load(url: initialURL)
        } else {
            loadEmptyState()
        }
        refreshChrome()
    }

    override func activate() {
        requestFocus()
        if shouldFocusURLBarOnNextActivation {
            browserContentView.focusURLField()
            shouldFocusURLBarOnNextActivation = false
            return
        }

        containerView.window?.makeFirstResponder(webView)
    }

    override func destroy() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.browserTile = nil
    }

    func load(url: URL) {
        let request = URLRequest(url: url)
        browserContentView.setDisplayedURL(url.absoluteString)
        webView.load(request)
        refreshChrome()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reload() {
        guard canReload else { return }
        webView.reload()
    }

    func openCurrentPageInDefaultBrowser() {
        guard let currentURL else { return }
        NSWorkspace.shared.open(currentURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shouldFocusURLBarOnNextActivation = false
        refreshChrome()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshChrome()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshChrome()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        refreshChrome()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil, let targetURL = navigationAction.request.url {
            load(url: targetURL)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let targetURL = navigationAction.request.url {
            load(url: targetURL)
        }
        return nil
    }

    private func navigate(fromInput input: String) {
        guard let url = BrowserURLSupport.normalizedURL(fromInput: input) else { return }
        shouldFocusURLBarOnNextActivation = false
        load(url: url)
    }

    private func installObservers() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
        ]
    }

    private func refreshChrome() {
        let fallbackTitle = currentURL?.host ?? defaultTitle
        let resolvedTitle = (webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? webView.title!
            : fallbackTitle
        setDisplayTitle(resolvedTitle)
        browserContentView.setDisplayedURL(currentURL?.absoluteString ?? "")
        browserContentView.setNavigationState(
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            canReload: canReload,
            canOpenExternal: currentURL != nil
        )
    }

    private func loadEmptyState() {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              background: #171717;
              color: rgba(255,255,255,0.82);
              font: 15px -apple-system, BlinkMacSystemFont, sans-serif;
            }
          </style>
        </head>
        <body>Enter a URL to open a page.</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

@MainActor
final class BrowserWebView: WKWebView {
    weak var browserTile: BrowserTile?

    override func mouseDown(with event: NSEvent) {
        browserTile?.requestFocus()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            browserTile?.requestFocus()
        }
        return became
    }
}

@MainActor
final class BrowserTileContentView: FlippedView, NSTextFieldDelegate {
    let urlField = NSTextField(frame: .zero)

    var onNavigate: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onOpenInDefaultBrowser: (() -> Void)?
    var onInteraction: (() -> Void)?

    private let toolbarView = NSView(frame: .zero)
    private let backButton = NSButton(title: "<", target: nil, action: nil)
    private let forwardButton = NSButton(title: ">", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let openExternalButton = NSButton(title: "Open", target: nil, action: nil)
    private let webView: BrowserWebView

    private let toolbarHeight: CGFloat = 40
    private let contentInset: CGFloat = 8
    private let compactButtonWidth: CGFloat = 30
    private let actionButtonWidth: CGFloat = 62

    init(webView: BrowserWebView) {
        self.webView = webView
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()

        toolbarView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight)

        let buttonY: CGFloat = 7
        backButton.frame = CGRect(x: contentInset, y: buttonY, width: compactButtonWidth, height: toolbarHeight - 14)
        forwardButton.frame = CGRect(
            x: backButton.frame.maxX + 6,
            y: buttonY,
            width: compactButtonWidth,
            height: toolbarHeight - 14
        )
        reloadButton.frame = CGRect(
            x: forwardButton.frame.maxX + 8,
            y: buttonY,
            width: actionButtonWidth,
            height: toolbarHeight - 14
        )
        openExternalButton.frame = CGRect(
            x: bounds.width - contentInset - actionButtonWidth,
            y: buttonY,
            width: actionButtonWidth,
            height: toolbarHeight - 14
        )

        let urlFieldX = reloadButton.frame.maxX + 8
        let urlFieldWidth = max(140, openExternalButton.frame.minX - 8 - urlFieldX)
        urlField.frame = CGRect(x: urlFieldX, y: 8, width: urlFieldWidth, height: toolbarHeight - 16)

        webView.frame = CGRect(
            x: 0,
            y: toolbarHeight,
            width: bounds.width,
            height: max(0, bounds.height - toolbarHeight)
        )
    }

    func setDisplayedURL(_ value: String) {
        guard urlField.currentEditor() == nil else { return }
        urlField.stringValue = value
    }

    func setNavigationState(
        canGoBack: Bool,
        canGoForward: Bool,
        canReload: Bool,
        canOpenExternal: Bool
    ) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        reloadButton.isEnabled = canReload
        openExternalButton.isEnabled = canOpenExternal
    }

    func focusURLField() {
        guard let window else { return }
        window.makeFirstResponder(urlField)
        urlField.selectText(nil)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        onInteraction?()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        addSubview(toolbarView)

        configureButton(backButton, action: #selector(handleBack(_:)))
        configureButton(forwardButton, action: #selector(handleForward(_:)))
        configureButton(reloadButton, action: #selector(handleReload(_:)))
        configureButton(openExternalButton, action: #selector(handleOpenExternal(_:)))

        urlField.font = .systemFont(ofSize: 13, weight: .regular)
        urlField.isBordered = true
        urlField.bezelStyle = .roundedBezel
        urlField.focusRingType = .default
        urlField.placeholderString = "Enter URL"
        urlField.target = self
        urlField.action = #selector(handleNavigate(_:))
        urlField.delegate = self
        toolbarView.addSubview(urlField)

        addSubview(webView)
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        toolbarView.addSubview(button)
    }

    @objc private func handleNavigate(_ sender: Any?) {
        onInteraction?()
        onNavigate?(urlField.stringValue)
    }

    @objc private func handleBack(_ sender: Any?) {
        onInteraction?()
        onBack?()
    }

    @objc private func handleForward(_ sender: Any?) {
        onInteraction?()
        onForward?()
    }

    @objc private func handleReload(_ sender: Any?) {
        onInteraction?()
        onReload?()
    }

    @objc private func handleOpenExternal(_ sender: Any?) {
        onInteraction?()
        onOpenInDefaultBrowser?()
    }
}
