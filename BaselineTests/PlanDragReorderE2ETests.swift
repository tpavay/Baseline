import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The Plan tab's drag reorder driven the way a finger drives it: the drop point is a coordinate on
/// the *rendered* week, resolved against the frames the live layout published, and committed through
/// the same repository call the gesture's `finishDrag` makes.
///
/// `PlanDragReorderTests` proves the repository's ordering rules and `PlanDragReorderModel` proves
/// target resolution against hand-built rectangles. Neither one can catch a week whose real rows land
/// somewhere the model reads differently — an aimed drop that resolves to the neighbouring day, or a
/// locked day whose frame does not actually cover the row the athlete sees on it. This suite closes
/// that seam by using the layout's own geometry as the input.
@MainActor
@Suite(.serialized)
struct PlanDragReorderE2ETests {

    /// Wednesday, 22 July 2026 — the same pinned week the render suite uses, so the visible days are
    /// Mon performed · Tue missed · Wed (today) two sessions · Thu rest · Fri planned · Sat/Sun empty.
    private static let fixedNow = Calendar.planWeek.date(
        from: DateComponents(year: 2026, month: 7, day: 22, hour: 12)
    )!

    private let cal = Calendar.planWeek

    @Test("A drop aimed under a future day's session lands as that day's second session")
    func aimedDropOntoAFutureDayLandsWhereTheAthleteAimed() async throws {
        let screen = try await PlanDragHarness(screen: PlanWeekScreen()).ready()
        defer { screen.tearDown() }

        let zone2 = try #require(screen.sessionID(titled: "Zone 2 Recovery"))
        let legDay = try #require(screen.sessionID(titled: "Leg Day"))
        let friday = try #require(cal.date(byAdding: .day, value: 4, to: cal.weekStart(for: Self.fixedNow)))

        // Aim just under the middle of Friday's only row — the gesture's "drop after this one" region.
        let legDayFrame = try #require(screen.geometry.sessions[legDay])
        let drop = CGPoint(x: legDayFrame.midX, y: legDayFrame.midY + 1)

        let target = screen.resolveTarget(at: drop, sourceID: zone2, sourceDate: Self.fixedNow)
        #expect(target == .destination(
            .init(date: cal.startOfDay(for: friday), index: 1, displayIndex: 1)
        ), "The aimed point resolves to the slot after Leg Day")

        try #require(screen.commit(target, sourceID: zone2))

        try await screen.settleUntil {
            guard let moved = screen.element(labelled: "Zone 2 Recovery"),
                  let leg = screen.element(labelled: "Leg Day") else { return false }
            return moved.accessibilityFrame.minY > leg.accessibilityFrame.minY
        }
        #expect(screen.titles(on: friday) == ["Leg Day", "Zone 2 Recovery"])
        #expect(screen.titles(on: Self.fixedNow) == ["Evening Accessories"])
        try screen.capture("plan-drag-aimed-drop-future-day")
    }

    @Test("A drop aimed under the day's other session reorders within the day")
    func aimedDropWithinTheDayReordersIt() async throws {
        let screen = try await PlanDragHarness(screen: PlanWeekScreen()).ready()
        defer { screen.tearDown() }

        let zone2 = try #require(screen.sessionID(titled: "Zone 2 Recovery"))
        let accessories = try #require(screen.sessionID(titled: "Evening Accessories"))
        let accessoriesFrame = try #require(screen.geometry.sessions[accessories])
        let drop = CGPoint(x: accessoriesFrame.midX, y: accessoriesFrame.midY + 1)

        let target = screen.resolveTarget(at: drop, sourceID: zone2, sourceDate: Self.fixedNow)
        #expect(target == .destination(
            .init(date: cal.startOfDay(for: Self.fixedNow), index: 1, displayIndex: 2)
        ))

        try #require(screen.commit(target, sourceID: zone2))

        try await screen.settleUntil {
            guard let moved = screen.element(labelled: "Zone 2 Recovery"),
                  let other = screen.element(labelled: "Evening Accessories") else { return false }
            return moved.accessibilityFrame.minY > other.accessibilityFrame.minY
        }
        #expect(screen.titles(on: Self.fixedNow) == ["Evening Accessories", "Zone 2 Recovery"])
        try screen.capture("plan-drag-aimed-drop-within-day")
    }

    @Test("Aiming at a past or performed day resolves to a locked target and moves nothing")
    func aimingAtALockedDayCommitsNothing() async throws {
        let screen = try await PlanDragHarness(screen: PlanWeekScreen()).ready()
        defer { screen.tearDown() }

        let zone2 = try #require(screen.sessionID(titled: "Zone 2 Recovery"))
        let monday = cal.weekStart(for: Self.fixedNow)
        let tuesday = try #require(cal.date(byAdding: .day, value: 1, to: monday))

        // Monday holds a performed session and Tuesday is a plain past day: both refuse a drop, and
        // the point aimed at each is the centre of the row the athlete actually sees there.
        for (title, date) in [("Full Body", monday), ("Push Day", tuesday)] {
            let rowID = try #require(screen.sessionID(titled: title))
            let frame = try #require(screen.geometry.sessions[rowID])
            let target = screen.resolveTarget(
                at: CGPoint(x: frame.midX, y: frame.midY),
                sourceID: zone2,
                sourceDate: Self.fixedNow
            )
            #expect(target == .locked(date: cal.startOfDay(for: date), reason: .past),
                    "\(title)'s day refuses the drop")
            #expect(screen.commit(target, sourceID: zone2) == false, "A locked target commits nothing")
        }

        try await screen.settle()
        #expect(screen.titles(on: Self.fixedNow) == ["Zone 2 Recovery", "Evening Accessories"])
        #expect(screen.titles(on: monday) == ["Full Body"])
        #expect(screen.titles(on: tuesday) == ["Push Day"])
        try screen.capture("plan-drag-locked-day-rejected")
    }

    @Test("A drop released above the week's first day is outside the grid and moves nothing")
    func releasingOutsideTheGridCommitsNothing() async throws {
        let screen = try await PlanDragHarness(screen: PlanWeekScreen()).ready()
        defer { screen.tearDown() }

        let zone2 = try #require(screen.sessionID(titled: "Zone 2 Recovery"))
        let topOfGrid = try #require(screen.geometry.days.values.map(\.minY).min())
        let target = screen.resolveTarget(
            at: CGPoint(x: 200, y: topOfGrid - 40),
            sourceID: zone2,
            sourceDate: Self.fixedNow
        )

        #expect(target == .outside)
        #expect(screen.commit(target, sourceID: zone2) == false)
        #expect(screen.titles(on: Self.fixedNow) == ["Zone 2 Recovery", "Evening Accessories"])
    }
}

