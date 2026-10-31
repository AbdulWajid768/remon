import Foundation

/// Monthly data-plan cycle that resets on a given day of the month.
struct BillingCycle: Equatable, Sendable {
    var start: Date
    var end: Date

    /// `resetDay` is clamped to 1…28 so every month has it.
    static func current(containing date: Date, resetDay: Int, calendar: Calendar = .current) -> BillingCycle {
        let day = min(max(resetDay, 1), 28)
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = day
        var start = calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
        if start > date {
            start = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        }
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return BillingCycle(start: start, end: end)
    }

    func fractionElapsed(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        return total > 0 ? min(max(date.timeIntervalSince(start) / total, 0), 1) : 0
    }

    /// Linear projection of usage at the end of the cycle.
    func projectedUsage(used: UInt64, at date: Date) -> UInt64 {
        let fraction = fractionElapsed(at: date)
        guard fraction > 0.02 else { return used }
        return UInt64(Double(used) / fraction)
    }
}

enum UsageAnomaly {
    /// An app is anomalous when today's usage is well above its recent daily average and big
    /// enough to matter. `history` holds per-day totals for the previous days (zeros included).
    static func ratio(today: UInt64, history: [UInt64], minimumBytes: UInt64 = 50_000_000) -> Double? {
        guard today >= minimumBytes, history.count >= 3 else { return nil }
        let average = Double(history.reduce(0, +)) / Double(history.count)
        guard average > 0 else { return nil }
        let ratio = Double(today) / average
        return ratio >= 3 ? ratio : nil
    }
}
