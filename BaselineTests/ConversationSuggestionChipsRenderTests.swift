import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Drives the real Ask Baseline surface the way an athlete does: open it with nothing said yet, tap
/// an opener, tap a second one, then send. Everything goes through `AskBaselineSheet` itself rather
/// than a stand-in, because the claims worth guarding are about the assembled screen (openers sit
/// above the composer, fill it, and retire on send), not about the chip row in isolation.
///
/// Hosted in a window attached to the app's scene: sign-in gates a plain launch, and an unattached
/// window renders blank. Each test also writes a PNG so the screen can be looked at and not only
/// asserted about; the paths are printed for collection.
@MainActor
struct ConversationSuggestionChipsRenderTests {

    @Test func generalScopeOpensWithItsOpenersAboveTheComposer() async throws {
        let screen = try await AskBaselineScreen(mode: .general)
        defer { screen.tearDown() }

        for suggestion in ConversationSuggestion.all(for: .general) {
            #expect(screen.chip(suggestion.label) != nil, "\"\(suggestion.label)\" is missing from the row.")
        }
        // The row's whole job is to sit where the athlete is about to type.
        let firstChip = try #require(screen.chip(ConversationSuggestion.all(for: .general)[0].label))
        #expect(firstChip.accessibilityFrame.maxY <= screen.sendButtonFrame.minY)
        // The capsule draws smaller than it answers to: the touch target clears the 44pt floor even
        // though the chip still reads as a 32pt pill.
        #expect(firstChip.accessibilityFrame.height >= 44)

        screen.capture("01-general-empty-chips")
    }

    @Test func tappingAnOpenerFillsTheComposerAndASecondOneReplacesIt() async throws {
        let screen = try await AskBaselineScreen(mode: .general)
        defer { screen.tearDown() }

        let openers = ConversationSuggestion.all(for: .general)
        let first = openers[0]
        let second = openers[2]

        try screen.tapChip(first.label)
        #expect(screen.composerText == first.prompt)
        #expect(screen.isEmptyConversation, "A chip fills the composer; it must never send.")
        screen.capture("02-general-chip-filled-composer")

        try screen.tapChip(second.label)
        #expect(screen.composerText == second.prompt, "A second chip replaces the first one's text.")
        #expect(screen.isEmptyConversation)
        screen.capture("03-general-second-chip-replaces")
    }

    @Test func theOpenersRetireOnceTheAthleteSends() async throws {
        let screen = try await AskBaselineScreen(mode: .general)
        defer { screen.tearDown() }

        let opener = ConversationSuggestion.all(for: .general)[0]
        try screen.tapChip(opener.label)
        try screen.tapSend()

        #expect(screen.transcriptShows(opener.prompt), "The tapped opener should have been sent as written.")
        #expect(screen.composerText.isEmpty)
        for suggestion in ConversationSuggestion.all(for: .general) {
            #expect(screen.chip(suggestion.label) == nil, "\"\(suggestion.label)\" outlived the first message.")
        }
        screen.capture("04-general-chips-gone-after-send")
    }

    /// A draft the athlete shaped themselves is theirs; the row leaves rather than risk a tap taking
    /// it back.
    @Test func typingOverAnOpenersTextRetiresTheRow() async throws {
        let screen = try await AskBaselineScreen(mode: .general)
        defer { screen.tearDown() }

        let opener = ConversationSuggestion.all(for: .general)[3]   // "Something hurts"
        try screen.tapChip(opener.label)
        #expect(screen.chip(opener.label) != nil, "Untouched chip text is still replaceable.")

        screen.type("My Achilles hurts today")
        #expect(screen.composerText == "My Achilles hurts today")
        #expect(screen.chip(opener.label) == nil)
        screen.capture("05-general-edited-draft-retires-row")
    }

    /// The row shows about three openers at once, so the rest are only real if it scrolls to them.
    @Test func theRowScrollsToReachTheOpenersPastTheFold() async throws {
        let screen = try await AskBaselineScreen(mode: .general)
        defer { screen.tearDown() }

        let last = try #require(ConversationSuggestion.all(for: .general).last)
        let row = try #require(screen.chipRow, "The openers should sit in a horizontal scroll view.")
        #expect(row.contentSize.width > row.bounds.width, "The row has to overflow, or nothing scrolls into reach.")

        let offscreen = try #require(screen.chip(last.label))
        #expect(!screen.isOnScreen(offscreen), "\"\(last.label)\" starts past the fold.")

        screen.scrollChipRowToEnd()
        let reached = try #require(screen.chip(last.label))
        #expect(screen.isOnScreen(reached), "\"\(last.label)\" should have scrolled into reach.")
        screen.capture("08-general-row-scrolled-to-end")
    }

    @Test func importScopeOffersItsOwnDraftFixingOpeners() async throws {
        let screen = try await AskBaselineScreen(mode: .workoutImport)
        defer { screen.tearDown() }

        for suggestion in ConversationSuggestion.all(for: .workoutImport) {
            #expect(screen.chip(suggestion.label) != nil, "\"\(suggestion.label)\" is missing from the import row.")
        }
        for suggestion in ConversationSuggestion.all(for: .general) {
            #expect(screen.chip(suggestion.label) == nil, "General opener \"\(suggestion.label)\" leaked into the import scope.")
        }
        screen.capture("06-import-empty-chips")
    }

    /// The reason the row does not reuse the app's fixed-height chips: at accessibility sizes a frozen
    /// 32pt capsule clips its label. These have to grow instead.
    @Test func openersGrowRatherThanClipAtAccessibilitySizes() async throws {
        let screen = try await AskBaselineScreen(mode: .general, textSize: .accessibility3)
        defer { screen.tearDown() }

        let label = ConversationSuggestion.all(for: .general)[0].label
        let chip = try #require(screen.chip(label))
        #expect(chip.accessibilityFrame.height > 44, "The capsule should have grown with its label, not held 32pt.")
        #expect(chip.accessibilityFrame.maxY <= screen.sendButtonFrame.minY)

        screen.capture("07-general-accessibility3")
    }
}

