import Foundation

/// The athlete's primary objective, chosen early in onboarding. Drives the "right place"
/// affirmation copy, the commitment mirror, and (later) recommendation tone.
enum TrainingObjective: String, Codable, CaseIterable, Identifiable, Sendable {
    case optimizeLoad
    case preventInjury
    case competitive
    case longevity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimizeLoad: "Optimize Training Load"
        case .preventInjury: "Prevent Injury & Burnout"
        case .competitive: "Competitive Performance"
        case .longevity: "Health & Longevity"
        }
    }


    /// The phrase mirrored into "I will use Baseline to… improve [objective]".
    var commitmentPhrase: String {
        switch self {
        case .optimizeLoad: "my training load"
        case .preventInjury: "durability — without breaking"
        case .competitive: "my race-day performance"
        case .longevity: "my long-term health"
        }
    }
}

/// Attribution answer — pure marketing signal, asked after the affirmation, never before value.
enum AcquisitionSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case friendsFamily
    case tiktok
    case instagram
    case appStore
    case other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .friendsFamily: "Friends or Family"
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .appStore: "App Store"
        case .other: "Other"
        }
    }
}

/// How the morning heart reading is captured. The metric is configured on the formula screen;
/// the source is its own choice (baselines are single-source — switching restarts calibration).
enum HeartSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case strap
    case camera

    var id: String { rawValue }
    var title: String {
        switch self {
        case .strap: "Chest Strap"
        case .camera: "Smartphone Camera"
        }
    }
}

/// The athlete's self-rated training background — calibrates prescription dose and (later) the
/// cold-start expectations before a personal baseline exists.
enum TrainingExperience: String, Codable, CaseIterable, Identifiable, Sendable {
    case recreational, dedicated, competitive, elite

    var id: String { rawValue }
    /// 1…4, shown as "LEVEL 01" … "LEVEL 04".
    var level: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var title: String {
        switch self {
        case .recreational: "Recreational"
        case .dedicated: "Dedicated"
        case .competitive: "Competitive"
        case .elite: "Elite"
        }
    }
    var subtitle: String {
        switch self {
        case .recreational: "Casual health and light movement."
        case .dedicated: "Consistent training for goals."
        case .competitive: "Sport-specific and event prep."
        case .elite: "Professional load and high volume."
        }
    }
    var icon: String {
        switch self {
        case .recreational: "figure.walk"
        case .dedicated: "figure.run"
        case .competitive: "flag.checkered"
        case .elite: "crown.fill"
        }
    }
}

/// Biological sex — used only to calibrate population norms during cold start (age/sex-adjusted
/// HRV and resting-HR expectations), before the athlete's own rolling baseline exists.
enum BiologicalSex: String, Codable, CaseIterable, Identifiable, Sendable {
    case male, female, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .male: "Male"
        case .female: "Female"
        case .other: "Other"
        }
    }
}

/// Individually toggleable items of the daily check-in (McLean wellness set). Sleep quality
/// defaults off because Apple Health covers it; it turns on for users without Health sleep.
enum CheckInComponent: String, Codable, CaseIterable, Identifiable, Sendable {
    case soreness, mood, energy, stress, sleepQuality

    var id: String { rawValue }
    var title: String {
        switch self {
        case .soreness: "Soreness"
        case .mood: "Mood"
        case .energy: "Energy"
        case .stress: "Stress"
        case .sleepQuality: "Sleep Quality"
        }
    }
}

/// The athlete's readiness formula: which inputs count toward the score. Rows are metrics —
/// never hardware; the heart source lives alongside as the metric's sub-configuration.
struct ReadinessConfig: Codable, Equatable, Sendable {
    var heartReadingEnabled = true
    var heartSource: HeartSource?
    var sleepEnabled = true
    var checkInEnabled = true
    var checkInComponents: Set<CheckInComponent> = [.soreness, .mood, .energy, .stress]
    /// The athlete's sleep need/goal in hours (Profile-editable; default 8:00 — plan §2). Feeds the
    /// Sleep Engine's goal-relative duration scoring and deficit. Optional-backed so configs
    /// persisted before this field existed decode unchanged (a missing key stays nil → 8 h default).
    var sleepNeedHours: Double?

    /// Sleep need as a `Duration` for `SleepEngine.analyze(need:)`; 8 h when unset.
    var sleepNeed: Duration { .seconds((sleepNeedHours ?? 8) * 3600) }

    /// At least one input is required for a valid score.
    var isValid: Bool { heartReadingEnabled || sleepEnabled || checkInEnabled }

    /// Check-in rows to render, in a stable display order. Sleep quality only surfaces when it's a
    /// chosen component *and* Apple Health sleep isn't already covering it. Single source of truth
    /// so the questionnaire and the flow (whether a check-in step even shows) agree.
    var visibleCheckInComponents: [CheckInComponent] {
        let order: [CheckInComponent] = [.soreness, .energy, .mood, .stress, .sleepQuality]
        return order.filter { c in
            guard checkInComponents.contains(c) else { return false }
            if c == .sleepQuality { return !sleepEnabled }
            return true
        }
    }
}

/// The daily check-in answers, oriented so 5 = best / most recovered (soreness & stress are
/// asked inverted in the UI copy but stored oriented). 1–5 in 0.5 steps.
struct CheckInAnswers: Codable, Equatable, Sendable {
    var soreness: Double?
    var mood: Double?
    var energy: Double?
    var stress: Double?
    var sleepQuality: Double?
    /// Manual sleep entry, used when Apple Health has no sleep for last night. Either a typed
    /// duration in hours or a thumbs up/down — whichever the athlete gives.
    var sleepHoursManual: Double?
    var sleepThumbsUp: Bool?
    var notes: String = ""

    /// Oriented values for the enabled components, in a stable order.
    func orientedValues(for components: Set<CheckInComponent>) -> [Double] {
        var values: [Double] = []
        if components.contains(.soreness), let soreness { values.append(soreness) }
        if components.contains(.mood), let mood { values.append(mood) }
        if components.contains(.energy), let energy { values.append(energy) }
        if components.contains(.stress), let stress { values.append(stress) }
        if components.contains(.sleepQuality), let sleepQuality { values.append(sleepQuality) }
        return values
    }
}

/// Everything onboarding collects, persisted after every change so a killed app resumes
/// exactly where the athlete left off.
struct OnboardingDraft: Codable, Equatable, Sendable {
    var name: String = ""
    var objective: TrainingObjective?
    var acquisition: AcquisitionSource?
    var config = ReadinessConfig()
    // Profile calibration (collected after auth). Canonical units are metric; the two `metric*`
    // flags only drive which unit the picker displays.
    var experience: TrainingExperience?
    var biologicalSex: BiologicalSex?
    var ageYears: Int = 28
    var heightCm: Double = 180
    var weightKg: Double = 79
    var metricHeight: Bool = false     // false = ft/in
    var metricWeight: Bool = false     // false = lb
    var healthConnectRequested = false
    var checkIn: CheckInAnswers?
    /// RMSSD / lnRMSSD of the completed first reading (nil = no reading taken yet).
    var firstReadingRMSSD: Double?
    var firstReadingLnRMSSD: Double?
    var firstReadingDone = false
    /// Last night's sleep hours pulled from HealthKit at the reveal, if available.
    var sleepHours: Double?
    var sleepEfficiency: Double?
    var provisionalScore: Int?
    var reminderHour: Int = 6
    var reminderMinute: Int = 30
    /// 1 = Sunday … 7 = Saturday (Calendar weekday numbering). Default: every day.
    var reminderWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    var reminderScheduled = false
    var committed = false
}
