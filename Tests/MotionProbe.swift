import AppKit
import ApplicationServices
import QuartzCore

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func pump(for duration: Double) {
    let until = Date(timeIntervalSinceNow: duration)
    repeat {
        if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    } while Date() < until
}

private let clickTag: Int64 = 0x5357434C

private final class ClickTarget: NSView {
    var received: Double?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        ("点击测速" as NSString).draw(at: CGPoint(x: 11, y: 10), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white
        ])
    }
    override func mouseDown(with event: NSEvent) {
        if received == nil, event.cgEvent?.getIntegerValueField(.eventSourceUserData) == clickTag {
            received = CACurrentMediaTime()
        }
    }
}

private final class ClickProbe {
    let panel: NSPanel
    let target = ClickTarget()
    let screenPoint: CGPoint
    let quartzPoint: CGPoint
    let gate: CFMachPort
    let source: CFRunLoopSource
    private var lastAttempt = 0.0
    private let initialMouse = CGEvent(source: nil)?.location

    init(display: SwipeDisplay) throws {
        let bounds = display.screen.visibleFrame.insetBy(dx: 48, dy: 34)
        let pointer = NSEvent.mouseLocation
        screenPoint = CGPoint(x: min(max(pointer.x, bounds.minX), bounds.maxX),
                              y: min(max(pointer.y, bounds.minY), bounds.maxY))
        let frame = display.screen.frame, quartz = CGDisplayBounds(display.screenID)
        quartzPoint = CGPoint(x: quartz.minX + screenPoint.x - frame.minX,
                              y: quartz.minY + frame.maxY - screenPoint.y)
        let rect = CGRect(x: screenPoint.x - 38, y: screenPoint.y - 18, width: 76, height: 36)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = target
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.managed, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Only our test window can receive a tagged click. All ordinary physical
        // input passes unchanged. If routing is undecided, discard the test click.
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard let gate = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                           options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            if (type == .leftMouseDown || type == .leftMouseUp),
               event.getIntegerValueField(.eventSourceUserData) == clickTag,
               event.getIntegerValueField(.eventTargetUnixProcessID) != Int64(getpid()) { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil), let source = CFMachPortCreateRunLoopSource(nil, gate, 0) else {
            throw Failure("无法创建测试窗口的点击过滤器")
        }
        self.gate = gate
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: gate, enable: true)
        panel.orderFrontRegardless()
    }

    var isUnderPointer: Bool {
        NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == panel.windowNumber
    }

    func tryClick() {
        let now = CACurrentMediaTime()
        guard target.received == nil, now - lastAttempt > 0.020, isUnderPointer,
              CGEvent.tapIsEnabled(tap: gate) else { return }
        lastAttempt = now
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: quartzPoint, mouseButton: .left) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: clickTag)
            event.post(tap: .cghidEventTap)
        }
    }

    func close() {
        panel.orderOut(nil)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(gate)
        if let initialMouse, let last = CGEvent(source: nil)?.location,
           hypot(last.x - quartzPoint.x, last.y - quartzPoint.y) < 1 {
            CGWarpMouseCursorPosition(initialMouse)
        }
    }
}

private struct Result {
    let t90: Double
    let current: Double
    let click: Double?
}