// MARK: - Harness

/// The assembled Ask Baseline screen in a real, scene-attached window, plus the few pokes a test
/// needs: read the composer, activate a chip, send. Interaction goes through the accessibility layer
/// because that is the only public way to press a SwiftUI button from a unit test, and it presses the
/// same control VoiceOver would.
@MainActor
private final class AskBaselineScreen {
    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName: String
    private let container: ModelContainer

    init(mode: AskBaselineContext, textSize: DynamicTypeSize = .large) async throws {
        suiteName = "ConversationSuggestionChipsRenderTests.\(mode).\(textSize)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = AskBaselineSheet(mode: mode)
            .environment(TrainingContextStore(defaults: defaults))
            .environment(HealthService(defaults: defaults))
            .environment(OnboardingStore(defaults: defaults))
            .environment(WorkoutStore(defaults: defaults))
            .environment(PlanStore(context: container.mainContext))
            .modelContainer(container)
            .dynamicTypeSize(textSize)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()

        // The sheet builds its ConversationService in a `.task`; the composer is the signal it landed.
        try await settle(until: { [weak window] in
            guard let window else { return false }
            return AskBaselineScreen.elements(in: window).contains { $0.accessibilityLabel == "Send message" }
        })
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Reading the screen

    /// The composer's live text, read off the field itself rather than from view state, so the
    /// assertion covers what the athlete can actually see in the box.
    var composerText: String {
        guard let field = textInput,
              let range = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        else { return "" }
        return field.text(in: range) ?? ""
    }

    /// The greeting only exists while the log is empty, so its heading doubles as the "nothing said
    /// yet" signal without reaching into the view's private state.
    var isEmptyConversation: Bool {
        AskBaselineScreen.elements(in: window)
            .contains { $0.accessibilityLabel == "Ask Baseline" || $0.accessibilityLabel == "Fix this workout" }
    }

    func transcriptShows(_ text: String) -> Bool {
        AskBaselineScreen.elements(in: window).contains {
            $0.accessibilityLabel == text && !($0 is UITextInput)
        }
    }

    func chip(_ label: String) -> NSObject? {
        AskBaselineScreen.elements(in: window).first {
            $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
        }
    }

    var sendButtonFrame: CGRect {
        AskBaselineScreen.elements(in: window)
            .first { $0.accessibilityLabel == "Send message" }?
            .accessibilityFrame ?? .zero
    }

    /// The openers' scroll view: the only horizontally overflowing one on the screen (the transcript
    /// above it scrolls vertically).
    var chipRow: UIScrollView? {
        AskBaselineScreen.allViews(in: window)
            .compactMap { $0 as? UIScrollView }
            .first { $0.contentSize.width > $0.bounds.width && $0.bounds.width > 0 }
    }

    func isOnScreen(_ element: NSObject) -> Bool {
        window.bounds.contains(element.accessibilityFrame)
    }

    // MARK: Driving the screen

    func tapChip(_ label: String) throws {
        let element = try #require(chip(label), "No chip labelled \"\(label)\" on screen.")
        #expect(element.accessibilityActivate())
        flush()
    }

    func tapSend() throws {
        let element = try #require(
            AskBaselineScreen.elements(in: window).first { $0.accessibilityLabel == "Send message" }
        )
        #expect(element.accessibilityActivate())
        flush()
    }

    func scrollChipRowToEnd() {
        guard let row = chipRow else { return }
        row.setContentOffset(CGPoint(x: row.contentSize.width - row.bounds.width, y: 0), animated: false)
        flush()
    }

    /// Types into the composer the way the keyboard does, so SwiftUI's binding updates and the row
    /// sees a draft the athlete shaped.
    func type(_ text: String) {
        guard let field = textInput else { return }
        field.becomeFirstResponder()
        if let range = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
            field.replace(range, withText: text)
        }
        flush()
    }

    // MARK: Evidence

    func capture(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            // `drawHierarchy` and not `ImageRenderer`: the latter cannot rasterize the transcript's
            // ScrollView or the composer's TextField, which is most of what these shots are for.
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }
        let url = AskBaselineScreen.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ask-baseline-chips")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: Plumbing

    private var textInput: (UIView & UITextInput)? {
        AskBaselineScreen.allViews(in: window).lazy.compactMap { $0 as? (UIView & UITextInput) }.first
    }

    /// Lets the main run loop turn so SwiftUI applies the state change and lays out again. Kept
    /// synchronous because `RunLoop.run(until:)` is unavailable from an async context, and this is
    /// already pinned to the main actor's thread.
    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    private func flush() { spin(0.4) }

    private func settle(until condition: () -> Bool, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            spin(0.1)
            await Task.yield()
            if condition() { flush(); return }
        }
        Issue.record("Ask Baseline never finished opening.")
    }

    private static func allViews(in root: UIView) -> [UIView] {
        root.subviews.reduce(into: [root]) { $0 += allViews(in: $1) }
    }

    /// Every accessibility element on screen: SwiftUI publishes controls both as views that mark
    /// themselves accessible and as synthesized elements hanging off a container, so both paths are
    /// walked.
    private static func elements(in root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()

        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { out.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                out.append(object)
                let count = object.accessibilityElementCount()
                guard count != NSNotFound, count > 0 else { return }
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { walk(child) }
                }
            }
        }
        walk(root)
        return out
    }
}
