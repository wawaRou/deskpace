import AppKit
import ApplicationServices
import QuartzCore

private func pump(for duration: Double) {
    let until = Date(timeIntervalSinceNow: duration)
    repeat {
        if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    } while Date() < until
}

private struct LegMeasurement {
    let timing: MotionTiming
    var t90: Double { timing.t90 }
    let current: Double
    let click: Double?
}

private struct RoundTrip {
    let outbound: MotionTiming
    let back: MotionTiming
    let click: Double
}

// A late display frame can dominate a single short landing.
private func threeSamples<T>(_ measure: () throws -> T) rethrows -> [T] {
    try (0..<3).map { _ in try measure() }
}

private func medianOfThree<T>(_ values: [T], by key: KeyPath<T, Double>) -> T {
    precondition(values.count == 3)
    return values.sorted { $0[keyPath: key] < $1[keyPath: key] }[1]
}

private enum Delivery {
    case native, accelerated, timedOut, timedOutAfterMotion
}

private final class MotionProbe {
    let spaces: NativeSpaces
    let handoff: HandoffProbe
    let input: GestureFixture
    let engine = SwipeEngine()
    let display: SwipeDisplay
    let point: CGPoint
    let route: ProbeRoute
    var sign: Double { Double(route.step) }
    let home: UInt64
    var neighbor: UInt64 { display.spaces[route.start + route.step] }
    private var frameIntervals: [Double] = []

    init() throws {
        guard AXIsProcessTrusted(), let spaces = NativeSpaces(), let input = GestureFixture(),
              let point = CGEvent(source: nil)?.location, let display = spaces.display(at: point) else {
            throw Failure("需要终端的辅助功能权限，以及光标所在显示器上的可读取桌面")
        }
        self.spaces = spaces
        self.input = input
        self.point = point
        self.display = display
        handoff = try HandoffProbe(spaces: spaces)
        home = display.spaces[display.origin]
        let args = CommandLine.arguments
        let requestedStep = args.contains("--previous") ? -1 : (args.contains("--next") ? 1 : nil)
        route = try ProbeRoute(origin: display.origin, count: display.spaces.count,
                               requestedStep: requestedStep, chain: args.contains("--chain"))
        engine.observeFrameInterval = { [weak self] interval in self?.frameIntervals.append(interval) }
    }

    func distance(to goal: UInt64) throws -> Double {
        guard let offset = spaces.offset(of: goal) else { throw Failure("无法读取目标桌面的位置") }
        return abs(offset)
    }

    func swipe(_ direction: Double, end: Double, interval: Double = 0.0085, hold: Double = 0.025) {
        var previous = direction * 0.005
        input.send(at: point, phase: 1, progress: previous, delta: previous)
        for i in 1...15 {
            pump(for: interval)
            let p = direction * end * Double(i) / 15
            input.send(at: point, phase: 2, progress: p, delta: p - previous)
            previous = p
        }
        pump(for: hold)
    }

