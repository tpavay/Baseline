import Foundation
import SwiftData
import Testing
@testable import Baseline

@MainActor
struct PlanDragReorderTests {
    private let calendar = Calendar.planWeek

    @Test("Drop after an existing session persists final within-day order")
    func reorderWithinDayAfterExistingSession() throws {
        let bed = try TestBed()
        let day = bed.today
        let first = bed.seed("First", on: day)
        _ = bed.seed("Second", on: day)
        _ = bed.seed("Third", on: day)

        let result = bed.repository.reposition(
            first.id,
            toDate: day,
            at: .index(2),
            notBefore: day,
            scope: .allTraining,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(bed.titles(on: day) == ["Second", "Third", "First"])
    }

    @Test("Drop before an existing session persists final within-day order")
    func reorderWithinDayBeforeExistingSession() throws {
        let bed = try TestBed()
        let day = bed.today
        _ = bed.seed("First", on: day)
        _ = bed.seed("Second", on: day)
        let third = bed.seed("Third", on: day)

        let result = bed.repository.reposition(
            third.id,
            toDate: day,
            at: .index(0),
            notBefore: day,
            scope: .allTraining,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(bed.titles(on: day) == ["Third", "First", "Second"])
    }

    @Test("A planned session moves to an occupied future day as its second session")
    func moveAcrossDaysToOccupiedFutureDay() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 2, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        _ = bed.seed("Already there", on: future)

        let result = bed.repository.reposition(
            moved.id,
            toDate: future,
            at: .index(1),
            notBefore: bed.today,
            scope: .allTraining,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(bed.titles(on: bed.today).isEmpty)
        #expect(bed.titles(on: future) == ["Already there", "Move me"])

        #expect(bed.repository.undo(actor: .user).isApplied)
        #expect(bed.titles(on: bed.today) == ["Move me"])
        #expect(bed.titles(on: future) == ["Already there"])
    }

    @Test("An in-progress session can move without changing its performed-session record")
    func moveInProgressSessionPreservesPerformedSeparation() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("In progress", on: bed.today)
        let session = try #require(bed.repository.startSession(forScheduled: moved.id, now: bed.today))

        let result = bed.repository.reposition(
            moved.id,
            toDate: future,
            at: .index(0),
            notBefore: bed.today,
            scope: .allTraining,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(calendar.isDate(bed.repository.scheduledWorkout(moved.id)?.date ?? .distantPast,
                                inSameDayAs: future))
        let persistedSession = try #require(bed.repository.session(forScheduled: moved.id))
        #expect(persistedSession.id == session.id)
        #expect(persistedSession.status == .active)
        #expect(bed.repository.completedLog(forScheduled: moved.id) == nil)
    }

    @Test("A past day rejects a drop without appending a version")
    func pastDayRejectsDrop() throws {
        let bed = try TestBed()
        let past = try #require(calendar.date(byAdding: .day, value: -1, to: bed.today))
        let moved = bed.seed("Stay today", on: bed.today)
        let versionsBefore = bed.repository.versions(limit: 100).count

        let result = bed.repository.reposition(
            moved.id,
            toDate: past,
            at: .index(0),
            notBefore: bed.today,
            scope: .allTraining,
            actor: .user,
            reason: nil
        )

        #expect(result == .rejected(.invalidTarget))
        #expect(bed.titles(on: bed.today) == ["Stay today"])
        #expect(bed.titles(on: past).isEmpty)
        #expect(bed.repository.versions(limit: 100).count == versionsBefore)
    }

    @Test("A completed day rejects a drop and its frozen log stays unchanged")
    func completedDayRejectsDrop() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("Stay today", on: bed.today)
        let completed = bed.seed("Performed", on: future)
        _ = try #require(bed.repository.startSession(forScheduled: completed.id, now: bed.today))
        guard case .completed(let frozen) = bed.repository.completeSession(
            forScheduled: completed.id,
            acknowledgingOpenWork: true,
            now: bed.today
        ) else {
            Issue.record("Expected a frozen completed log")
            return
        }

        let result = bed.repository.reposition(
            moved.id,
            toDate: future,
            at: .index(1),
            notBefore: bed.today,
            scope: .allTraining,
            actor: .user,
            reason: nil
        )

        #expect(result == .rejected(.invalidTarget))
        #expect(bed.titles(on: bed.today) == ["Stay today"])
        #expect(bed.titles(on: future) == ["Performed"])
        #expect(bed.repository.completedLog(forScheduled: completed.id) == frozen)
    }

    @Test("A session cannot be dragged out of a completed day")
    func completedSourceDayRejectsDrop() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let completed = bed.seed("Performed", on: bed.today)
        let plannedSibling = bed.seed("Do not move", on: bed.today)
        _ = try #require(bed.repository.startSession(forScheduled: completed.id, now: bed.today))
        guard case .completed(let frozen) = bed.repository.completeSession(
            forScheduled: completed.id,
            acknowledgingOpenWork: true,
            now: bed.today
        ) else {
            Issue.record("Expected a frozen completed log")
            return
        }

        let result = bed.repository.reposition(
            plannedSibling.id,
            toDate: future,
            at: .index(0),
            notBefore: bed.today,
            scope: .allTraining,
            actor: .user,
            reason: nil
        )

        #expect(result == .rejected(.invalidTarget))
        #expect(bed.titles(on: bed.today) == ["Performed", "Do not move"])
        #expect(bed.titles(on: future).isEmpty)
        #expect(bed.repository.completedLog(forScheduled: completed.id) == frozen)
    }