// MARK: - Harness

/// `PlanWeekScreen` plus the two things the drag gesture owns privately: the published frames the drop
/// resolves against, and the commit `finishDrag` makes once a target is resolved.
@MainActor
private struct PlanDragHarness {
    let screen: PlanWeekScreen

    /// Wait until the week has rendered *and* published a frame for every day and session, so a drop
    /// point is never aimed at geometry that has not settled.
    func ready() async throws -> PlanWeekScreen {
        try await screen.settleUntil {
            screen.element(labelled: "Leg Day") != nil
                && screen.geometry.days.count == 7
                && screen.geometry.sessions.count >= 5
        }
        return screen
    }
}

extension PlanWeekScreen {
    private var cal: Calendar { .planWeek }

    private var now: Date {
        Calendar.planWeek.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 12))!
    }

    private var presentation: PlanWeekPresentation {
        let week = plan.week(containing: now)
        return PlanWeekPresentation.build(
            week: week,
            statuses: plan.statuses(for: week.days.flatMap(\.sessions), today: now),
            today: now,
            calendar: cal
        )
    }

    func sessionID(titled title: String) -> UUID? {
        plan.week(containing: now).days
            .flatMap(\.sessions)
            .first { $0.workout.title == title }?
            .id
    }

    func titles(on date: Date) -> [String] {
        presentation.days
            .first { cal.isDate($0.date, inSameDayAs: date) }?
            .sessions
            .map(\.title) ?? []
    }

    /// The same assembly `PlanView.dragDayGeometry()` performs: published frames plus the day locks
    /// the presentation already resolved, never re-derived here.
    func resolveTarget(at point: CGPoint, sourceID: UUID, sourceDate: Date) -> PlanDragReorderModel.Target {
        let days = presentation.days.compactMap { row -> PlanDragReorderModel.DayGeometry? in
            let date = cal.startOfDay(for: row.date)
            guard let frame = geometry.days[date] else { return nil }
            let sessions = row.sessions.compactMap { entry -> PlanDragReorderModel.SessionGeometry? in
                geometry.sessions[entry.id].map { .init(id: entry.id, frame: $0) }
            }
            return .init(date: date, frame: frame, sessions: sessions, lock: row.lock)
        }
        return PlanDragReorderModel.target(
            at: point,
            sourceID: sourceID,
            sourceDate: sourceDate,
            days: days
        )
    }

    /// What `PlanView.finishDrag` does with a resolved target: commit a destination, ignore anything
    /// else. Returns whether the schedule was written.
    @discardableResult
    func commit(_ target: PlanDragReorderModel.Target, sourceID: UUID) -> Bool {
        guard case .destination(let destination) = target else { return false }
        return plan.reposition(
            sourceID,
            toDate: destination.date,
            at: .index(destination.index),
            notBefore: cal.startOfDay(for: now)
        ).isApplied
    }
}

/// The frames `PlanView` resolves a drop against, captured from the live layout through the same
/// preferences the view's own gesture reads. Lock-guarded because SwiftUI delivers preference updates
/// through a `@Sendable` closure.
final class PlanDragGeometryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionFrames: [UUID: CGRect] = [:]
    private var dayFrames: [Date: CGRect] = [:]

    var sessions: [UUID: CGRect] { lock.withLock { sessionFrames } }
    var days: [Date: CGRect] { lock.withLock { dayFrames } }

    func record(sessions: [UUID: CGRect]) { lock.withLock { sessionFrames = sessions } }
    func record(days: [Date: CGRect]) { lock.withLock { dayFrames = days } }
}
