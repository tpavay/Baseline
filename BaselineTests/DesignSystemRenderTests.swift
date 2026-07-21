import SwiftUI
import Testing
import UIKit
@testable import Baseline

@MainActor
struct DesignSystemRenderTests {
    @Test func sleepAndZoneRingsRenderTogetherAtLargeDynamicType() throws {
        let harness = try DesignSystemRenderHarness(
            root: RingFixture()
                .dynamicTypeSize(.accessibility3)
                .preferredColorScheme(.dark)
        )
        defer { harness.tearDown() }

        let image = harness.renderedImage()
        #expect(image.size.width == 393)
        #expect(image.size.height == 852)
        #expect(harness.sampledColorCount(in: image) > 10)

        let labels = harness.accessibilityElements.compactMap(\.accessibilityLabel)
        #expect(labels.contains("Sleep score 82"))
        #expect(labels.contains("Heart-rate zones. Zone 2 has the most time"))

        harness.capture(image, named: "design-system-rings-accessibility3")
    }

    @Test func pickerRowsRemainReadableAndReachableAtLargeDynamicType() throws {
        let harness = try DesignSystemRenderHarness(
            root: PickerFixtureView()
                .dynamicTypeSize(.accessibility3)
                .preferredColorScheme(.dark)
        )
        defer { harness.tearDown() }

        let image = harness.renderedImage()
        #expect(harness.sampledColorCount(in: image) > 8)

        let lats = try #require(
            harness.accessibilityElements.first { $0.accessibilityLabel == "Lats" }
        )
        #expect(lats.accessibilityFrame.height >= BaselineSize.minimumTapTarget)
        #expect((lats.accessibilityValue as? String)?.contains("Unavailable") == true)

        let selected = try #require(
            harness.accessibilityElements.first { $0.accessibilityLabel == "Biceps" }
        )
        #expect(selected.accessibilityTraits.contains(.selected))
        #expect(selected.accessibilityFrame.height >= BaselineSize.minimumTapTarget)

        harness.capture(image, named: "design-system-picker-accessibility3")
    }
}

private struct RingFixture: View {
    var body: some View {
        VStack(spacing: BaselineSpacing.large) {
            Text("Shared ring foundation")
                .baselineTypography(.screenTitle)
                .foregroundStyle(BaselineColor.textHi)

            BaselineCard {
                VStack(spacing: BaselineSpacing.screen) {
                    SegmentedRing(
                        segments: [
                            .init(weight: 0.4, progress: 0.78, color: BaselineColor.zoneBlue),
                            .init(weight: 0.35, progress: 0.62, color: BaselineColor.accent),
                            .init(weight: 0.25, progress: 0.73, color: BaselineColor.zoneGreen)
                        ],
                        diameter: 84,
                        lineWidth: 5,
                        gapDegrees: 8,
                        accessibilitySummary: "Sleep score 82"
                    ) {
                        Text("82")
                            .baselineTypography(.instrumentValue)
                            .foregroundStyle(BaselineColor.textMid)
                    }

                    SegmentedRing(
                        segments: [
                            .init(weight: 34, progress: 1, color: BaselineColor.zoneBlue),
                            .init(weight: 41, progress: 1, color: BaselineColor.zoneGreen),
                            .init(weight: 38, progress: 1, color: BaselineColor.accent),
                            .init(weight: 22, progress: 1, color: BaselineColor.zoneAmber),
                            .init(weight: 8, progress: 1, color: BaselineColor.zoneRed)
                        ],
                        diameter: 118,
                        lineWidth: 11,
                        gapDegrees: 1.2,
                        accessibilitySummary: "Heart-rate zones. Zone 2 has the most time"
                    ) {
                        Text("Z2")
                            .baselineTypography(.instrumentValue)
                            .foregroundStyle(BaselineColor.zoneGreen)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(BaselineSpacing.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BaselineColor.base)
    }
}

private struct PickerFixtureView: View {
    @State private var selection: Set<String> = ["biceps"]

    private let items = [
        PickerRenderItem(id: "chest", title: "Chest", subtitle: "chest", icon: "figure.strengthtraining.traditional"),
        PickerRenderItem(id: "lats", title: "Lats", subtitle: "back", icon: "figure.strengthtraining.functional"),
        PickerRenderItem(id: "biceps", title: "Biceps", subtitle: "arms", icon: "dumbbell"),
        PickerRenderItem(id: "calves", title: "Calves", subtitle: "legs", icon: "figure.run")
    ]

    var body: some View {
        NavigationStack {
            TaxonomyPickerShell(
                title: "Other muscles",
                items: items,
                selection: $selection,
                selectionMode: .multiple,
                itemTitle: \.title,
                itemSubtitle: { $0.subtitle },
                itemIcon: { Image(systemName: $0.icon) },
                disabledReason: { item in
                    item.id == "lats" ? "Already selected as the primary muscle" : nil
                },
                onBack: {},
                onDone: {}
            )
        }
    }
}

private struct PickerRenderItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
}

@MainActor
private final class DesignSystemRenderHarness {
    private let window: UIWindow

    init<Content: View>(root: Content) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "The visual test must run in the app-hosted test bundle."
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
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

    var accessibilityElements: [NSObject] {
        Self.elements(in: window)
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
        let directory = URL.temporaryDirectory.appending(path: "baseline-design-system-renders")
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
