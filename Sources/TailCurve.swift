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
/// Seeking on its time axis changes playback speed without changing the shape.
struct TailCurve {
    let points: [TailPoint]
    var duration: Double { points[points.count - 1].time }

    init?(_ points: [TailPoint]) {
        guard points.count >= 3, points.first?.time == 0, points.first?.progress == 0,
              points.last?.progress == 1 else { return nil }
        for (a, b) in zip(points, points.dropFirst()) {
            guard b.time.isFinite, b.time > a.time, b.progress.isFinite,
                  (a.progress...1).contains(b.progress) else { return nil }
        }
        self.points = points
    }

    func progress(after elapsed: Double, rate: Double) -> Double {
        let t = elapsed * rate
        if t <= 0 { return 0 }
        guard let i = points.firstIndex(where: { $0.time >= t }), i > 0 else { return 1 }
        let a = points[i - 1], b = points[i]
        return a.progress + (b.progress - a.progress) * (t - a.time) / (b.time - a.time)
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