    /// Adding a second workout to a day is not a reorder of that day. If it renumbers its siblings it
    /// rewrites their intents, and the very next undo collides with any session live on that day.
    @Test("Adding a workout appends to its day without rewriting a sibling's intent")
    func addingAWorkoutLeavesSiblingOrderAlone() throws {
        let bed = try TestBed()
        let day = bed.today
        let live = bed.seed("Live", on: day)
        _ = bed.seed("Second", on: day)
        bed.clearStoredDayOrder(for: live.id)
        let ordersBefore = bed.storedDayOrders(on: day)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: day))

        #expect(bed.repository.addWorkout(bed.workout("Third", on: day), actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: day) == ["Live", "Second", "Third"],
                "A day written before drag ordering keeps its order and the new row lands last")
        #expect(Array(bed.storedDayOrders(on: day).dropLast()) == ordersBefore,
                "The add appended; it did not renumber the day")
        #expect(bed.repository.undo(actor: .user).isApplied,
                "The live session's intent never moved, so undoing the add is not a conflict")
        #expect(bed.titles(on: day) == ["Live", "Second"])
    }

    @Test("A duplicate lands after the session it was copied from")
    func duplicateAppendsToItsDay() throws {
        let bed = try TestBed()
        let day = bed.today
        let source = bed.seed("Source", on: day)
        _ = bed.seed("Second", on: day)

        #expect(bed.repository.duplicate(source.id, toDate: nil, actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: day) == ["Source", "Second", "Source"])
    }

    @Test("A duplicate onto another day appends there rather than inheriting the source's slot")
    func duplicateOntoAnotherDayAppends() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 2, to: bed.today))
        let source = bed.seed("Source", on: bed.today)
        _ = bed.seed("Already there", on: future)
        _ = bed.seed("Also there", on: future)

        #expect(bed.repository.duplicate(source.id, toDate: future, actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: future) == ["Already there", "Also there", "Source"],
                "The copy takes a fresh slot at the end, not the source's slot on another day")
    }

    @Test("Moving to another day appends there and leaves both days' siblings alone")
    func moveAppendsToTheTargetDay() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 2, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        let live = bed.seed("Stay", on: bed.today)
        _ = bed.seed("Already there", on: future)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: bed.today))

        #expect(bed.repository.move(moved.id, toDate: future, timeOfDay: nil, actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: bed.today) == ["Stay"])
        #expect(bed.titles(on: future) == ["Already there", "Move me"])
        #expect(bed.repository.undo(actor: .user).isApplied,
                "The gap the move left behind was never closed, so the live session's intent stood still")
        #expect(bed.titles(on: bed.today) == ["Move me", "Stay"])
        #expect(bed.titles(on: future) == ["Already there"])
    }

    /// The long-press menu's "Move to" is the drag's secondary route, so it lands on `reposition` with
    /// `.endOfDay`: appended to the end of the target day, refused on a locked one.
    @Test("The menu's move route appends to its target and obeys the same locks as the drag")
    func repositionToEndOfDayAppendsAndStillRejectsLockedDays() throws {
        let bed = try TestBed()
        let past = try #require(calendar.date(byAdding: .day, value: -1, to: bed.today))
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        _ = bed.seed("Already there", on: future)

        #expect(bed.repository.reposition(
            moved.id, toDate: past, at: .endOfDay, notBefore: bed.today, scope: .allTraining, actor: .user, reason: nil
        ) == .rejected(.invalidTarget))

        #expect(bed.repository.reposition(
            moved.id, toDate: future, at: .endOfDay, notBefore: bed.today, scope: .allTraining, actor: .user, reason: nil
        ).isApplied)
        #expect(bed.titles(on: future) == ["Already there", "Move me"])
    }

    /// An index past the day's last slot means the same thing as `.endOfDay`, which is the contract
    /// the protocol documents rather than an accident of an internal clamp.
    @Test("An index beyond the day's last slot appends instead of failing")
    func repositionClampsAnOutOfRangeIndexToTheEnd() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        _ = bed.seed("Already there", on: future)

        #expect(bed.repository.reposition(
            moved.id, toDate: future, at: .index(99), notBefore: bed.today, scope: .allTraining, actor: .user, reason: nil
        ).isApplied)
        #expect(bed.titles(on: future) == ["Already there", "Move me"])
    }

    /// The renumbering trap the sparse ordering exists to avoid: a day left with a gap by an earlier
    /// move gets something dropped onto it, and a *sibling* holding a live session is renumbered as
    /// collateral - which makes its intent differ between snapshots and silently refuses the next undo.
    @Test("Dropping onto a day never renumbers a sibling holding a live session")
    func repositionLeavesLiveSiblingsUntouched() throws {
        let bed = try TestBed()
        let other = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let day = bed.today
        _ = bed.seed("First", on: day)
        let leaving = bed.seed("Leaving", on: day)
        let live = bed.seed("Live", on: day)
        let arriving = bed.seed("Arriving", on: other)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: day))

        #expect(bed.repository.reposition(
            leaving.id, toDate: other, at: .endOfDay, notBefore: day, scope: .allTraining, actor: .user, reason: nil
        ).isApplied)
        let liveOrderAfterGap = bed.storedDayOrder(of: live.id)

        #expect(bed.repository.reposition(
            arriving.id, toDate: day, at: .endOfDay, notBefore: day, scope: .allTraining, actor: .user, reason: nil
        ).isApplied)

        #expect(bed.titles(on: day) == ["First", "Live", "Arriving"])
        #expect(bed.storedDayOrder(of: live.id) == liveOrderAfterGap,
                "The dropped session took a fresh slot; the live sibling kept its own")
        #expect(bed.repository.undo(actor: .user).isApplied,
                "No live intent changed, so the athlete's Undo is not refused")
        #expect(bed.titles(on: day) == ["First", "Live"])
    }

    /// The same guarantee for a mid-day insert, which is what a real drag between two rows produces:
    /// the moved row takes a value inside the gap rather than pushing the rows after it along.
    @Test("Dropping between two sessions re-spaces only the moved row")
    func repositionBetweenSessionsWritesOnlyTheMovedRow() throws {
        let bed = try TestBed()
        let day = bed.today
        let first = bed.seed("First", on: day)
        let live = bed.seed("Live", on: day)
        let moved = bed.seed("Moved", on: day)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: day))
        let firstOrder = bed.storedDayOrder(of: first.id)
        let liveOrder = bed.storedDayOrder(of: live.id)

        #expect(bed.repository.reposition(
            moved.id, toDate: day, at: .index(1), notBefore: day, scope: .allTraining, actor: .user, reason: nil
        ).isApplied)

        #expect(bed.titles(on: day) == ["First", "Moved", "Live"])
        #expect(bed.storedDayOrder(of: first.id) == firstOrder)
        #expect(bed.storedDayOrder(of: live.id) == liveOrder)
        #expect(bed.repository.undo(actor: .user).isApplied)
        #expect(bed.titles(on: day) == ["First", "Live", "Moved"])
    }

    /// A legacy day whose rows predate drag ordering: dropping onto the end of it must not give those
    /// rows the numbers they never had, because that is a rewrite of intents the drop never touched.
    @Test("Appending to a day of unordered legacy rows leaves them unordered")
    func repositionOntoLegacyDayLeavesItAlone() throws {
        let bed = try TestBed()
        let day = bed.today
        let other = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let legacy = bed.seed("Legacy", on: day)
        let arriving = bed.seed("Arriving", on: other)
        bed.clearStoredDayOrder(for: legacy.id)

        #expect(bed.repository.reposition(
            arriving.id, toDate: day, at: .endOfDay, notBefore: day, scope: .allTraining, actor: .user, reason: nil
        ).isApplied)

        #expect(bed.titles(on: day) == ["Legacy", "Arriving"])
        #expect(bed.storedDayOrder(of: legacy.id) == nil)
    }

    // MARK: The locked-source policy
    //
    // A past day is history and a day holding performed training is a record of what happened, so
    // neither is a legal source *or* target - a missed session cannot be dragged forward out of
    // yesterday, and a planned sibling cannot leave a day whose other session was performed. This is
    // the approved product rule (`PlanDayLock`, `docs/implementation/plan-tab.md` §10), not an
    // oversight: both routes into `reposition` are pinned to it here so a future change is deliberate.

    @Test("A missed session on a past day cannot be dragged forward")
    func pastSourceDayRejectsDrop() throws {
        let bed = try TestBed()
        let past = try #require(calendar.date(byAdding: .day, value: -1, to: bed.today))
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let missed = bed.seed("Missed Monday", on: past)
        let versionsBefore = bed.repository.versions(limit: 100).count

        for position in [PlanDayPosition.index(0), .endOfDay] {
            #expect(bed.repository.reposition(
                missed.id, toDate: future, at: position, notBefore: bed.today, scope: .allTraining, actor: .user, reason: nil
            ) == .rejected(.invalidTarget))
        }

        #expect(bed.titles(on: past) == ["Missed Monday"])
        #expect(bed.titles(on: future).isEmpty)
        #expect(bed.repository.versions(limit: 100).count == versionsBefore)
    }

    @Test("The presentation offers no move destinations out of a locked day")
    func lockedDaysOfferNoMoveDestinations() throws {
        let bed = try TestBed()
        let past = try #require(calendar.date(byAdding: .day, value: -1, to: bed.today))
        _ = bed.seed("Missed", on: past)
        let performed = bed.seed("Performed", on: bed.today)
        _ = bed.seed("Planned sibling", on: bed.today)
        try bed.complete(performed.id)

        let week = bed.repository.week(containing: bed.today, filter: .allTraining)
        let sessions = week.days.flatMap(\.sessions)
        let completedIDs = bed.repository.completedScheduledWorkoutIDs(among: sessions.map(\.id))
        let presentation = PlanWeekPresentation.build(
            week: week,
            statuses: Dictionary(uniqueKeysWithValues: sessions.map {
                ($0.id, completedIDs.contains($0.id) ? ScheduleStatus.completed : .planned)
            }),
            today: bed.today,
            calendar: calendar
        )
        let pastMatch = presentation.days.first { calendar.isDate($0.date, inSameDayAs: past) }
        let todayMatch = presentation.days.first(where: \.isToday)
        let pastRow = try #require(pastMatch)
        let todayRow = try #require(todayMatch)

        #expect(pastRow.lock == .past)
        #expect(todayRow.lock == .completed)
        #expect(presentation.moveDestinations(from: pastRow, calendar: calendar).isEmpty)
        #expect(presentation.moveDestinations(from: todayRow, calendar: calendar).isEmpty,
                "The planned sibling of a performed session stays put, by policy")
        #expect(todayRow.sessions.allSatisfy { $0.showsReorderHandle == false })
    }

    // MARK: Filtered scope

    /// The drop index the grid produces counts only the rows the athlete could see. Interpreting it
    /// against the day's full persistence order would land the session on the wrong side of a row.
    @Test("A filtered drop lands where the athlete saw it, among the visible rows only")
    func repositionResolvesTheIndexAgainstTheVisibleRows() throws {
        let bed = try TestBed()
        let programB = bed.addProgram("B")
        let day = bed.today
        let other = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        _ = bed.seed("A hidden", on: day)
        _ = bed.seed("B visible", on: day, program: programB)
        let moved = bed.seed("B moving", on: other, program: programB)

        // Program B's grid shows one row on `day`; dropping below it is `.index(1)`.
        #expect(bed.repository.reposition(
            moved.id,
            toDate: day,
            at: .index(1),
            notBefore: day,
            scope: .program(programB),
            actor: .user,
            reason: nil
        ).isApplied)

        #expect(bed.titles(on: day, filter: .program(programB)) == ["B visible", "B moving"],
                "The drop landed below the row it was dropped below")
        #expect(bed.titles(on: day) == ["A hidden", "B visible", "B moving"],
                "The hidden program's session kept its place")
    }

    @Test("A filtered drop at the first visible slot stays ahead of the visible rows only")
    func repositionAtTheFirstVisibleSlotLeavesHiddenRowsAlone() throws {
        let bed = try TestBed()
        let programB = bed.addProgram("B")
        let day = bed.today
        let other = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        let hidden = bed.seed("A hidden", on: day)
        _ = bed.seed("B visible", on: day, program: programB)
        let moved = bed.seed("B moving", on: other, program: programB)
        let hiddenOrder = bed.storedDayOrder(of: hidden.id)

        #expect(bed.repository.reposition(
            moved.id,
            toDate: day,
            at: .index(0),
            notBefore: day,
            scope: .program(programB),
            actor: .user,
            reason: nil
        ).isApplied)

        #expect(bed.titles(on: day, filter: .program(programB)) == ["B moving", "B visible"])
        #expect(bed.titles(on: day) == ["A hidden", "B moving", "B visible"])
        #expect(bed.storedDayOrder(of: hidden.id) == hiddenOrder,
                "A filtered reorder never rewrites the intent of a session it did not show")
    }

    /// Within one filtered day, the index the grid produced still counts visible rows only - here the
    /// hidden session sits between two visible ones, so slot 1 and persistence slot 1 differ.
    @Test("A within-day filtered reorder counts visible rows across a hidden one")
    func repositionWithinDayIgnoresHiddenRowsWhenCountingSlots() throws {
        let bed = try TestBed()
        let programB = bed.addProgram("B")
        let day = bed.today
        _ = bed.seed("B first", on: day, program: programB)
        _ = bed.seed("A hidden", on: day)
        let moved = bed.seed("B third", on: day, program: programB)
        _ = bed.seed("B fourth", on: day, program: programB)

        // Visible: [B first, B third, B fourth]. Drop "B third" last.
        #expect(bed.repository.reposition(
            moved.id,
            toDate: day,
            at: .index(2),
            notBefore: day,
            scope: .program(programB),
            actor: .user,
            reason: nil
        ).isApplied)

        #expect(bed.titles(on: day, filter: .program(programB)) == ["B first", "B fourth", "B third"])
        #expect(bed.titles(on: day) == ["B first", "A hidden", "B fourth", "B third"],
                "The hidden row still sits between the two rows it was between")
    }

    /// The grid renders a day as open when nothing it shows was performed, so the repository has to
    /// agree - otherwise every drop onto that day is silently refused with an insertion indicator
    /// still drawn under the athlete's finger.
    @Test("A performed session the filter hides does not lock the day it hides it on")
    func aHiddenPerformedSessionDoesNotLockAVisiblyOpenDay() throws {
        let bed = try TestBed()
        let programB = bed.addProgram("B")
        let day = bed.today
        let other = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        let hiddenPerformed = bed.seed("A performed", on: day)
        try bed.complete(hiddenPerformed.id)
        let moved = bed.seed("B moving", on: other, program: programB)

        #expect(bed.repository.reposition(
            moved.id,
            toDate: day,
            at: .endOfDay,
            notBefore: day,
            scope: .program(programB),
            actor: .user,
            reason: nil
        ).isApplied)
        #expect(bed.titles(on: day, filter: .program(programB)) == ["B moving"])

        #expect(bed.repository.reposition(
            moved.id,
            toDate: other,
            at: .endOfDay,
            notBefore: day,
            scope: .allTraining,
            actor: .user,
            reason: nil
        ) == .rejected(.invalidTarget),
        "Unfiltered, the same day is a completed day and refuses the move")
    }

    // MARK: The standalone reorder API

    @Test("Reordering a day of rows written before drag ordering actually reorders it")
    func reorderPersistsOnLegacyRowsWithNoStoredOrder() throws {
        let bed = try TestBed()
        let day = bed.today
        let first = bed.seed("First", on: day)
        let second = bed.seed("Second", on: day)
        bed.clearStoredDayOrder(for: first.id)
        bed.clearStoredDayOrder(for: second.id)
        // Rows with no stored order fall back to a stable identity tie-break, so reverse whatever the
        // day currently reads as rather than assuming it.
        let before = Array(bed.repository.day(day, filter: .allTraining).sessions.reversed())

        #expect(bed.repository.reorder(
            day: day, orderedIDs: before.map(\.id), actor: .user, reason: nil
        ).isApplied)

        #expect(bed.titles(on: day) == before.map(\.workout.title))
    }

    @Test("A reorder that changes nothing is refused instead of appending a version")
    func reorderRejectsANoOp() throws {
        let bed = try TestBed()
        let day = bed.today
        let first = bed.seed("First", on: day)
        let second = bed.seed("Second", on: day)
        let versionsBefore = bed.repository.versions(limit: 100).count

        #expect(bed.repository.reorder(
            day: day, orderedIDs: [first.id, second.id], actor: .user, reason: nil
        ) == .rejected(.invalidTarget))
        #expect(bed.repository.versions(limit: 100).count == versionsBefore)
        #expect(bed.titles(on: day) == ["First", "Second"])
    }

    @Test("Geometry resolves before and after slots, past locks, and completed locks")
    func dragTargetResolution() {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_774_000_000))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let past = calendar.date(byAdding: .day, value: -1, to: today)!
        let first = UUID()
        let second = UUID()
        let days = [
            PlanDragReorderModel.DayGeometry(
                date: past,
                frame: CGRect(x: 0, y: 0, width: 320, height: 80),
                sessions: [],
                lock: .past
            ),
            PlanDragReorderModel.DayGeometry(
                date: today,
                frame: CGRect(x: 0, y: 80, width: 320, height: 120),
                sessions: [
                    .init(id: first, frame: CGRect(x: 0, y: 80, width: 320, height: 60)),
                    .init(id: second, frame: CGRect(x: 0, y: 140, width: 320, height: 60))
                ],
                lock: nil
            ),
            PlanDragReorderModel.DayGeometry(
                date: tomorrow,
                frame: CGRect(x: 0, y: 200, width: 320, height: 80),
                sessions: [],
                lock: .completed
            )
        ]

        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 190),
            sourceID: first,
            sourceDate: today,
            days: days
        ) == .destination(.init(date: today, index: 1, displayIndex: 2)))
        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 90),
            sourceID: second,
            sourceDate: today,
            days: days
        ) == .destination(.init(date: today, index: 0, displayIndex: 0)))
        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 40),
            sourceID: first,
            sourceDate: today,
            days: days
        ) == .locked(date: past, reason: .past))
        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 240),
            sourceID: first,
            sourceDate: today,
            days: days
        ) == .locked(date: tomorrow, reason: .completed))
    }
}

