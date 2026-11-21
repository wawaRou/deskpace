struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// Compare a measured landing with the native baseline for the same gesture.
struct MotionChecks {
    let frameInterval: Double

    func checkRate(_ t90: Double, native: Double, rate: Double) throws {
        let expected = native / rate
        let tolerance = max(expected * 0.12, frameInterval + 0.004)
        guard abs(t90 - expected) <= tolerance else {
            throw Failure("设为 \(rate)× 时，T90 为 \(Int(t90 * 1000)) 毫秒，预期约 \(Int(expected * 1000)) 毫秒")
        }
    }

    func checkSeparation(native: Double, triple: Double, quadruple: Double) throws {
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
