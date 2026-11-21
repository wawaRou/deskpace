import Foundation

struct TailPoint {
    let time: Double
    let progress: Double

    static func time(at threshold: Double, in points: [TailPoint]) -> Double? {
        guard (0...1).contains(threshold), let i = points.firstIndex(where: { $0.progress >= threshold }) else { return nil }
        if i == 0 { return points[0].time }
        let a = points[i - 1], b = points[i]
        return a.time + (b.time - a.time) * (threshold - a.progress) / (b.progress - a.progress)
    }
}

/// A recording of distance travelled after lift, normalised to the distance remaining.
struct TailCurve {
    let points: [TailPoint]
    private let t90: Double
    private let slopeAtLift: Double
    private let slopeAt90: Double
    var duration: Double { points[points.count - 1].time }

    init?(_ points: [TailPoint]) {
        guard points.count >= 3, points.first?.time == 0, points.first?.progress == 0,
              points.last?.progress == 1 else { return nil }
        for (a, b) in zip(points, points.dropFirst()) {
            guard b.time.isFinite, b.time > a.time, b.progress.isFinite,
                  (a.progress...1).contains(b.progress) else { return nil }
        }
        guard let t10 = TailPoint.time(at: 0.1, in: points), t10 > 0,
              let t90 = TailPoint.time(at: 0.9, in: points),
              let t95 = TailPoint.time(at: 0.95, in: points), t95 > t90 else { return nil }
        self.points = points
        self.t90 = t90
        slopeAtLift = 0.1 * t90 / t10
        // Use a short secant rather than a single (possibly repeated) position
        // sample to estimate the landing speed in units of progress per T90.
        slopeAt90 = min(0.9, 0.05 * t90 / (t95 - t90))
    }

    /// Learn from a native landing on one display. The curve ends at the final
    /// arrival: earlier frames that touched the target and later frames are
    /// dropped. A landing too short or long to be a normal tail yields no curve.
    init?(learnedFrom samples: [TailPoint], settledAt settled: Double) {
        guard settled > 0.10, settled < 1.6 else { return nil }
        let points = samples.filter { $0.time < settled && $0.progress < 1 }
        self.init(points + [TailPoint(time: settled, progress: 1)])
    }

    /// Fraction of the remaining distance covered `elapsed` seconds after lift.
    /// At 1× this is the recording. Up to 2× it blends toward a smoothed curve:
    /// a quick start, an even cruise, then the recorded final 10%.
    func progress(after elapsed: Double, rate: Double) -> Double {
        let t = elapsed * rate
        if t <= 0 { return 0 }
        guard let i = points.firstIndex(where: { $0.time >= t }), i > 0 else { return 1 }
        let a = points[i - 1], b = points[i]
        let recorded = a.progress + (b.progress - a.progress) * (t - a.time) / (b.time - a.time)
        guard rate > 1, t < t90 else { return recorded }

        // Start within the native speed range in real time, cruise, then ease into
        // the recorded tail. The area under the velocity curve must equal 0.9.
        let x = t / t90
        let rise = 0.18, fall = 0.10
        let start = min(0.9, slopeAtLift) / rate
        let cruise = (0.9 - (rise * start + fall * slopeAt90) / 2) / (1 - (rise + fall) / 2)
        let paced = start * x + (cruise - start) * integratedRamp(x, length: rise)
            + (slopeAt90 - cruise) * integratedRamp(x - (1 - fall), length: fall)
        let nativeWeight = max(0, 2 - rate)
        return paced + nativeWeight * nativeWeight * (recorded - paced)
    }

    // Integral of a velocity transition with zero acceleration at both ends.
    private func integratedRamp(_ time: Double, length: Double) -> Double {
        if time <= 0 { return 0 }
        if time >= length { return time - length / 2 }
        let u = time / length
        return length * u * u * u * (1 - u / 2)
    }

    // Normalised horizontal displacement from an original four-finger switch
    // on macOS 27.2.1. Used until this display supplies its own 1× recording.
    static let reference = TailCurve([
        (0, 0), (0.020, 0.0846), (0.040, 0.1892), (0.060, 0.2875),
        (0.080, 0.3985), (0.100, 0.4887), (0.125, 0.5759), (0.150, 0.6520),
        (0.175, 0.7156), (0.200, 0.7639), (0.250, 0.8400), (0.300, 0.8964),
        (0.350, 0.9307), (0.400, 0.9527), (0.450, 0.9691), (0.500, 0.9791),
        (0.600, 0.9904), (0.700, 0.9958), (0.750, 0.9972), (0.900, 1.0)
    ].map { TailPoint(time: $0.0, progress: $0.1) })!
}
