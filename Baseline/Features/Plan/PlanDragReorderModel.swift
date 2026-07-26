import CoreGraphics
import Foundation

/// Pure target resolution for Plan View drag reorder.
///
/// Geometry comes from the rendered weekly grid, while all schedule meaning stays explicit in the
/// input. The view can therefore animate lift/gap feedback without becoming the authority for whether
/// a move is legal, and tests can exercise every insertion boundary without synthesizing touch events.
struct PlanDragReorderModel: Sendable {
    struct SessionGeometry: Equatable, Sendable {
        let id: UUID
        let frame: CGRect
    }

    struct DayGeometry: Equatable, Sendable {
        let date: Date
        let frame: CGRect
        let sessions: [SessionGeometry]
        let isPast: Bool
        let isCompleted: Bool
    }

    struct Destination: Equatable, Sendable {
        let date: Date
        /// Final index after the dragged session has been removed from its source day.
        let index: Int
        /// Slot in the currently rendered rows, which still include the lifted source as a placeholder.
        let displayIndex: Int
    }

    enum LockReason: Equatable, Sendable {
        case past
        case completed
    }

    enum Target: Equatable, Sendable {
        case destination(Destination)
        case locked(date: Date, reason: LockReason)
        case noChange
        case outside
    }

    static func target(
        at location: CGPoint,
        sourceID: UUID,
        sourceDate: Date,
        days: [DayGeometry],
        calendar: Calendar = .planWeek
    ) -> Target {
        guard let day = nearestDay(to: location, in: days) else { return .outside }
        if day.isPast { return .locked(date: day.date, reason: .past) }
        if day.isCompleted { return .locked(date: day.date, reason: .completed) }

        let rawIndex = day.sessions.firstIndex { location.y < $0.frame.midY } ?? day.sessions.count
        let isSourceDay = calendar.isDate(day.date, inSameDayAs: sourceDate)
        guard isSourceDay, let sourceIndex = day.sessions.firstIndex(where: { $0.id == sourceID }) else {
            return .destination(Destination(date: day.date, index: rawIndex, displayIndex: rawIndex))
        }

        let finalIndex = rawIndex > sourceIndex ? rawIndex - 1 : rawIndex
        guard finalIndex != sourceIndex else { return .noChange }
        let displayIndex = finalIndex > sourceIndex ? finalIndex + 1 : finalIndex
        return .destination(Destination(date: day.date, index: finalIndex, displayIndex: displayIndex))
    }

    private static func nearestDay(to location: CGPoint, in days: [DayGeometry]) -> DayGeometry? {
        let verticallyRelevant = days.filter {
            location.y >= $0.frame.minY && location.y <= $0.frame.maxY
        }
        if let containing = verticallyRelevant.min(by: {
            abs(location.x - $0.frame.midX) < abs(location.x - $1.frame.midX)
        }) {
            return containing
        }

        // Hairlines and a target gap can leave a few points between adjacent day frames. Resolve that
        // seam to the visually nearest day, but do not accept a drag above or below the weekly grid.
        guard let first = days.min(by: { $0.frame.minY < $1.frame.minY }),
              let last = days.max(by: { $0.frame.maxY < $1.frame.maxY }),
              location.y >= first.frame.minY,
              location.y <= last.frame.maxY else {
            return nil
        }
        return days.min(by: {
            abs(location.y - $0.frame.midY) < abs(location.y - $1.frame.midY)
        })
    }
}