@MainActor
private final class TestBed {
    let container: ModelContainer
    let repository: SwiftDataPlanRepository
    let today: Date
    private let programID: UUID

    init() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repository = SwiftDataPlanRepository(context: container.mainContext)
        today = Calendar.planWeek.startOfDay(for: Date(timeIntervalSince1970: 1_774_000_000))
        programID = repository.addProgram(Program(name: "Test", createdAt: today)).id
    }

    func workout(_ title: String, on date: Date, program: UUID? = nil) -> ScheduledWorkout {
        var exercise = PlannedExercise(exerciseName: "Squat", definitionId: "back-squat")
        exercise.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        let workout = Workout(
            title: title,
            blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)]
        )
        return ScheduledWorkout(
            programID: program ?? programID,
            date: date,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        )
    }

    @discardableResult
    func seed(_ title: String, on date: Date, program: UUID? = nil) -> ScheduledWorkout {
        repository.addScheduled(workout(title, on: date, program: program))
    }

    /// A second active program, so a `.program(id)` filter hides real sessions rather than none.
    func addProgram(_ name: String) -> UUID {
        repository.addProgram(Program(name: name, createdAt: today)).id
    }

    func titles(on date: Date, filter: ProgramFilter = .allTraining) -> [String] {
        repository.day(date, filter: filter).sessions.map(\.workout.title)
    }

    /// Drive one scheduled workout all the way to a frozen performed log.
    func complete(_ id: UUID) throws {
        _ = try #require(repository.startSession(forScheduled: id, now: today))
        guard case .completed = repository.completeSession(
            forScheduled: id,
            acknowledgingOpenWork: true,
            now: today
        ) else {
            throw CompletionFailure()
        }
    }

    struct CompletionFailure: Error {}

    func storedDayOrders(on date: Date) -> [Int?] {
        repository.day(date, filter: .allTraining).sessions.map(\.dayOrder)
    }

    func storedDayOrder(of id: UUID) -> Int? {
        repository.scheduledWorkout(id)?.dayOrder
    }

    /// Null out one row's stored order, the way a schedule written before drag ordering shipped looks
    /// on disk. Unordered rows sort ahead of ordered ones, so the result is still deterministic.
    func clearStoredDayOrder(for id: UUID) {
        let rows = (try? container.mainContext.fetch(FetchDescriptor<SDScheduledWorkout>())) ?? []
        for row in rows where row.id == id { row.dayOrder = nil }
        try? container.mainContext.save()
    }
}
