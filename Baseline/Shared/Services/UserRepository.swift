import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Firestore persistence for the athlete's profile + readiness configuration, written when
/// onboarding completes (and whenever the config changes later). Field names here must stay in
/// lock-step with the strict hasOnly/hasAll validation in firestore.rules — adding or renaming
/// a field requires a matching rules update, deployed to every environment (see CLAUDE.md).
struct UserRepository {

    private var db: Firestore { Firestore.firestore() }

    /// Create or update users/{uid}. Merge-writes so partial updates never clobber other fields;
    /// stamps createdAt only on first write.
    func saveProfile(uid: String, draft: OnboardingDraft, onboardingCompleted: Bool) async throws {
        let ref = db.collection("users").document(uid)
        let exists = try await ref.getDocument().exists

        var data: [String: Any] = [
            "name": draft.name,
            "objective": draft.objective?.rawValue ?? "",
            "acquisition": draft.acquisition?.rawValue ?? "",
            "experience": draft.experience?.rawValue ?? "",
            "biologicalSex": draft.biologicalSex?.rawValue ?? "",
            "ageYears": draft.ageYears,
            "heightCm": draft.heightCm,
            "weightKg": draft.weightKg,
            "metricHeight": draft.metricHeight,
            "metricWeight": draft.metricWeight,
            "config": [
                "heartReadingEnabled": draft.config.heartReadingEnabled,
                "heartSource": draft.config.heartSource?.rawValue ?? "",
                "sleepEnabled": draft.config.sleepEnabled,
                "checkInEnabled": draft.config.checkInEnabled,
                "checkInComponents": draft.config.checkInComponents.map(\.rawValue).sorted(),
            ],
            "reminderHour": draft.reminderHour,
            "reminderMinute": draft.reminderMinute,
            "reminderWeekdays": draft.reminderWeekdays.sorted(),
            "reminderScheduled": draft.reminderScheduled,
            "onboardingCompleted": onboardingCompleted,
            "lastUpdated": FieldValue.serverTimestamp(),
        ]
        if !exists {
            data["createdAt"] = FieldValue.serverTimestamp()
        }
        try await ref.setData(data, merge: true)
    }

    /// Whether this account already finished onboarding on another install — used by the
    /// "I already have an account" path to skip straight into the app.
    func onboardingCompleted(uid: String) async -> Bool {
        let doc = try? await db.collection("users").document(uid).getDocument()
        return doc?.data()?["onboardingCompleted"] as? Bool ?? false
    }
}