    func leg(_ direction: Double, to goal: UInt64, rate: Double, clicks: ClickProbe?,
             skipOneUpdate: Bool = false, releaseSpeed: Double = 3.2,
             expectedDelivery: Delivery? = nil) throws -> LegMeasurement {
        engine.rate = rate
        let p = 0.22
        let slow = releaseSpeed <= 1
        swipe(direction, end: p, interval: slow ? 0.020 : 0.0085, hold: releaseSpeed == 0 ? 0.18 : 0.025)
        let delivery = expectedDelivery ?? (rate == 1 ? .native : .accelerated)
        let initial = abs(spaces.offset(of: goal) ?? 0)
        frameIntervals.removeAll(keepingCapacity: true)
        let endsStart = handoff.events.endIndex
        let timeoutGap: Double?
        switch delivery {
        case .timedOut: timeoutGap = .infinity
        case .timedOutAfterMotion: timeoutGap = initial * 0.9
        default: timeoutGap = nil
        }
        handoff.watch(goal, skipBelowGap: skipOneUpdate ? initial * 0.13 : nil,
                      dropBelowGap: timeoutGap)
        let start = CACurrentMediaTime()
        input.send(at: point, phase: 4, progress: p * direction, delta: releaseSpeed == 0 ? 0 : direction * p / 15,
                   velocity: direction * releaseSpeed)
        guard initial > 20 else { throw Failure("无法测量松手位置") }
        var points = [TailPoint(time: 0, progress: 0)]
        var current: Double?, last = initial, reversal = 0.0
        var confirmation = LandingConfirmation()
        var landed = false
        var nextCurrentCheck = 0.0
        while CACurrentMediaTime() - start < 1.8 {
            pump(for: 0.004)
            let t = CACurrentMediaTime() - start
            let distance = try self.distance(to: goal)
            reversal = max(reversal, distance - last)
            last = distance
            points.append(TailPoint(time: t, progress: 1 - distance / initial))
            if current == nil, t >= nextCurrentCheck {
                if spaces.isCurrent(goal, on: display) { current = t }
                nextCurrentCheck = t + 0.008
            }
            clicks?.tryClick()
            // During a rapid return the system may still list the starting
            // desktop as current for both legs. Wait for the actual landing.
            let currentTarget = distance <= 2 && spaces.isCurrent(goal, on: display)
            if confirmation.observe(at: t, distance: distance, current: currentTarget),
               clicks == nil || clicks?.target.received != nil {
                landed = true
                break
            }
        }
        guard landed,
              let t90 = TailPoint.time(at: 0.9, in: points), let current else {
            throw Failure("未确认桌面到位：末次距离 \(last) 点，或未观测到目标收到点击")
        }
        let timing = try MotionTiming(t90: t90, frameIntervals: frameIntervals)
        let expectedEnd: HandoffProbe.Event = delivery == .native ? .nativeEnd(4) : .postedEnd(4)
        try handoff.verify([expectedEnd], since: endsStart)
        if let timeoutGap {
            guard handoff.skippedUpdate, let remaining = handoff.remaining,
                  remaining > 2, remaining <= timeoutGap else {
                throw Failure("未触发指定位置的超时交还")
            }
        } else if reversal >= max(5, initial * 0.012) {
            throw Failure("收尾出现反向位移")
        }
        if delivery == .accelerated {
            if skipOneUpdate, !handoff.skippedUpdate { throw Failure("未能模拟收尾期间丢失一帧") }
            guard let remaining = handoff.remaining else {
                throw Failure("松手速度 \(releaseSpeed)，设为 \(rate)× 时未接管收尾，T90 为 \(Int(t90 * 1000)) 毫秒")
            }
            guard remaining <= 2 else {
                throw Failure("结束手势时距目标还有 \(Int(remaining.rounded())) 点，桌面会再次减速到位")
            }
            // Equal distances around 90% should still be decelerating. Allow
            // two refresh periods and two polling intervals for frame timing.
            let tolerance = 2 * timing.frameInterval + 0.008
            guard let t85 = TailPoint.time(at: 0.85, in: points),
                  let t95 = TailPoint.time(at: 0.95, in: points),
                  t90 - t85 <= t95 - t90 + tolerance else {
                throw Failure("桌面在 90% 附近减速后再次加速")
            }
        }
        return LegMeasurement(timing: timing, current: current, click: clicks?.target.received.map { $0 - start })
    }

    func run() throws {
        engine.start()
        defer { engine.stop() }
        guard engine.isRunning else { throw Failure("无法监听四指手势") }
        if CommandLine.arguments.contains("--chain") { try rapidAdvance(from: route.start); return }
        let clicks = try ClickProbe(display: display)
        defer { clicks.close() }
        let deadline = CACurrentMediaTime() + 0.8
        while clicks.target.received == nil, CACurrentMediaTime() < deadline { pump(for: 0.014); clicks.tryClick() }
        guard clicks.target.received != nil else { throw Failure("当前空间的测试窗口未收到校验点击") }
        // A failure after the outbound leg still returns to the starting Space.
        defer {
            if spaces.isCurrent(neighbor, on: display) { _ = try? leg(-sign, to: home, rate: 1, clicks: nil) }
        }
        let kind = { (id: UInt64) in self.display.fullScreenSpaces.contains(id) ? "全屏" : "桌面" }
        print("\(kind(neighbor)) → \(kind(home))，同方向、同一目标窗口")
        // Neither landing kind has a recorded native curve at startup.
        let coldRebound = try medianOfThree(threeSamples { try rebound(rate: 4) }, by: \.t90)
        let coldSwitch = try medianOfThree(threeSamples {
            let outbound = try leg(sign, to: neighbor, rate: 3, clicks: nil)
            _ = try leg(-sign, to: home, rate: 4, clicks: nil, skipOneUpdate: true)
            return outbound.timing
        }, by: \.t90)

        let native = try measureRoundTrips(rate: 1, clicks: clicks)
        try coldSwitch.checkRate(native: native.outbound.t90, rate: 3)
        let triple = try measureRoundTrips(rate: 3, clicks: clicks)
        let quadruple = try measureRoundTrips(rate: 4, clicks: clicks)
        for (rate, trip) in [(3.0, triple), (4.0, quadruple)] {
            try trip.outbound.checkRate(native: native.outbound.t90, rate: rate)
            try trip.back.checkRate(native: native.back.t90, rate: rate)
            guard trip.click < native.click * 0.8 else { throw Failure("点击等待时间未缩短") }
        }
        try MotionTiming.checkSeparation(native: native.outbound.t90, triple: triple.outbound.t90, quadruple: quadruple.outbound.t90)
        try MotionTiming.checkSeparation(native: native.back.t90, triple: triple.back.t90, quadruple: quadruple.back.t90)
        var nativeSlow: [LegMeasurement] = []
        for rate in [1.0, 3.0] {
            let slow = try leg(sign, to: neighbor, rate: rate, clicks: nil, releaseSpeed: 0.76)
            let held = try leg(-sign, to: home, rate: rate, clicks: nil, releaseSpeed: 0)
            print("\(rate)× 慢划 T90 \(Int(slow.t90 * 1000)) ms，停住再松手 \(Int(held.t90 * 1000)) ms")
            if rate == 1 { nativeSlow = [slow, held] }
            else {
                for (result, native) in zip([slow, held], nativeSlow) {
                    try result.timing.checkRate(native: native.t90, rate: rate)
                }
            }
        }
        let nativeRebound = try medianOfThree(threeSamples { try rebound(rate: 1) }, by: \.t90)
        let selectedRebound = try medianOfThree(threeSamples { try rebound(rate: 4) }, by: \.t90)
        print("回弹 T90：原速 \(Int(nativeRebound.t90 * 1000)) ms，4× 预设 / 校准曲线 \(Int(coldRebound.t90 * 1000)) / \(Int(selectedRebound.t90 * 1000)) ms")
        try coldRebound.checkRate(native: nativeRebound.t90, rate: 4)
        try selectedRebound.checkRate(native: nativeRebound.t90, rate: 4)
        try feedbackRecovery(nativeReturn: native.back.t90)
        try rapidReturn(nativeT90: native.back.t90)
        if display.spaces.count >= 3 {
            let chain = try ProbeRoute(origin: display.origin, count: display.spaces.count,
                                       requestedStep: route.step, chain: true)
            try rapidAdvance(from: chain.start)
        }
    }

