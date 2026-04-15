import AppKit
import Foundation
import WebKit

@MainActor
final class BrowserStore {
    static let shared = BrowserStore()

    let websiteDataStore: WKWebsiteDataStore

    private init() {
        websiteDataStore = .default()
    }

    func makeWebView() -> BrowserWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        return webView
    }
}
