import SwiftUI
import Testing
import UIKit

/// Shared harness for app-hosted screen tests: real-window hosting, run-loop settling,
/// accessibility lookup/activation, and screenshot capture into `evidence/`. Screen classes
/// conform and keep only their root-view construction.
@MainActor
protocol HostedScreen: AnyObject {
    var window: UIWindow { get }
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

    func activate(labelled text: String) -> Bool {
        element(labelled: text)?.accessibilityActivate() ?? false
    }

    func settle() async throws {
        let deadline = Date().addingTimeInterval(1)
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
