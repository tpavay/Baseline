import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// App-hosted renders of the redesigned live-HR HUD: the streaming state (gauge + nested BPM + zone
/// name + stats + time-in-zone, and **no** connection line) and the degraded states (an explicit
/// status line, no fabricated number). Screenshots are written for design review.
@MainActor
struct LiveHeartRateHUDRenderTests {

    @Test func streamingHUDShowsGaugeStatsAndZoneBreakdownWithoutAStatusLine() throws {
        let harness = try LiveHeartRateRenderHarness(provider: PreviewLiveHeartRateProvider.streaming(bpm: 152))
        defer { harness.tearDown() }

        let image = harness.renderedImage()
        #expect(harness.sampledColorCount(in: image) > 8)

        let spoken = harness.accessibilitySpokenText
        // The hero readout, the gauge summary, the stats, and the time-in-zone breakdown.
        #expect(spoken.contains { $0.contains("152 beats per minute") })
        #expect(spoken.contains { $0.contains("Current zone Z3 Aerobic") })
        #expect(spoken.contains { $0.contains("24:18") })
        #expect(spoken.contains { $0.contains("Z3 52 percent") })
        // While streaming normally there is no connection/status line at all.
        for status in ["No signal", "Connecting", "Reconnecting", "Strap disconnected", "Streaming"] {
            #expect(!spoken.contains { $0.contains(status) }, "unexpected status line: \(status)")
        }

        harness.capture(image, named: "live-hr-hud-streaming")
    }

    @Test func noSignalHUDKeepsAggregatesBlanksTheNumberAndShowsTheStatus() throws {
        let harness = try LiveHeartRateRenderHarness(provider: PreviewLiveHeartRateProvider.noSignal())
        defer { harness.tearDown() }

        let image = harness.renderedImage()
        let spoken = harness.accessibilitySpokenText
        // The honest degraded treatment: an explicit reason, no live number, aggregates persist.
        #expect(spoken.contains { $0.contains("No signal") })
        #expect(!spoken.contains { $0.contains("beats per minute") })
        #expect(spoken.contains { $0.contains("19:30") })

        harness.capture(image, named: "live-hr-hud-no-signal")
    }

    @Test func disconnectedHUDBeforeAnySessionShowsOnlyTheGaugeFrameAndStatus() throws {
        let harness = try LiveHeartRateRenderHarness(provider: PreviewLiveHeartRateProvider.disconnected())
        defer { harness.tearDown() }

        let image = harness.renderedImage()
        let spoken = harness.accessibilitySpokenText
        #expect(spoken.contains { $0.contains("Strap disconnected") })
        // No session yet → no stats row and no time-in-zone breakdown.
        #expect(!spoken.contains { $0.contains("percent") })
        #expect(!spoken.contains { $0.contains("beats per minute") })

        harness.capture(image, named: "live-hr-hud-disconnected")
    }

    /// The freeze fix, rendered end-to-end. A live monitor shows a real reading (the stuck "133"),
    /// then the strap goes silent while the GATT link stays `.connected`. With no new sample and no
    /// disconnect event, the old pull-model HUD stayed frozen on 133 forever; the watchdog tick now
    /// repaints it to the honest "No signal — check the strap" degraded state. Captures both frames.
    @Test func watchdogRepaintsAFrozenReadingToNoSignalInTheHUD() throws {
        let clock = RenderClock()
        let source = RenderLiveSource()
        source.connectionStatus = .connected
        let monitor = HeartRateMonitor(source: source, zoneModel: .preview, now: clock.now)
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }
        source.emit(bpm: 133)

        // Before: the HUD paints the real live number — this is the value that used to freeze.
        let liveHarness = try LiveHeartRateRenderHarness(provider: monitor)
        let liveImage = liveHarness.renderedImage()
        #expect(liveHarness.accessibilitySpokenText.contains { $0.contains("133 beats per minute") })
        liveHarness.capture(liveImage, named: "live-hr-hud-watchdog-before-frozen-133")
        liveHarness.tearDown()

