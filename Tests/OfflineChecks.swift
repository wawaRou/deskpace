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
    print("离线回归通过：到位、实测刷新周期与倍率、同屏反馈恢复、三空间起点")
}
