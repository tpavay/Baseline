import Foundation
import Testing
@testable import Baseline

/// A photo import can run for a minute or more. The screen must stay awake for the whole of that
/// wait - a display that dims and locks mid-import reads as a hang - and it must go back to normal
/// idle behavior the moment the import stops working, on every exit path.
struct WorkoutImportKeepAwakeTests {
    @Test func keepsScreenAwakeWhileImportIsWorking() {
        let working: [WorkoutImportStatus] = [
            .loadingImages(completed: 0, total: 3),
            .recognizing(completed: 1, total: 3),
            .preparingSections,
            .waitingForHandoff,
            .retryingSections(completed: 1, total: 4),
            .processingSections(completed: 2, total: 5),
            .parsing,
        ]
        for status in working {
            #expect(
                WorkoutImportView.shouldKeepScreenAwake(for: status),
                "\(status) is active import work and must hold the display on."
            )
        }
    }

    /// Every terminal or idle state releases the flag. `failed` and `saved` are the exit paths a leak
    /// would hide behind, so they are asserted explicitly alongside the picker and the review editor.
    @Test func releasesScreenWhenImportIsNotWorking() {
        let idle: [WorkoutImportStatus] = [
            .selecting,
            .reviewing,
            .saving,
            .saved(templateID: UUID()),
            .failed(message: "Baseline could not parse that workout right now. Try again."),
        ]
        for status in idle {
            #expect(
                !WorkoutImportView.shouldKeepScreenAwake(for: status),
                "\(status) is not active import work and must restore normal idle behavior."
            )
        }
    }
}

/// The wait has to describe what is actually happening. The server reports queued separately from
/// processing, and where the work runs decides whether leaving the app is safe.
struct WorkoutImportProgressCopyTests {
    @Test func queuedSaysTheImportHasNotStarted() {
        let status = WorkoutImportProgressCopy.processingStatus(isQueued: true, completed: 0, total: 4)
        let detail = WorkoutImportProgressCopy.processingDetail(isQueued: true, completed: 0, total: 4)
        #expect(status == "Waiting for a parser slot")
        #expect(detail.contains("in line"))
        #expect(detail.contains("hasn't started yet"))
    }

    @Test func processingReportsRealSectionProgress() {
        #expect(
            WorkoutImportProgressCopy.processingStatus(isQueued: false, completed: 2, total: 5)
                == "Organizing exercises"
        )
        #expect(
            WorkoutImportProgressCopy.processingDetail(isQueued: false, completed: 2, total: 5)
                .hasPrefix("2 of 5 sections organized.")
        )
    }

    @Test func allSectionsDoneReportsEditorPreparation() {
        #expect(
            WorkoutImportProgressCopy.processingStatus(isQueued: false, completed: 5, total: 5)
                == "Preparing editor"
        )
    }

    /// Server-owned work survives backgrounding and the result is fetched on foreground restoration,
    /// so that copy invites the user to leave. Device-owned work only pauses, so its copy must not.
    @Test func footnotesTellTheTruthAboutLeavingTheApp() {
        #expect(WorkoutImportProgressCopy.serverStageFootnote.contains("You can close this screen"))
        #expect(WorkoutImportProgressCopy.serverStageFootnote.contains("keeps running on Baseline's server"))
        #expect(WorkoutImportProgressCopy.localStageFootnote.contains("pauses if you leave Baseline"))
        #expect(!WorkoutImportProgressCopy.localStageFootnote.contains("You can close this screen"))
    }

    @Test func serverProgressWithoutSectionCountsStillExplainsTheWait() {
        #expect(
            WorkoutImportProgressCopy.processingDetail(isQueued: false, completed: 0, total: 0)
                == WorkoutImportProgressCopy.serverStageFootnote
        )
    }
}

/// `isQueuedOnServer` is what the progress copy keys off, so it has to track the real server state
/// rather than merely "the job reached the server".
@MainActor
struct WorkoutImportQueuedStateTests {
    private func model(serverStatus: String?) -> WorkoutImportViewModel {
        var job = WorkoutImportJob(stage: .processingSections, expectedPageCount: 1)
        job.serverProgress = serverStatus.map {
            WorkoutImportServerProgress(
                serverJobID: "server-1",
                status: $0,
                completedSections: 0,
                totalSections: 4
            )
        }
        return WorkoutImportViewModel(initialJob: job)
    }

    @Test func reportsQueuedOnlyWhileTheServerSaysQueued() {
        #expect(model(serverStatus: WorkoutImportRemoteJobState.queued.rawValue).isQueuedOnServer)
        #expect(!model(serverStatus: WorkoutImportRemoteJobState.processing.rawValue).isQueuedOnServer)
        #expect(!model(serverStatus: WorkoutImportRemoteJobState.completed.rawValue).isQueuedOnServer)
        #expect(!model(serverStatus: nil).isQueuedOnServer)
    }
}
