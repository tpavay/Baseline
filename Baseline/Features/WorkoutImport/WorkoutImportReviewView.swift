import SwiftUI

enum WorkoutImportEvidenceResolver {
    static func crops(for issue: WorkoutImportIssue, in session: ImportSession) -> [SourceEvidenceCrop] {
        let records = session.evidence.filter { evidence in
            (issue.exerciseID != nil && evidence.exerciseID == issue.exerciseID)
                || (issue.nodeID != nil && evidence.nodeID == issue.nodeID)
        }
        let observationIDs = Set(records.flatMap(\.sourceObservationIDs))
        guard !observationIDs.isEmpty else { return [] }

        let matching = session.observations.filter { observationIDs.contains($0.id) }
        let observationsByImage = Dictionary(grouping: matching, by: \.sourceImageIndex)
        return observationsByImage.keys.sorted().compactMap { sourceImageIndex in
            guard (session.sourceImages.indices.contains(sourceImageIndex)
                    || session.sourcePages.contains(where: { $0.index == sourceImageIndex })),
                  let observations = observationsByImage[sourceImageIndex],
                  let box = boundingBox(observations) else { return nil }
            let padded = box.insetBy(dx: -0.02, dy: -0.015)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard padded.width > 0, padded.height > 0 else { return nil }
            return SourceEvidenceCrop(sourceImageIndex: sourceImageIndex, normalizedBounds: padded)
        }
    }

    private static func boundingBox(_ observations: [WorkoutTextObservation]) -> CGRect? {
        observations.map(\.boundingBox).reduce(nil as CGRect?) { partial, rect in
            let cg = CGRect(x: rect.x, y: 1 - rect.y - rect.height, width: rect.width, height: rect.height)
            return partial?.union(cg) ?? cg
        }
    }
}

struct WorkoutImportReviewView: View {
    private enum ReviewAction: Hashable { case saveFailure }

    @Environment(WorkoutStore.self) private var reviewStore
    @Environment(PlanStore.self) private var plan

    let model: WorkoutImportViewModel
    let sourceCount: Int
    let onClose: () -> Void
    let onViewSources: () -> Void
    let onDiscard: () -> Void

    @State private var duplicatePrompt = false
    @AccessibilityFocusState private var focusedAction: ReviewAction?

