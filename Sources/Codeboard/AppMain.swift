import AppKit

@main
enum CodeboardMain {
    @MainActor
    private static let retainedDelegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = retainedDelegate
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        delegate.startIfNeeded()
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