    func measureRoundTrips(rate: Double, clicks: ClickProbe) throws -> RoundTrip {
        let samples = try threeSamples {
            let outbound = try leg(sign, to: neighbor, rate: rate, clicks: nil)
            guard !clicks.isUnderPointer else { throw Failure("测试窗口跟随了空间切换，无法隔离目标") }
            clicks.target.received = nil
            let back = try leg(-sign, to: home, rate: rate, clicks: clicks)
            guard let clicked = back.click else { throw Failure("目标窗口未收到点击") }
            print("\(rate)×  去程 / 回程 T90 \(Int(outbound.t90 * 1000)) / \(Int(back.t90 * 1000)) ms  回程当前空间 \(Int(back.current * 1000)) ms  窗口收到点击 \(Int(clicked * 1000)) ms")
            return RoundTrip(outbound: outbound.timing, back: back.timing, click: clicked)
        }
        return RoundTrip(outbound: medianOfThree(samples.map(\.outbound), by: \.t90),
                         back: medianOfThree(samples.map(\.back), by: \.t90),
                         click: medianOfThree(samples, by: \.click).click)
    }

    func feedbackRecovery(nativeReturn: Double) throws {
        _ = try leg(sign, to: neighbor, rate: 3, clicks: nil, expectedDelivery: .timedOut)
        _ = try leg(-sign, to: home, rate: 3, clicks: nil, expectedDelivery: .native)

        // This time, allow at least 10% of the motion before dropping the remaining updates.
        _ = try leg(sign, to: neighbor, rate: 3, clicks: nil, expectedDelivery: .timedOutAfterMotion)
        _ = try leg(-sign, to: home, rate: 3, clicks: nil, expectedDelivery: .native)
        _ = try leg(sign, to: neighbor, rate: 3, clicks: nil, expectedDelivery: .native)
        let restored = try leg(-sign, to: home, rate: 3, clicks: nil)
        try restored.timing.checkRate(native: nativeReturn, rate: 3)
        print("连续两次超时后，分别经过 1 次和 2 次原速到位，同屏恢复 3×")
    }

