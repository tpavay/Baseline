import Foundation
import Observation

/// Onboarding session state: the draft answers, the current step, and completion — all
/// persisted to UserDefaults after every change so a killed app resumes exactly in place.
/// Navigation walks the pure `OnboardingFlow` step computation; back always works because we
/// re-derive the previous step from the (possibly changed) draft rather than a stored stack.
@MainActor
@Observable
final class OnboardingStore {

    private(set) var step: OnboardingStep
    var draft: OnboardingDraft {
        didSet { persistDraft() }
    }
    private(set) var isComplete: Bool

    /// True while the athlete is on the auth step because they tapped "I already have an
    /// account" — a successful sign-in then finishes onboarding instead of continuing it.
    private(set) var isExistingUserSignIn = false

    private let defaults: UserDefaults

    private enum Keys {
        static let draft = "onboarding.draft"
        static let step = "onboarding.step"
        static let complete = "onboarding.complete"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isComplete = defaults.bool(forKey: Keys.complete)
        if let data = defaults.data(forKey: Keys.draft),
           let saved = try? JSONDecoder().decode(OnboardingDraft.self, from: data) {
            draft = saved
        } else {
            draft = OnboardingDraft()
        }
        if let raw = defaults.string(forKey: Keys.step), let saved = OnboardingStep(rawValue: raw) {
            step = saved
        } else {
            step = .welcome
        }
        // If the persisted step fell out of the flow (config changed shape), snap to a valid one.
        let steps = OnboardingFlow.steps(for: draft)
        if !steps.contains(step) { step = steps.first ?? .welcome }
    }

    // MARK: - Navigation

    var canGoBack: Bool { OnboardingFlow.step(before: step, draft: draft) != nil }
    var canAdvance: Bool { OnboardingFlow.canAdvance(from: step, draft: draft) }
    var progress: Double { OnboardingFlow.progress(at: step, draft: draft) }

    func advance() {
        guard canAdvance else { return }
        if let next = OnboardingFlow.step(after: step, draft: draft) {
            go(to: next)
        } else {
            complete()
        }
    }

    func back() {
        guard let previous = OnboardingFlow.step(before: step, draft: draft) else { return }
        if step == .auth { isExistingUserSignIn = false }
        go(to: previous)
    }

    /// "I already have an account" on the welcome screen — jump straight to sign-in.
    func skipToSignIn() {
        isExistingUserSignIn = true
        go(to: .auth)
    }

    /// Called when the auth step succeeds. Existing users skip the rest of onboarding;
    /// new users continue to the outlook → commitment → reminder tail.
    func authSucceeded() {
        if isExistingUserSignIn {
            complete()
        } else {
            advance()
        }
    }

    private func go(to newStep: OnboardingStep) {
        step = newStep
        defaults.set(newStep.rawValue, forKey: Keys.step)
    }

    private func complete() {
        isComplete = true
        defaults.set(true, forKey: Keys.complete)
    }

    private func persistDraft() {
        if let data = try? JSONEncoder().encode(draft) {
            defaults.set(data, forKey: Keys.draft)
        }
    }

    #if DEBUG
    /// Dev helper: wipe onboarding so the flow can be walked again.
    func reset() {
        defaults.removeObject(forKey: Keys.draft)
        defaults.removeObject(forKey: Keys.step)
        defaults.removeObject(forKey: Keys.complete)
        draft = OnboardingDraft()
        step = .welcome
        isComplete = false
        isExistingUserSignIn = false
    }
    #endif
}
