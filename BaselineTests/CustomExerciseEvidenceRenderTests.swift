import SwiftUI
import Testing
import UIKit
@testable import Baseline

@MainActor
struct CustomExerciseEvidenceRenderTests {
    @Test func capturesEveryApprovedCustomExerciseScreenOnIPhone16Pro() throws {
        let store = WorkoutStore(
            units: StubUnitSystem(.imperial),
            defaults: UserDefaults(suiteName: "custom-evidence-\(UUID().uuidString)")!
        )

        for screen in CustomExerciseEvidenceScreen.allCases {
            let harness = try CustomExerciseEvidenceHarness(
                root: CustomExerciseEvidenceRoot(screen: screen)
                    .environment(store)
                    .preferredColorScheme(.dark)
            )
            defer { harness.tearDown() }

            let image = harness.renderedImage()
            #expect(image.size == CGSize(width: 393, height: 852))
            #expect(harness.sampledColorCount(in: image) > 8)
            try harness.capture(image, named: screen.fileName)
        }
    }
}

private enum CustomExerciseEvidenceScreen: String, CaseIterable {
    case custom
    case equipment
    case primaryMuscle
    case otherMuscles
    case metrics
    case movementPattern
    case tags
    case level

    var fileName: String {
        switch self {
        case .custom: "custom-exercise"
        case .equipment: "pick-equipment"
        case .primaryMuscle: "pick-primary-muscle"
        case .otherMuscles: "pick-other-muscles"
        case .metrics: "pick-metrics"
        case .movementPattern: "pick-movement-pattern"
        case .tags: "pick-tags"
        case .level: "pick-level"
        }
    }

    var pickerKind: CustomExercisePickerKind? {
        switch self {
        case .custom: nil
        case .equipment: .equipment
        case .primaryMuscle: .primaryMuscle
        case .otherMuscles: .otherMuscles
        case .metrics: .metrics
        case .movementPattern: .movementPattern
        case .tags: .tags
        case .level: .level
        }
    }
}

private struct CustomExerciseEvidenceRoot: View {
    let screen: CustomExerciseEvidenceScreen
    @State private var draft = CustomExerciseFormDraft(
        name: "Single-Arm Sled Drag",
        equipment: [.sled],
        primaryMuscles: [.lats],
        secondaryMuscles: [.quadriceps, .biceps, .forearms],
        metrics: [.duration, .distance, .pace],
        patterns: [.pull, .gait],
        tags: [.hyrox],
        level: [.intermediate]
    )

    var body: some View {
        NavigationStack {
            if let pickerKind = screen.pickerKind {
                CustomExercisePicker(kind: pickerKind, draft: $draft)
            } else {
                CustomExerciseForm(draft: draft, onCreate: { _ in })
            }
        }
    }
}

@MainActor
private final class CustomExerciseEvidenceHarness {
    private let window: UIWindow

    init<Content: View>(root: Content) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "The evidence test must run in the app-hosted test bundle."
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

    func capture(_ image: UIImage, named name: String) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = repositoryRoot.appending(path: "evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(image.pngData())
        let url = directory.appending(path: "\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }

    private func settle() {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.4))
        window.layoutIfNeeded()
    }
}