        // Strap stops sending; link stays connected. The watchdog tick pushes the downgrade.
        clock.advance(by: HeartRateMonitor.freshnessWindow + 1)
        monitor.checkLiveness()

        let degradedHarness = try LiveHeartRateRenderHarness(provider: monitor)
        defer { degradedHarness.tearDown() }
        let degradedImage = degradedHarness.renderedImage()
        let spoken = degradedHarness.accessibilitySpokenText
        #expect(spoken.contains { $0.contains("No signal") })          // honest degraded state
        #expect(!spoken.contains { $0.contains("beats per minute") })  // the frozen number is gone
        degradedHarness.capture(degradedImage, named: "live-hr-hud-watchdog-after-no-signal")
    }
}

// MARK: - Watchdog render fixtures

/// A hand-advanced clock so the render test drives the monitor's freshness deterministically.
@MainActor
private final class RenderClock {
    private(set) var current = Date(timeIntervalSince1970: 1_000_000)
    func advance(by seconds: TimeInterval) { current += seconds }
    var now: @MainActor () -> Date { { [self] in current } }
}

/// A controllable live source that pushes samples through the real `onLiveSample` seam, so the HUD is
/// driven by an actual `HeartRateMonitor` (and its watchdog) rather than a static preview provider.
private final class RenderLiveSource: LiveHeartRateSource {
    var liveSample: HeartRateSample?
    var connectionStatus: BluetoothManager.Status = .connected
    var onLiveSample: ((HeartRateSample) -> Void)?

    func startLiveMonitoring() {}
    func stopLiveMonitoring() {}
    func resubscribeLive() {}
    func reconnectLive() {}

    func emit(bpm: Int, contact: HeartRateSample.SensorContact = .detected) {
        let sample = HeartRateSample(bpm: bpm, sensorContact: contact, receivedAt: .distantPast)
        liveSample = sample
        onLiveSample?(sample)
    }
}

// MARK: - Harness

/// Hosts the HUD in a real key window (an unattached window renders blank) and rasterizes it via
/// `drawHierarchy`, mirroring the design-system render harness.
@MainActor
private final class LiveHeartRateRenderHarness {
    private let window: UIWindow

    init(provider: any LiveHeartRateProviding) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "The visual test must run in the app-hosted test bundle."
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let root = ScrollView {
            LiveHeartRateView(provider: provider, targetZones: nil)
                .padding(20)
        }
        .background(BaselineColor.base)
        .preferredColorScheme(.dark)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        settle()
    }

    func tearDown() {
        window.resignKey()
        window.isHidden = true
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        window.rootViewController = nil
    }

    /// Every accessibility label + value in the hierarchy, flattened for containment checks.
    var accessibilitySpokenText: [String] {
        Self.elements(in: window).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }
    }

    func renderedImage() -> UIImage {
        settle()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func sampledColorCount(in image: UIImage) -> Int {
        guard let source = image.cgImage else { return 0 }
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return 0 }

        var colors = Set<UInt32>()
        for y in stride(from: 0, to: height, by: 12) {
            for x in stride(from: 0, to: width, by: 12) {
                let offset = (y * width + x) * 4
                let value = UInt32(pixels[offset]) << 24
                    | UInt32(pixels[offset + 1]) << 16
                    | UInt32(pixels[offset + 2]) << 8
                    | UInt32(pixels[offset + 3])
                colors.insert(value)
            }
        }
        return colors.count
    }

    func capture(_ image: UIImage, named name: String) {
        guard let data = image.pngData() else { return }
        let directory = URL.temporaryDirectory.appending(path: "baseline-live-hr-renders")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private func settle() {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.3))
        window.layoutIfNeeded()
    }

    private static func elements(in root: UIView) -> [NSObject] {
        var output: [NSObject] = []
        var seen = Set<ObjectIdentifier>()

        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { output.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                output.append(object)
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
        return output
    }
}
