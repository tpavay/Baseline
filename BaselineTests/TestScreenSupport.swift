import ObjectiveC
import SwiftUI
import Testing
import UIKit

/// Shared harness for app-hosted screen tests: real-window hosting, run-loop settling,
/// accessibility lookup/activation, and screenshot capture into `evidence/`. Screen classes
/// conform and keep only their root-view construction.
@MainActor
protocol HostedScreen: AnyObject {
    var window: UIWindow { get }

    /// A protocol requirement rather than an extension-only helper so a screen that needs a longer
    /// run-loop budget is honoured by the shared helpers that settle on its behalf.
    func settle(timeout: TimeInterval) async throws
}

extension HostedScreen {
    /// Host `rootView` in a key window attached to the app's scene — an unattached window renders
    /// blank and publishes no accessibility elements.
    static func makeWindow(rootView: some View) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: rootView)
        window.makeKeyAndVisible()
        return window
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func element(labelled text: String) -> NSObject? {
        AccessibilityElementWalker.elements(in: window)
            .first { $0.accessibilityLabel?.contains(text) ?? false }
    }

    func hasLabel(containing text: String) -> Bool {
        element(labelled: text) != nil
    }

    func activate(labelled text: String) -> Bool {
        element(labelled: text)?.accessibilityActivate() ?? false
    }

    /// Every view in the hosted hierarchy — the text-input lookups below need views UIKit publishes no
    /// accessibility element for, which `AccessibilityElementWalker` deliberately skips.
    func views() -> [UIView] {
        func walk(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(walk) }
        return walk(window)
    }

    func textInputs(labelled label: String) -> [UIView & UITextInput] {
        views()
            .compactMap { $0 as? (UIView & UITextInput) }
            .filter { $0.accessibilityLabel?.contains(label) ?? false }
    }

    func inputCount(labelled label: String) -> Int {
        textInputs(labelled: label).count
    }

    func inputText(labelled label: String) -> String? {
        guard let input = textInputs(labelled: label).first,
              let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        else { return nil }
        return input.text(in: range)
    }

    func replaceInput(labelled label: String, with text: String) throws {
        let input = try #require(textInputs(labelled: label).first)
        input.becomeFirstResponder()
        let range = try #require(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        input.replace(range, withText: text)
        input.resignFirstResponder()
        window.layoutIfNeeded()
    }

    func canFocusInput(labelled label: String) -> Bool {
        guard let input = textInputs(labelled: label).first else { return false }
        input.becomeFirstResponder()
        let isFocused = input.isFirstResponder
        input.resignFirstResponder()
        return isFocused
    }

    /// Pin the tallest scroll view to its bottom, then lay out. Content inside a `LazyVStack` below the
    /// fold is never materialized and so never reaches the accessibility tree — a card at the end of a
    /// long screen is invisible to `element(labelled:)` until it has been scrolled into view.
    @discardableResult
    func scrollToBottom() -> Bool {
        var scrollViews: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scrollView = view as? UIScrollView { scrollViews.append(scrollView) }
            view.subviews.forEach(walk)
        }
        walk(window)
        guard let scrollView = scrollViews.max(by: { $0.contentSize.height < $1.contentSize.height }),
              scrollView.contentSize.height > scrollView.bounds.height else { return false }
        let bottom = scrollView.contentSize.height - scrollView.bounds.height
            + scrollView.adjustedContentInset.bottom
        scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        window.layoutIfNeeded()
        return true
    }

    /// The presented alert, if any — SwiftUI's `.alert` is a `UIAlertController` presented over the
    /// hosting controller.
    var presentedAlert: UIAlertController? {
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            if let alert = presented as? UIAlertController { return alert }
            controller = presented
        }
        return nil
    }

    /// Tap an alert button. `accessibilityActivate()` is a no-op on `UIAlertController` action views,
    /// so the button's own handler — the SwiftUI `Button` action, i.e. the product code — is invoked
    /// directly and the alert is dismissed the way the system would.
    ///
    /// Reaching the handler means KVC against a private `UIAlertAction` ivar, and KVC against a key
    /// that no longer exists raises an Objective-C exception Swift cannot catch — the runner would
    /// die rather than report. The key is therefore proven to exist first, so a future OS rename
    /// fails this one expectation cleanly instead of taking the suite down.
    func tapAlertButton(_ title: String) async throws {
        let alert = try #require(presentedAlert, "No alert on screen when tapping \"\(title)\".")
        let action = try #require(alert.actions.first { $0.title == title },
                                  "Alert has no \"\(title)\" button (buttons: \(alert.actions.compactMap(\.title))).")
        try #require(Self.alertActionExposesHandler,
                     "UIAlertAction no longer exposes a `handler` key: this harness needs a new way to invoke an alert button.")
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        if let block = action.value(forKey: "handler") {
            unsafeBitCast(block as AnyObject, to: Handler.self)(action)
        }
        alert.presentingViewController?.dismiss(animated: false)
        try await settle()
    }

    private static var alertActionExposesHandler: Bool {
        UIAlertAction.instancesRespond(to: Selector(("handler")))
            || class_getInstanceVariable(UIAlertAction.self, "_handler") != nil
    }

    func settle(timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            spin(0.05)
            await Task.yield()
        }
        spin(0.1)
    }

    /// Settle until `condition` holds, failing the test if it never does. For content that appears
    /// asynchronously (e.g. the Today home model assembling from live evidence).
    func settleUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            spin(0.05)
            await Task.yield()
        }
        try #require(condition(), "Condition not met within \(timeout)s")
    }

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    func capture(_ name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let url = AccessibilityElementWalker.evidenceDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }
}

/// Accessibility-tree traversal and the evidence directory screenshots are collected into.
@MainActor
enum AccessibilityElementWalker {
    /// Every accessibility element reachable from `root` — real views and virtual elements alike.
    static func elements(in root: UIView) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()

        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { result.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                result.append(object)
                let count = object.accessibilityElementCount()
                guard count != NSNotFound, count > 0 else { return }
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        walk(child)
                    }
                }
            }
        }

        walk(root)
        return result
    }

    static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("evidence")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
