import CoreGraphics

/// A failed accelerated landing yields to macOS. Only a complete native landing
/// with observable motion on the same display counts toward the next attempt.
struct DisplayFeedback {
    static let landingTolerance = 1.5 // points

    private struct Cooldown {
        let interval: Int
        var remaining: Int
    }

    private var cooldowns: [CGDirectDisplayID: Cooldown] = [:]

    func canAccelerate(on display: CGDirectDisplayID) -> Bool {
        (cooldowns[display]?.remaining ?? 0) == 0
    }

    mutating func missedFeedback(on display: CGDirectDisplayID) {
        let interval = cooldowns[display].map { min(8, 2 * $0.interval) } ?? 1
        cooldowns[display] = Cooldown(interval: interval, remaining: interval)
    }

    mutating func confirmedNativeLanding(on display: CGDirectDisplayID, gap: Double, samples: [TailPoint]) {
        guard let remaining = cooldowns[display]?.remaining, remaining > 0 else { return }
        // A subpixel offset on the final frame still counts as arrived.
        let arrivalProgress = 1 - Self.landingTolerance / gap
        if samples.contains(where: { $0.progress > 0 && $0.progress < arrivalProgress }) {
            cooldowns[display]?.remaining = remaining - 1
        }
    }

    mutating func confirmedPlayback(on display: CGDirectDisplayID) {
        cooldowns.removeValue(forKey: display)
    }
}