    // Two swipes in the same direction, with the middle Space still moving
    // when tracking starts on the second swipe.
    func rapidAdvance(from start: Int) throws {
        let order = display.spaces
        let step = Int(sign)
        let middle = start + step
        let finish = middle + step

        func move(to destination: Int) throws {
            for _ in order.indices {
                guard let here = spaces.display(at: point), here.spaces == order else { throw Failure("桌面排列已变化") }
                if here.origin == destination { return }
                let direction = destination > here.origin ? 1 : -1
                _ = try leg(Double(direction), to: order[here.origin + direction], rate: 1, clicks: nil)
            }
            throw Failure("未到达测试指定的桌面")
        }

        do {
            try move(to: middle)
            let baseline = try leg(sign, to: order[finish], rate: 1, clicks: nil)
            try move(to: start)
            let eventStart = handoff.events.endIndex
            engine.rate = 3
            swipe(sign, end: 0.22)
            let gap = try distance(to: order[middle])
            let lift = CACurrentMediaTime()
            input.send(at: point, phase: 4, progress: sign * 0.22, delta: sign * 0.01, velocity: sign * 3.2)
            while try distance(to: order[middle]) > gap * 0.65, CACurrentMediaTime() - lift < 0.5 {
                pump(for: 0.003)
            }
            let remaining = try distance(to: order[middle])
            guard remaining >= gap * 0.40, remaining <= gap * 0.65,
                  spaces.isCurrent(order[start], on: display) else { throw Failure("未覆盖中间桌面仍在移动的时段") }
            let second = try leg(sign, to: order[finish], rate: 3, clicks: nil)
            try second.timing.checkRate(native: baseline.t90, rate: 3)
            try handoff.verify([.begin, .postedEnd(4), .begin, .postedEnd(4)], since: eventStart)
            print("连续同向切换三个空间，第二程原速 / 3× T90 \(Int(baseline.t90 * 1000)) / \(Int(second.t90 * 1000)) ms")
        } catch {
            pump(for: 1.8)
            try move(to: display.origin)
            throw error
        }
        try move(to: display.origin)
    }

    func rapidReturn(nativeT90: Double) throws {
        let eventsStart = handoff.events.endIndex
        engine.rate = 3
        swipe(sign, end: 0.22)
        let gap = abs(spaces.offset(of: neighbor) ?? 0)
        let start = CACurrentMediaTime()
        input.send(at: point, phase: 4, progress: sign * 0.22, delta: sign * 0.01, velocity: sign * 3.2)
        // Start the reverse swipe as the first lands, before Current Space changes.
        while abs(spaces.offset(of: neighbor) ?? gap) > gap * 0.12, CACurrentMediaTime() - start < 0.5 {
            pump(for: 0.004)
        }
        guard gap > 20, abs(spaces.offset(of: neighbor) ?? gap) <= gap * 0.12,
              spaces.isCurrent(home, on: display) else { throw Failure("未覆盖两次手势重叠的时段") }
        let result = try leg(-sign, to: home, rate: 3, clicks: nil)
        try result.timing.checkRate(native: nativeT90, rate: 3)
        try handoff.verify([.begin, .postedEnd(4), .begin, .postedEnd(4)], since: eventsStart)
        print("连续往返 3×，回程 T90 \(Int(result.t90 * 1000)) ms，已回到起始桌面")
    }

    func rebound(rate: Double) throws -> MotionTiming {
        engine.rate = rate
        swipe(sign, end: 0.22)
        let initial = abs(spaces.offset(of: home) ?? 0)
        frameIntervals.removeAll(keepingCapacity: true)
        let endsStart = handoff.events.endIndex
        handoff.watch(home)
        let start = CACurrentMediaTime()
        input.send(at: point, phase: 8, progress: sign * 0.22, delta: 0)
        var points = [TailPoint(time: 0, progress: 0)]
        while CACurrentMediaTime() - start < 1.1 {
            pump(for: 0.005)
            let distance = try self.distance(to: home)
            points.append(TailPoint(time: CACurrentMediaTime() - start, progress: 1 - distance / max(initial, 1)))
        }
        guard initial > 20, spaces.isCurrent(home, on: display), try distance(to: home) <= 2,
              let time = TailPoint.time(at: 0.9, in: points) else { throw Failure("取消手势未回到起始桌面") }
        let expectedEnd: HandoffProbe.Event = rate == 1 ? .nativeEnd(8) : .postedEnd(8)
        try handoff.verify([expectedEnd], since: endsStart)
        if rate > 1, (handoff.remaining ?? .infinity) > 2 {
            throw Failure("取消事件未在原桌面到位后送出，回弹 T90 为 \(Int(time * 1000)) 毫秒")
        }
        return try MotionTiming(t90: time, frameIntervals: frameIntervals)
    }
}

@main enum LiveTest {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        do { try runOfflineChecks() }
        catch { fputs("\(error)\n", stderr); exit(1) }
        if CommandLine.arguments.contains("--offline") { return }

        guard NSRunningApplication.runningApplications(withBundleIdentifier: "dev.switchdesktop.prototype").isEmpty else {
            fputs("请先从菜单栏退出 DeskPace，避免重复处理同一手势。\n", stderr); exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        do { try MotionProbe().run() }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
