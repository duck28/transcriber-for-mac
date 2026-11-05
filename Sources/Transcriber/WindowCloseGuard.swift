import AppKit
import SwiftUI

/// Lets the app veto closing the window it's attached to, e.g. to ask about unsaved changes.
///
/// SwiftUI owns the window's delegate and offers no hook for this, so the delegate is wrapped:
/// `windowShouldClose(_:)` is answered here and every other delegate message goes to SwiftUI's delegate.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: (NSWindow) -> Bool

    func makeNSView(context: Context) -> GuardView {
        GuardView(shouldClose: shouldClose)
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
        view.install()
    }

    final class GuardView: NSView {
        var shouldClose: (NSWindow) -> Bool
        private let proxy = DelegateProxy()

        init(shouldClose: @escaping (NSWindow) -> Bool) {
            self.shouldClose = shouldClose
            super.init(frame: .zero)
            proxy.shouldClose = { [weak self] window in self?.shouldClose(window) ?? true }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        /// Wraps the current delegate, again if SwiftUI has replaced it since.
        func install() {
            guard let window, window.delegate !== proxy else { return }
            proxy.original = window.delegate
            window.delegate = proxy
        }
    }

    private final class DelegateProxy: NSObject, NSWindowDelegate {
        // Strong, because NSWindow only holds its delegate weakly.
        var original: NSWindowDelegate?
        var shouldClose: ((NSWindow) -> Bool)?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose?(sender) ?? true else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || original?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
        }
    }
}
