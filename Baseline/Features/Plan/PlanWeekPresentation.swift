import Foundation

/// Pure presentation model behind the Plan tab's bounded weekly grid.
///
/// It turns a `TrainingWeek` plus the derived per-session statuses into exactly what each day cell
/// renders, so every day-state rule - the green performed cell, the neutral session with its reorder
/// handle, rest, the empty "+", and the extra "+" under today's and future days - is unit-testable
/// without a view tree. No SwiftUI, no persistence, no formatting the view could not reproduce.

/// What a weekday cell shows above its letter in the seven-day strip.
enum PlanWeekdayMark: Equatable, Sendable {
    case none
    case completed          // green dot: the day has a performed session
    case rest               // moon: the day is an explicit rest day
}

struct PlanWeekdayCell: Identifiable, Equatable, Sendable {
    let date: Date
    /// The locale's narrow weekday symbol ("M", "T", …).
    let letter: String
    let mark: PlanWeekdayMark
    let isToday: Bool
    var id: Date { date }
}

/// One scheduled session as the weekly grid renders it.
struct PlanSessionEntry: Identifiable, Equatable, Sendable {
    /// The scheduled workout's id - the view resolves the domain object from it for taps and menus.
    let id: UUID
    let title: String
    /// The work in one line ("Bike + Row", plus a planned duration when the plan carries one). Never
    /// the word "planned": a plan state is not a subtitle, and an absent duration is not a state.
    let detail: String
    let status: ScheduleStatus
    /// Reorder is offered on today's and future sessions only; a day already trained is history.
    let showsReorderHandle: Bool

    /// A performed `CompletedWorkoutLog` exists for this session (`ScheduleStatusResolver` lets
    /// performed facts win, and `PlanStore.statuses` resolves them from one batched completed-log
    /// fetch). This - not "the day is in the past" - is what fills the cell green and offers the log.
    var isCompleted: Bool { status == .completed }
}

/// What fills a day's cell stack.
enum PlanDayContent: Equatable, Sendable {
    case sessions([PlanSessionEntry])
    case rest
    case empty
}

struct PlanDayRow: Identifiable, Equatable, Sendable {
    let date: Date
    let dayNumber: String
    let weekdayAbbreviation: String
    let isToday: Bool
    let isPast: Bool
    let content: PlanDayContent
    /// A trailing "+" cell under the day's sessions, for adding a second session. Today and future
    /// only - a past day that already happened gets no invitation to add more to it.
    let showsAddAnother: Bool
    var id: Date { date }

    var sessions: [PlanSessionEntry] {
        if case .sessions(let entries) = content { return entries }
        return []
    }
}

struct PlanWeekPresentation: Equatable, Sendable {
    let weekStart: Date
    /// "JUL 20 – 26", or "JUL 28 – AUG 3" when the week straddles a month boundary.
    let rangeLabel: String
    /// The navigation title for the focused week.
    let monthLabel: String
    let weekdays: [PlanWeekdayCell]
    let days: [PlanDayRow]

    var containsToday: Bool { days.contains { $0.isToday } }

    static func build(
        week: TrainingWeek,
        statuses: [UUID: ScheduleStatus],
        today: Date,
        calendar: Calendar = .planWeek
    ) -> PlanWeekPresentation {
        let startOfToday = calendar.startOfDay(for: today)
        let days = week.days.map { day -> PlanDayRow in
            let date = calendar.startOfDay(for: day.date)
            let isToday = calendar.isDate(date, inSameDayAs: startOfToday)
            let isPast = date < startOfToday
            let entries = day.sessions.map { session in
                let status = statuses[session.id] ?? .planned
                return PlanSessionEntry(
                    id: session.id,
                    title: session.workout.title,
                    detail: detail(for: session, isCompleted: status == .completed),
                    status: status,
                    showsReorderHandle: status != .completed && !isPast
                )
            }
            return PlanDayRow(
                date: date,
                dayNumber: date.formatted(.dateTime.day()),
                weekdayAbbreviation: date.formatted(.dateTime.weekday(.abbreviated)).uppercased(),
                isToday: isToday,
                isPast: isPast,
                content: entries.isEmpty ? (day.isRestDay ? .rest : .empty) : .sessions(entries),
                showsAddAnother: !entries.isEmpty && !isPast
            )
        }
        return PlanWeekPresentation(
            weekStart: calendar.startOfDay(for: week.startDate),
            rangeLabel: rangeLabel(weekStart: week.startDate, calendar: calendar),
            monthLabel: week.startDate.formatted(.dateTime.month(.wide).year()),
            weekdays: days.map { row in
                PlanWeekdayCell(
                    date: row.date,
                    letter: row.date.formatted(.dateTime.weekday(.narrow)),
                    mark: mark(for: row),
                    isToday: row.isToday
                )
            },
            days: days
        )
    }

    /// Today is marked by its accent letter alone - a dot or moon above it would read as a second,
    /// competing state on the one day the strip is already pointing at.
    private static func mark(for row: PlanDayRow) -> PlanWeekdayMark {
        if row.isToday { return .none }
        if row.sessions.contains(where: \.isCompleted) { return .completed }
        if case .rest = row.content { return .rest }
        return .none
    }

    /// The performed cell says what it opens; a planned cell says what the work is.
    private static func detail(for session: ScheduledWorkout, isCompleted: Bool) -> String {
        if isCompleted { return "View log" }
        let names = session.workout.allExercises.prefix(2).map(\.exerciseName)
        let work = names.isEmpty ? (session.workout.goal ?? "Training") : names.joined(separator: " + ")
        guard let planned = AggregateProvider.aggregates(for: [session]).first(where: { $0.key == .duration }) else {
            return work
        }
        return "\(work) · \(MetricFormat.durationLong(planned.total))"
    }

    private static func rangeLabel(weekStart: Date, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: weekStart)
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = sameMonth
            ? end.formatted(.dateTime.day())
            : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)".uppercased()
    }
}