/// Observe the outgoing end event downstream of the app and read the actual
/// target Space position. A fast T90 alone can miss a second native landing.
private final class HandoffProbe {
    let spaces: NativeSpaces
    var goal: UInt64?
    private(set) var remaining: Double?
    private var skipBelowGap: Double?
    private(set) var skippedUpdate = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(spaces: NativeSpaces) throws {
        self.spaces = spaces
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap,
                options: .defaultTap, eventsOfInterest: CGEventMask(1) << SwipeField.type.rawValue,
                callback: { _, type, event, pointer in
            if type == SwipeField.type, let pointer,
               event.getIntegerValueField(.eventSourceUserData) == SwipeField.posted {
                let probe = Unmanaged<HandoffProbe>.fromOpaque(pointer).takeUnretainedValue()
                let phase = event.getIntegerValueField(SwipeField.phase)
                if let goal = probe.goal {
                    if phase == 4 || phase == 8 { probe.remaining = probe.spaces.offset(of: goal).map(abs) }
                    if phase == 2, let threshold = probe.skipBelowGap, let x = probe.spaces.offset(of: goal),
                       abs(x) <= threshold {
                        probe.skipBelowGap = nil
                        probe.skippedUpdate = true
                        return nil
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw Failure("无法观测手势结束时的真实位置")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func watch(_ goal: UInt64, skipBelowGap: Double?) {
        self.goal = goal
        remaining = nil
        self.skipBelowGap = skipBelowGap
        skippedUpdate = false
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

private final class MotionProbe {
    let spaces: NativeSpaces
    let handoff: HandoffProbe
    let input: GestureFixture
    let engine = SwipeEngine()
    let display: SwipeDisplay
    let point: CGPoint
    let sign: Double
    let home: UInt64
    let neighbor: UInt64

    init() throws {
        guard AXIsProcessTrusted(), let spaces = NativeSpaces(), let input = GestureFixture(),
              let point = CGEvent(source: nil)?.location, let display = spaces.display(at: point) else {
            throw Failure("需要终端的辅助功能权限，以及光标所在显示器上的可读取桌面")
        }
        self.spaces = spaces; self.input = input; self.point = point; self.display = display
        handoff = try HandoffProbe(spaces: spaces)
        home = display.spaces[display.origin]
        let directions: [Double] = CommandLine.arguments.contains("--previous") ? [-1] :
            (CommandLine.arguments.contains("--next") ? [1] : [1, -1])
        guard let sign = directions.first(where: { display.neighbor(in: $0) != nil }),
              let neighbor = display.neighbor(in: sign) else { throw Failure("这个方向没有相邻桌面") }
        self.sign = sign; self.neighbor = neighbor
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
             skipOneUpdate: Bool = false, releaseSpeed: Double = 3.2) throws -> Result {
        engine.rate = rate
        let p = 0.22
        let slow = releaseSpeed <= 1
        swipe(direction, end: p, interval: slow ? 0.020 : 0.0085, hold: releaseSpeed == 0 ? 0.18 : 0.025)
        let initial = abs(spaces.offset(of: goal) ?? 0)
        handoff.watch(goal, skipBelowGap: skipOneUpdate ? initial * 0.13 : nil)
        let start = CACurrentMediaTime()
        input.send(at: point, phase: 4, progress: p * direction, delta: releaseSpeed == 0 ? 0 : direction * p / 15,
                   velocity: direction * releaseSpeed)
        guard initial > 20 else { throw Failure("无法测量松手位置") }
        var points = [TailPoint(time: 0, progress: 0)]
        var current: Double?, last = initial, reversal = 0.0
        var nextCurrentCheck = 0.0
        while CACurrentMediaTime() - start < 1.8 {
            pump(for: 0.004)
            let t = CACurrentMediaTime() - start
            let distance = abs(spaces.offset(of: goal) ?? initial)
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
            if let current, t - current > 0.035, distance <= 2,
               rate == 1 || handoff.remaining != nil, clicks == nil || clicks?.target.received != nil { break }
        }
        guard let t90 = TailPoint.time(at: 0.9, in: points), let current,
              spaces.isCurrent(goal, on: display), reversal < max(5, initial * 0.012) else {
            throw Failure("目标桌面或连续位移未通过验证")
        }
        if rate > 1 {
            if skipOneUpdate, !handoff.skippedUpdate { throw Failure("未能模拟收尾期间丢失一帧") }
            guard let remaining = handoff.remaining else {
                throw Failure("松手速度 \(releaseSpeed)，设为 \(rate)× 时未接管收尾，T90 为 \(Int(t90 * 1000)) 毫秒")
            }
            guard remaining <= 2 else {
                throw Failure("结束手势时距目标还有 \(Int(remaining.rounded())) 点，桌面会再次减速到位")
            }
            // Equal distances around 90% should still be decelerating. Allow
            // two refresh periods and two polling intervals for frame timing.
            let tolerance = 2 / Double(max(1, display.screen.maximumFramesPerSecond)) + 0.008
            guard let t85 = TailPoint.time(at: 0.85, in: points),
                  let t95 = TailPoint.time(at: 0.95, in: points),
                  t90 - t85 <= t95 - t90 + tolerance else {
                throw Failure("桌面在 90% 附近减速后再次加速")
            }
        }
        return Result(t90: t90, current: current, click: clicks?.target.received.map { $0 - start })
    }

    func run() throws {
        engine.start()
        defer { engine.stop() }
        guard engine.isRunning else { throw Failure("无法监听四指手势") }
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
        var baseline: Result?
        for rate in [1.0, 3.0, 4.0] {
            _ = try leg(sign, to: neighbor, rate: rate, clicks: nil, skipOneUpdate: rate == 4)
            guard !clicks.isUnderPointer else { throw Failure("测试窗口跟随了空间切换，无法隔离目标") }
            clicks.target.received = nil
            let result = try leg(-sign, to: home, rate: rate, clicks: clicks)
            guard let clicked = result.click else { throw Failure("目标窗口未收到点击") }
            print("\(rate)×  T90 \(Int(result.t90 * 1000)) ms  当前空间 \(Int(result.current * 1000)) ms  窗口收到点击 \(Int(clicked * 1000)) ms")
            if let baseline {
                guard result.t90 <= baseline.t90 * 1.25 / rate + 0.012,
                      let originalClick = baseline.click, clicked < originalClick * 0.8 else {
                    throw Failure("实际位移或点击等待时间未缩短")
                }
            } else { baseline = result }
        }
        var nativeSlow: [Result] = []
        for rate in [1.0, 3.0] {
            let slow = try leg(sign, to: neighbor, rate: rate, clicks: nil, releaseSpeed: 0.76)
            let held = try leg(-sign, to: home, rate: rate, clicks: nil, releaseSpeed: 0)
            print("\(rate)× 慢划 T90 \(Int(slow.t90 * 1000)) ms，停住再松手 \(Int(held.t90 * 1000)) ms")
            if rate == 1 { nativeSlow = [slow, held] }
            else {
                for (result, native) in zip([slow, held], nativeSlow) {
                    guard result.t90 <= native.t90 * 1.25 / rate + 0.012 else { throw Failure("慢划收尾仍为原速") }
                }
            }
        }
        let nativeRebound = try rebound(rate: 1)
        let selectedRebound = try rebound(rate: 4)
        guard selectedRebound <= nativeRebound * 1.25 / 4 + 0.012 else { throw Failure("回弹仍为系统原速") }
        print("取消回弹 T90 \(Int(nativeRebound * 1000)) / \(Int(selectedRebound * 1000)) ms，已回到起始桌面")
        guard let baseline else { throw Failure("缺少原速切换基准") }
        try rapidReturn(native: baseline)
    }

    func rapidReturn(native: Result) throws {
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
        guard result.t90 <= native.t90 * 1.25 / 3 + 0.012 else { throw Failure("立即回切仍为原速") }
        print("连续往返 3×，回程 T90 \(Int(result.t90 * 1000)) ms，已回到起始桌面")
    }

    func rebound(rate: Double) throws -> Double {
        engine.rate = rate
        swipe(sign, end: 0.22)
        let initial = abs(spaces.offset(of: home) ?? 0)
        handoff.watch(home, skipBelowGap: nil)
        let start = CACurrentMediaTime()
        input.send(at: point, phase: 8, progress: sign * 0.22, delta: 0)
        var points = [TailPoint(time: 0, progress: 0)]
        while CACurrentMediaTime() - start < 1.1 {
            pump(for: 0.005)
            let distance = abs(spaces.offset(of: home) ?? initial)
            points.append(TailPoint(time: CACurrentMediaTime() - start, progress: 1 - distance / max(initial, 1)))
        }
        guard initial > 20, spaces.isCurrent(home, on: display), abs(spaces.offset(of: home) ?? 100) < 2,
              let time = TailPoint.time(at: 0.9, in: points) else { throw Failure("取消手势未回到起始桌面") }
        if rate > 1, (handoff.remaining ?? .infinity) > 2 {
            throw Failure("取消事件未在原桌面到位后送出，回弹 T90 为 \(Int(time * 1000)) 毫秒")
        }
        return time
    }
}

@main enum LiveTest {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "dev.switchdesktop.prototype").isEmpty else {
            fputs("请先从菜单栏退出 Switch Desktop，避免重复处理同一手势。\n", stderr); exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        do { try MotionProbe().run() }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
