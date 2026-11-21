// Regression cases shared by CI and the live probe, without an event tap.
func runOfflineChecks() throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    func expectFailure(_ check: () throws -> Void) throws {
        do { try check() }
        catch is Failure { return }
        throw Failure("错误的倍率样本仍通过")
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
        let checks = MotionChecks(frameInterval: 1 / hz)
        try checks.checkRate(0.100, native: 0.300, rate: 3)
        try checks.checkRate(0.075, native: 0.300, rate: 4)
        try checks.checkSeparation(native: 0.300, triple: 0.100, quadruple: 0.075)
        try expectFailure { try checks.checkRate(0.075, native: 0.300, rate: 3) }
        try expectFailure { try checks.checkRate(0.100, native: 0.300, rate: 4) }
        try expectFailure { try checks.checkSeparation(native: 0.300, triple: 0.075, quadruple: 0.075) }
    }

    var feedback = DisplayFeedback()
    for interval in [1, 2, 4, 8, 8] {
        feedback.missedFeedback(on: 1)
        feedback.confirmedNativeLanding(on: 2)
        try require(feedback.canAccelerate(on: 2), "超时影响了其他显示器")
        for _ in 0..<interval {
            try require(!feedback.canAccelerate(on: 1), "过早重试")
            feedback.confirmedNativeLanding(on: 1)
        }
        try require(feedback.canAccelerate(on: 1), "位移恢复后未重试")
    }
    feedback.confirmedPlayback(on: 1)
    feedback.missedFeedback(on: 1)
    feedback.confirmedNativeLanding(on: 1)
    try require(feedback.canAccelerate(on: 1), "成功调速后未重置重试间隔")
    print("离线回归通过：末帧到位、实测倍率和同屏反馈恢复")
}
