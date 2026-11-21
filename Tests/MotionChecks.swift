struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// Compare a measured landing with the native baseline for the same gesture.
struct MotionTiming {
    let t90: Double
    let frameInterval: Double

    init(t90: Double, frameIntervals: [Double]) throws {
        guard !frameIntervals.isEmpty else { throw Failure("收尾期间未测到刷新周期") }
        self.t90 = t90
        let sorted = frameIntervals.sorted()
        frameInterval = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }

    func checkRate(native: Double, rate: Double) throws {
        let expected = native / rate
        let tolerance = max(expected * 0.12, frameInterval + 0.004)
        guard abs(t90 - expected) <= tolerance else {
            throw Failure("设为 \(rate)× 时，T90 为 \(Int(t90 * 1000)) 毫秒，预期约 \(Int(expected * 1000)) 毫秒")
        }
    }

    static func checkSeparation(native: Double, triple: Double, quadruple: Double) throws {
        // Require at least half the expected gap between the two measured rates.
        let expectedGap = native / 3 - native / 4
        guard triple - quadruple >= expectedGap / 2 else { throw Failure("3× 与 4× 的实测倍率未拉开") }
    }
}

struct LandingConfirmation {
    private var firstAtTarget: Double?

    mutating func observe(at time: Double, distance: Double?, current: Bool) -> Bool {
        guard let distance, abs(distance) <= 2, current else {
            firstAtTarget = nil
            return false
        }
        guard let firstAtTarget else {
            self.firstAtTarget = time
            return false
        }
        return time - firstAtTarget >= 0.035
    }
}

// Choose the starting space and direction for an ordinary swipe or a three-space chain.
struct ProbeRoute {
    let start: Int
    let step: Int

    init(origin: Int, count: Int, requestedStep: Int?, chain: Bool) throws {
        step = requestedStep ?? (origin + 1 < count ? 1 : -1)
        if chain {
            guard count >= 3 else { throw Failure("连续同向切换需要三个相邻空间") }
            start = step > 0 ? min(origin, count - 3) : max(origin, 2)
        } else {
            guard (0..<count).contains(origin + step) else { throw Failure("这个方向没有相邻桌面") }
            start = origin
        }
    }
}