    var body: some View {
        WorkoutTemplateEditor {
            EmptyView()
        } bottomContent: {
            reviewFooter
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", action: onClose)
                    .foregroundStyle(BaselineColor.textMid)
                    .disabled(!model.reviewDraftIsPersisted)
                    .accessibilityHint(
                        model.reviewDraftIsPersisted
                            ? "Closes this editor and keeps the draft"
                            : "Available after the latest edits are saved"
                    )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if sourceCount > 0 {
                        Button("View Source Photos", systemImage: "photo.stack", action: onViewSources)
                    }
                    Button("Discard workout", systemImage: "trash", role: .destructive, action: onDiscard)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("More workout actions")
            }
        }
        .onChange(of: reviewStore.current) { _, newValue in
            guard let newValue else { return }
            model.replaceDraftWorkout(newValue)
        }
        .confirmationDialog("A similar template already exists", isPresented: $duplicatePrompt) {
            ForEach(model.duplicateTemplates) { template in
                Button("Update \(template.name)") { _ = model.updateTemplate(template.id, in: plan) }
            }
            Button("Save as a new template") { _ = model.saveNewTemplate(in: plan) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Update an existing template or keep both. Already-scheduled workouts will not change.")
        }
        .onChange(of: model.saveError) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                await Task.yield()
                focusedAction = .saveFailure
            }
        }
    }

    private var reviewFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let persistenceError = model.reviewPersistenceError {
                draftPersistenceFailureBanner(persistenceError)
            }
            if let saveError = model.saveError {
                saveFailureBanner(saveError)
            }
            if !model.session.issues.isEmpty {
                issueSummary
            }
            saveButton
        }
        .padding(.top, 18)
    }

    private var issueSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(issueCountLabel)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BaselineColor.zoneAmber)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(model.session.issues) { issue in
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.message)
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.textMid)
                        .fixedSize(horizontal: false, vertical: true)

                    if issue.code == .unsupportedIntensityTarget,
                       issue.unresolvedIntensity != nil {
                        WorkoutImportIssueRecoveryActions(
                            showsUseWatts: model.canUseWatts(for: issue),
                            onUseWatts: { useWatts(for: issue) },
                            onRemoveTarget: { removeIntensityTarget(for: issue) }
                        )
                    }

                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.zoneAmber.opacity(0.08)))
    }

    private var saveButton: some View {
        Button(saveButtonLabel, action: save)
            .buttonStyle(WorkoutImportPrimaryButtonStyle())
            .disabled(!model.session.canSave)
            .accessibilityHint(
                model.session.canSave
                    ? "Saves this ordinary editable workout template"
                    : "Resolve all required review items first"
            )
    }

    private func saveFailureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Could not save")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.zoneRed)
                Spacer()
                Button {
                    model.clearSaveError()
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Dismiss")
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(BaselineColor.textMid)
            Text("Your workout edits are still here.")
                .font(.footnote)
                .foregroundStyle(BaselineColor.textMid)
            Button("Keep editing") {
                model.clearSaveError()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BaselineColor.accent)
            .frame(minHeight: 44)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.zoneRed.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityFocused($focusedAction, equals: .saveFailure)
    }

    private func draftPersistenceFailureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Draft not saved yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaselineColor.zoneAmber)
            Text(message)
                .font(.footnote)
                .foregroundStyle(BaselineColor.textMid)
            Button("Try saving draft again") {
                model.retryReviewDraftPersistence()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BaselineColor.accent)
            .frame(minHeight: 44)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.zoneAmber.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }

    private var saveButtonLabel: String {
        if model.saveError != nil { return "Try saving again" }
        return model.session.blockingIssues.isEmpty ? "Save Workout Template" : "Resolve Items to Save"
    }

    private var issueCountLabel: String {
        let count = model.session.issues.count
        return "\(count) item\(count == 1 ? "" : "s") to review"
    }

    private func save() {
        if model.saveReviewedDraft(from: reviewStore, in: plan) == .requiresDuplicateChoice {
            duplicatePrompt = true
        }
    }

    private func useWatts(for issue: WorkoutImportIssue) {
        model.useWatts(for: issue, in: reviewStore)
    }

    private func removeIntensityTarget(for issue: WorkoutImportIssue) {
        model.removeIntensityTarget(for: issue, in: reviewStore)
    }

}

struct WorkoutImportSourceGallery: View {
    let model: WorkoutImportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(0..<sourceCount, id: \.self) { index in
                    ScrollView(.vertical) {
                        CachedWorkoutImportPreview(
                            loadData: { await model.sourceImageData(at: index) },
                            normalizedCrop: nil,
                            maximumPixelSize: 1_600,
                            cacheID: "source-gallery-\(model.session.id)-\(index)",
                            accessibilityLabel: "Workout photo \(index + 1) of \(sourceCount)"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(16)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .navigationTitle("Photo \(min(selection + 1, max(sourceCount, 1))) of \(sourceCount)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationBackground(BaselineColor.base)
    }

    private var sourceCount: Int {
        max(model.session.sourceImages.count, model.session.sourcePages.count)
    }
}

private struct WorkoutImportEvidenceSheet: View {
    let issue: WorkoutImportIssue
    let model: WorkoutImportViewModel
    let crops: [SourceEvidenceCrop]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(issue.message)
                            .font(.body)
                            .foregroundStyle(BaselineColor.textMid)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(crops) { crop in
                            if model.session.sourceImages.indices.contains(crop.sourceImageIndex)
                                || model.session.sourcePages.contains(where: { $0.index == crop.sourceImageIndex }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Photo \(crop.sourceImageIndex + 1)")
                                        .font(.headline)
                                        .foregroundStyle(BaselineColor.textHi)
                                    CachedWorkoutImportPreview(
                                        loadData: { await model.sourceImageData(at: crop.sourceImageIndex) },
                                        normalizedCrop: crop.normalizedBounds,
                                        maximumPixelSize: 1_200,
                                        cacheID: "issue-\(model.session.id)-\(issue.id)-\(crop.sourceImageIndex)-\(crop.normalizedBounds)",
                                        accessibilityLabel: "Source for \(issue.message)"
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
