import Foundation

/// All conditional onboarding copy in one place — objective-keyed affirmations, the founder
/// quotes, and the carousel content. Plain, athlete-directed language; never lab jargon,
/// never "chassis" (user-facing vocabulary is "active recovery" / "mobility").
enum OnboardingCopy {

    // MARK: - "You're in the right place." (keyed to the chosen objective)

    /// The bolded goal phrase in "Baseline was made for people like you — ready to …"
    static func goalPhrase(for objective: TrainingObjective) -> String {
        switch objective {
        case .optimizeLoad: "make every hard day count."
        case .preventInjury: "train hard without breaking."
        case .competitive: "peak on purpose."
        case .longevity: "train for decades."
        }
    }

    // MARK: - 30-day outlook (grounded in Vesterinen et al. 2016, Med Sci Sports Exerc:
    // HRV-guided runners improved 3km performance 2.1% vs 1.1% — nearly double — while doing
    // FEWER hard sessions. We state the outcome, not the citation.)

    static func outlookHeadline(for objective: TrainingObjective) -> String {
        switch objective {
        case .optimizeLoad: "TRAIN SMARTER,\nNOT JUST HARDER"
        case .preventInjury: "FEWER SETBACKS,\nMORE CONSISTENCY"
        case .competitive: "PEAK HIGHER,\nON PURPOSE"
        case .longevity: "PROGRESS THAT\nLASTS"
        }
    }

    static func outlookBody(for objective: TrainingObjective) -> String {
        switch objective {
        case .optimizeLoad:
            "Athletes who train by recovery see nearly double the performance gain — from fewer hard days, not more. You do less, and get more back."
        case .preventInjury:
            "Reading recovery first means backing off before strain becomes injury. Fewer hard days, fewer setbacks, steadier progress that compounds."
        case .competitive:
            "The research is clear: guiding training by recovery produces nearly double the performance improvement. Show up peaked, not just tired."
        case .longevity:
            "Sustainable beats aggressive. Training the right dose each day keeps you healthy and improving for years — not sidelined every few months."
        }
    }

    static func founderQuote(for objective: TrainingObjective) -> String {
        switch objective {
        case .optimizeLoad:
            "For years I woke up, checked a recovery score, and still had no idea whether to run hard or take it easy. Every app gave me a number — none told me what to do with it. I built Baseline so your hardest days land when your body can actually cash them in."
        case .preventInjury:
            "I've trained through mornings my body was clearly asking for a break — and paid for it. The apps I used gave me a number, not a warning I could act on. I built Baseline so you back off by choice — not because an injury decides for you."
        case .competitive:
            "I've stood on start lines not knowing whether my training had me peaked or just tired. A score alone never answered that. I built Baseline so you arrive on race day ready — not lucky."
        case .longevity:
            "I'm not training for one season — I plan on doing this for the rest of my life. Every readiness app I tried stopped at the number and ignored the long game. I built Baseline so you can train for decades, not just seasons."
        }
    }

    // MARK: - Value carousel (universal values only — nothing hardware-conditional)

    struct CarouselSlide: Identifiable, Equatable {
        let id: Int
        let headline: String
        let support: String
        /// nil score → the formula-toggles visual (slide 4).
        let score: Int?
        let band: String
        let chipTitle: String
        let chipSubtitle: String
    }

    static let carousel: [CarouselSlide] = [
        CarouselSlide(
            id: 0,
            headline: "Wake up knowing.",
            support: "One glance answers the morning question: push, maintain, or recover. No more guessing what today should be.",
            score: 74, band: "MODERATE",
            chipTitle: "STEADY WORK BUILDS YOU TODAY", chipSubtitle: ""
        ),
        CarouselSlide(
            id: 1,
            headline: "Push when it pays.",
            support: "Green means your body is actually ready to adapt to hard stimulus. Hit the session with full confidence.",
            score: 88, band: "RECOVERED",
            chipTitle: "CLEARED FOR INTENSITY", chipSubtitle: ""
        ),
        CarouselSlide(
            id: 2,
            headline: "Bad days still count.",
            support: "Run down? Now you know it's real. Back off on purpose — active recovery today buys a stronger tomorrow.",
            score: 54, band: "STRAINED",
            chipTitle: "EASY DAY, ON PURPOSE", chipSubtitle: ""
        ),
        CarouselSlide(
            id: 3,
            headline: "Your score. Your rules.",
            support: "Build readiness from what matters to you — your sleep, how you feel, your heart data if you want it. It's your formula.",
            score: nil, band: "",
            chipTitle: "", chipSubtitle: ""
        ),
    ]

    // MARK: - Fixed lines used on more than one screen

    static let tosFootnote = "By continuing you accept the Terms of Service. Baseline provides training guidance, not medical advice."
    static let formulaFootnote = "At least one input is required. Your history keeps whatever each day recorded."
    static let sourceFootnote = "Pick one to start. Your baseline is built from a single source — switching later restarts calibration (~2 weeks)."
}
