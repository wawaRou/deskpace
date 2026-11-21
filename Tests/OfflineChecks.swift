import CoreGraphics

// Regression cases shared by CI and the live probe, without an event tap.
func runOfflineChecks() throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    func expectFailure(_ check: () throws -> Void) throws {
        do { try check() }
        catch is Failure { return }
        throw Failure("预期失败的用例仍通过")
    }

    var landing = LandingConfirmation()
    for (time, distance) in [(0.0, 100.0), (0.1, 9.0), (0.2, 5.0), (1.8, 5.0)] {
        try require(!landing.observe(at: time, distance: distance, current: true), "未到位即通过")
    }
    _ = landing.observe(at: 2, distance: 1, current: true)
    try require(!landing.observe(at: 2.1, distance: nil, current: true), "缺少末帧仍通过")
    try require(!landing.observe(at: 2.2, distance: 0, current: false), "错误空间仍通过")
    try require(!landing.observe(at: 2.3, distance: 1, current: true), "沿用了失效的到位观测")
    try require(landing.observe(at: 2.4, distance: 0, current: true), "已到位的样本未通过")

    let curve = TailCurve.reference
    // The final physical changed event is delivered before lift, but its last
    // 59 points can reach the compositor after lift. Replay both directions.
    let interval = 1.0 / 120
    for sign in [-1.0, 1.0] {
        guard let changed = CGEvent(source: nil), let end = CGEvent(source: nil) else {
            throw Failure("无法构造长划用例")
        }
        let start = 0.85 * sign
        changed.type = SwipeField.type
        changed.setDoubleValueField(SwipeField.progress, value: start)
        guard let playback = Playback(kind: .nextSpace, changed: changed, end: end, trackingOriginX: 0,
                                      originX: 834 * sign, targetX: -742 * sign, orientation: 1, curve: curve) else {
            throw Failure("无法启动长划回放")
        }
        guard case let .move(progress) = playback.step(targetX: -683 * sign, presentationTime: interval,
                                                       rate: 1.99, elapsed: interval, frameInterval: interval) else {
            throw Failure("手指最后一笔位移延后显示，收尾第一帧停住")
        }
        let measuredTravel = (progress - start) * 893 / 0.85 * sign
        let expectedTravel = 683 * curve.progress(after: interval, rate: 1.99)
        try require(abs(measuredTravel - expectedTravel) < 0.01, "收尾第一步仍按滞后的位移换算")
        playback.previous = progress
        let secondDeadline = 2 * interval
        guard case .awaitingFeedback = playback.step(targetX: -683 * sign, presentationTime: secondDeadline,
                                                     rate: 1.99, elapsed: interval, frameInterval: interval),
              case let .move(second) = playback.step(targetX: (-683 + measuredTravel) * sign,
                                                     presentationTime: secondDeadline, rate: 1.99,
                                                     elapsed: interval + 0.002, frameInterval: interval) else {
            throw Failure("同一刷新期限内收到位置反馈后未推进下一步")
        }
        let secondTravel = (second - start) * 893 / 0.85 * sign
        try require(abs(secondTravel - 683 * curve.progress(after: secondDeadline, rate: 1.99)) < 0.01,
                    "同一帧重读位置时重复推进了播放时钟")

        changed.timestamp = 1_000_000_000
        end.timestamp = changed.timestamp + 200_000
        changed.setDoubleValueField(SwipeField.deltaX, value: sign * 0.056)
        guard let cancel = Playback(kind: .rebound, changed: changed, end: end, trackingOriginX: 0,
                                    originX: 834 * sign, targetX: 834 * sign, orientation: 1, curve: curve),
              case .wait = cancel.step(targetX: 834 * sign, presentationTime: interval,
                                       rate: 4, elapsed: 0.002, frameInterval: interval),
              case let .move(returnProgress) = cancel.step(targetX: 893 * sign, presentationTime: 2 * interval,
                                                           rate: 4, elapsed: 0.010, frameInterval: interval) else {
            throw Failure("回弹与尚未显示的最后一笔跟手位移冲突")
        }
        let firstReturn = (start - returnProgress) * 893 / 0.85 * sign
        try require(abs(firstReturn - 893 * curve.progress(after: interval, rate: 4)) < 0.01,
                    "回弹把等待最后一笔跟手位移的时间合并到第一帧")
    }
    let nativeT90 = TailPoint.time(at: 0.9, in: curve.points)!
    let refresh = 1.0 / 120
    let nativeFirst = curve.progress(after: refresh, rate: 1)
    for rate in [1.5, 2, 2.5, 3, 3.5, 4] {
        let first = curve.progress(after: refresh, rate: rate)
        try require(first < 1.65 * nativeFirst, "松手后第一个刷新周期的位移远大于原速")
    }
    for hz in [60.0, 120.0] {
        let interval = 1 / hz
        var clock = PlaybackClock()
        let first = clock.advance(toward: 2 * interval, frameInterval: interval)
        try require(abs(first - interval) < 1e-9, "首次回调迟到导致合并两帧位移")
        let late = clock.advance(toward: 5 * interval, frameInterval: interval)
        try require(late > first + interval && late <= first + 1.04 * interval,
                    "跳过的刷新没有被分摊到后续帧")
        var settled = late
        for frame in 6...160 {
            settled = clock.advance(toward: Double(frame) * interval, frameInterval: interval)
        }
        try require(abs(settled - 160 * interval) < 1e-8, "短暂延迟后播放时钟一直落后")
    }
    for point in curve.points {
        let native = curve.progress(after: point.time, rate: 1)
        try require(abs(native - point.progress) < 1e-8, "原速偏离了采样曲线")
        if point.time >= nativeT90 {
            let tail = curve.progress(after: point.time / 2, rate: 2)
            try require(abs(tail - point.progress) < 1e-8, "切换的最后 10% 偏离了采样曲线")
        }
    }
    for hz in [60.0, 120.0] {
        for rate in stride(from: 1.0, through: 4.0, by: 0.125) {
            var last = 0.0, peak = 0.0
            for frame in 1...Int((curve.duration * hz / rate).rounded(.up)) {
                let t = Double(frame) / hz
                let progress = curve.progress(after: t, rate: rate)
                try require(progress >= last && progress <= 1, "调速曲线越过落点或发生倒退")
                peak = max(peak, progress - last)
                last = progress
            }
            let averageStep = 0.9 * rate / (nativeT90 * hz)
            if rate >= 2 {
                try require(peak <= 1.2 * averageStep, "加速切换的峰值帧位移超过前 90% 平均值的 1.2 倍")
            }
            try require(abs(curve.progress(after: nativeT90 / rate, rate: rate) - 0.9) < 1e-8 &&
                        last == 1, "平滑处理改变了 T90 或到位时间")
        }
    }

    for hz in [60.0, 120.0] {
        func timing(_ t90: Double) throws -> MotionTiming {
            try MotionTiming(t90: t90, frameIntervals: [1 / hz])
        }
        try timing(0.100).checkRate(native: 0.300, rate: 3)
        try timing(0.075).checkRate(native: 0.300, rate: 4)
        try MotionTiming.checkSeparation(native: 0.300, triple: 0.100, quadruple: 0.075)
        try expectFailure { try timing(0.075).checkRate(native: 0.300, rate: 3) }
        try expectFailure { try timing(0.100).checkRate(native: 0.300, rate: 4) }
        try expectFailure { try MotionTiming.checkSeparation(native: 0.300, triple: 0.075, quadruple: 0.075) }
    }

    let motionSamples = [TailPoint(time: 0, progress: 0), TailPoint(time: 0.1, progress: 0.6),
                         TailPoint(time: 0.3, progress: 1)]
    var feedback = DisplayFeedback()
    for interval in [1, 2, 4, 8, 8] {
        feedback.missedFeedback(on: 1)
        feedback.confirmedNativeLanding(on: 2, gap: 500, samples: motionSamples)
        try require(feedback.canAccelerate(on: 2), "超时影响了其他显示器")
        for _ in 0..<interval {
            try require(!feedback.canAccelerate(on: 1), "过早重试")
            feedback.confirmedNativeLanding(on: 1, gap: 500, samples: motionSamples)
        }
        try require(feedback.canAccelerate(on: 1), "位移恢复后未重试")
    }
    feedback.confirmedPlayback(on: 1)
    feedback.missedFeedback(on: 1)
    feedback.confirmedNativeLanding(on: 1, gap: 500, samples: motionSamples)
    try require(feedback.canAccelerate(on: 1), "成功调速后未重置重试间隔")
    var endpointFeedback = DisplayFeedback()
    endpointFeedback.missedFeedback(on: 1)
    for distance in [0.0, 0.5, 1.5] {
        let endpoint = TailPoint(time: 0.1, progress: 1 - distance / 500)
        endpointFeedback.confirmedNativeLanding(on: 1, gap: 500, samples: [motionSamples[0], endpoint])
        try require(!endpointFeedback.canAccelerate(on: 1), "仅到位帧解除了冷却")
    }
    endpointFeedback.confirmedNativeLanding(on: 1, gap: 500, samples: motionSamples)
    try require(endpointFeedback.canAccelerate(on: 1), "有中间位移仍未恢复")

    let variableRefresh = [1/60.0, 1/60.0, 1/120.0]
    try MotionTiming(t90: 0.093, frameIntervals: variableRefresh).checkRate(native: 0.300, rate: 4)
    try expectFailure {
        try MotionTiming(t90: 0.106, frameIntervals: variableRefresh).checkRate(native: 0.300, rate: 4)
    }

    for (origin, step, start) in [(2, 1, 0), (0, -1, 2)] {
        let route = try ProbeRoute(origin: origin, count: 3, requestedStep: step, chain: true)
        try require(route.start == start && route.step == step, "三桌面专项起点或方向错误")
        try expectFailure { _ = try ProbeRoute(origin: origin, count: 3, requestedStep: step, chain: false) }
    }
    try expectFailure { _ = try ProbeRoute(origin: 0, count: 2, requestedStep: 1, chain: true) }
    print("离线回归通过：到位、切换帧位移、实测刷新周期与倍率、同屏反馈恢复、三空间起点")
}
