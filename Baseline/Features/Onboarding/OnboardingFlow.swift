import Foundation

/// One screen of onboarding. The list a given athlete sees is *computed from their draft* —
/// config-first onboarding: enabling an input pulls in that input's setup steps, and the
/// value-first order puts the first score before account creation.
enum OnboardingStep: String, Codable, Hashable, CaseIterable, Sendable {
    // Act 0 — value
    case welcome
    case carousel

    // Act 1 — about you
    case name
    case objective
    case rightPlace
    case attribution

    // Act 2 — your score
    case buildScoreIntro
    case formula
    case heartSource          // only when the heart reading is enabled
    case strapPairing         // only when source == .strap
    case appleHealth

    // Act 3 — first reading → score → account
    case firstReadingIntro
    case firstReading         // strap: live reading · camera: capture front-end pending · subjective-only: skipped
    case checkIn              // only when check-in is enabled
    case scoreReveal
    case auth

    // Act 4 — profile calibration (after account creation)
    case trainingExperience
    case gender
    case age
    case units                // imperial vs metric — seeds body height/weight units below
    case height
    case weight

    case outlook
    case commitment
    case reminder
}

/// Pure flow computation — no UI, no persistence, fully unit-testable.
enum OnboardingFlow {

    /// The full step sequence for a draft. Recomputed whenever the draft changes, so toggling
    /// an input on the formula screen immediately reshapes the remaining flow.
    static func steps(for draft: OnboardingDraft) -> [OnboardingStep] {
        var steps: [OnboardingStep] = [
            .welcome, .carousel,
            .name, .objective, .rightPlace, .attribution,
            .buildScoreIntro, .formula,
        ]

        // Apple Health first (seeds the baseline + can supply sleep/age), then the heart-reading
        // source choice, so the reading-source setup sits right before the first reading.
        steps.append(.appleHealth)

        if draft.config.heartReadingEnabled {
            steps.append(.heartSource)
            if draft.config.heartSource == .strap {
                steps.append(.strapPairing)
            }
        }

        steps.append(.firstReadingIntro)

        // The first reading runs for both strap and camera sources (the same reading engine
        // behind a different capture front-end). Subjective-only users go straight to check-in.
        if draft.config.heartReadingEnabled, draft.config.heartSource != nil {
            steps.append(.firstReading)
        }

        if draft.config.checkInEnabled {
            steps.append(.checkIn)
        }

        // Profile calibration follows account creation (existing-user sign-in skips this tail).
        steps.append(contentsOf: [
            .scoreReveal, .auth,
            .trainingExperience, .gender, .age, .units, .height, .weight,
            .outlook, .commitment, .reminder,
        ])
        return steps
    }

    /// The step after `current` for this draft, or nil when onboarding is finished.
    static func step(after current: OnboardingStep, draft: OnboardingDraft) -> OnboardingStep? {
        let all = steps(for: draft)
        guard let idx = all.firstIndex(of: current) else { return all.first }
        let next = all.index(after: idx)
        return next < all.endIndex ? all[next] : nil
    }

    /// The step before `current` for this draft, or nil at the start.
    static func step(before current: OnboardingStep, draft: OnboardingDraft) -> OnboardingStep? {
        let all = steps(for: draft)
        guard let idx = all.firstIndex(of: current), idx > all.startIndex else { return nil }
        return all[all.index(before: idx)]
    }

    /// Whether the athlete may leave `step` going forward, given what the draft has collected.
    /// Screens use this to disable their CONTINUE until the step's requirement is met.
    static func canAdvance(from step: OnboardingStep, draft: OnboardingDraft) -> Bool {
        switch step {
        case .name: return !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        case .objective: return draft.objective != nil
        case .attribution: return draft.acquisition != nil
        case .formula: return draft.config.isValid
        case .heartSource: return draft.config.heartSource != nil || !draft.config.heartReadingEnabled
        case .trainingExperience: return draft.experience != nil
        case .gender: return draft.biologicalSex != nil
        case .commitment: return draft.committed
        default: return true
        }
    }

    /// Progress through the flow (0...1) for the slim progress affordance.
    static func progress(at step: OnboardingStep, draft: OnboardingDraft) -> Double {
        let all = steps(for: draft)
        guard let idx = all.firstIndex(of: step), all.count > 1 else { return 0 }
        return Double(idx) / Double(all.count - 1)
    }
}
