import AppKit
import ApplicationServices
import QuartzCore

// Observed on physical, horizontal four-finger swipes. The CGEvent carries
// absolute progress as a Double, a per-update delta, and two phase fields.
enum SwipeField {
    static let type = CGEventType(rawValue: 30)!
    static let kind = CGEventField(rawValue: 110)!
    static let axis = CGEventField(rawValue: 123)!
    static let progress = CGEventField(rawValue: 124)!
    static let deltaX = CGEventField(rawValue: 125)!
    static let deltaY = CGEventField(rawValue: 126)!
    static let speed = CGEventField(rawValue: 129)!
    static let speedX = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!
    static let companionPhase = CGEventField(rawValue: 134)!
    static let posted: Int64 = 0x53574454
}

private struct Gesture {
    let display: SwipeDisplay
    let rate: Double
    let location: CGPoint
    var changed: CGEvent?
}

private final class Landing {
    let display: SwipeDisplay
    let target: UInt64
    let gap: Double
    let pitch: Double
    let start: CFTimeInterval
    let rate: Double
    var samples = [TailPoint(time: 0, progress: 0)]
    var settledAt: Double?
    var movedAway = false

    init(display: SwipeDisplay, target: UInt64, gap: Double, pitch: Double, rate: Double) {
        self.display = display
        self.target = target
        self.gap = gap
        self.pitch = pitch
        self.rate = rate
        start = CACurrentMediaTime()
    }
}

private final class Playback {
    enum Step {
        case wait, finish, unresponsive
        case move(Double)
    }

    private struct Pending {
        let issued: Double
        let travelBefore: Double
        let expectedStep: Double
    }

    let changed: CGEvent
    let end: CGEvent
    let startProgress: Double
    let orientation: Double
    let curve: TailCurve
    private let direction: Double
    private let pitch: Double
    private let initialGap: Double
    private var pointsPerUnit: Double
    private var pending: Pending?
    var previous: Double

    init?(changed: CGEvent, end: CGEvent, originX: Double, targetX: Double, orientation: Double, curve: TailCurve) {
        // The end event has not been forwarded. The on-screen position belongs
        // to a changed event, even when the lift carries another trackpad delta.
        let progress = changed.getDoubleValueField(SwipeField.progress)
        guard progress.isFinite, abs(progress) > 0.001, originX * progress > 0,
              targetX * progress < 0, abs(originX) > 2 else { return nil }
        self.changed = changed
        self.end = end
        self.startProgress = progress
        direction = progress > 0 ? 1 : -1
        pitch = abs(originX - targetX)
        initialGap = abs(targetX)
        pointsPerUnit = abs(originX / progress)
        self.orientation = orientation
        self.previous = progress
        self.curve = curve
    }

    /// Match compositor feedback to one outstanding tracking position. Both the
    /// conversion and the decision to release depend on the real Space transform.
    func step(targetX: Double, fraction: Double, elapsed: Double, frameInterval: Double) -> Step {
        let remaining = -direction * targetX
        let travel = pitch - remaining
        if let pending {
            let displacement = travel - pending.travelBefore
            if displacement * pending.expectedStep > 0, abs(displacement) >= 0.75, travel > 0 {
                pointsPerUnit = travel / abs(previous)
            } else if abs(pending.expectedStep) > 1.5, abs(remaining) > 1 {
                if elapsed - pending.issued > max(0.085, frameInterval * 4) { return .unresponsive }
                // An update can be dropped or coalesced. Repeat the absolute
                // position with zero delta until the compositor acknowledges it.
                return .move(previous)
            }
            self.pending = nil
        }
        if abs(remaining) <= 1 { return .finish }

        let amount: Double
        if fraction >= 1 || remaining < 0 {
            amount = abs(previous) + remaining / pointsPerUnit
        } else {
            // A slightly late initial sample can put us ahead of the curve.
            let desiredGap = initialGap * (1 - fraction)
            amount = max(abs(previous), (pitch - desiredGap) / pointsPerUnit)
        }
        guard amount.isFinite, amount > 0 else { return .unresponsive }
        let step = (amount - abs(previous)) * pointsPerUnit
        guard abs(step) >= 0.5 else { return .wait }
        pending = Pending(issued: elapsed, travelBefore: travel, expectedStep: step)
        return .move(amount * direction)
    }
}

final class SwipeEngine: NSObject {
    var rate = 1.0
    var report: (String) -> Void = { _ in }
    var trace: ((String) -> Void)?
    private var rejectedDisplay: Set<CGDirectDisplayID> = []
    private let spaces = NativeSpaces()
    private let payload = SwipePayload()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var link: CADisplayLink?
    private var gesture: Gesture?
    private var landing: Landing?
    private var playback: Playback?
    private var curves: [CGDirectDisplayID: TailCurve] = [:]

    var isRunning: Bool { tap.map(CGEvent.tapIsEnabled(tap:)) ?? false }

    func start() {
        guard !isRunning else { return }
        stop()
        guard spaces != nil, payload != nil else { report("此系统的桌面接口暂不可用"); return }
        guard AXIsProcessTrusted() else { report("需要辅助功能权限"); return }
        let mask = CGEventMask(1) << SwipeField.type.rawValue
        let callback: CGEventTapCallBack = { proxy, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<SwipeEngine>.fromOpaque(pointer).takeUnretainedValue()
            return engine.receive(proxy, type, event)
        }
        // Holding a release here stopped the real desktop for the exact duration
        // of the hold. Later taps can receive a separate copy after recognition.
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            report("系统尚未允许调节手势")
            return
        }
        self.tap = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        report("等待四指横移")
    }

    func stop() {
        interrupt()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    func interrupt(proxy: CGEventTapProxy? = nil) {
        if let playback {
            // If another gesture begins partway through the tail, release at
            // the last position we sent and let the native recognizer decide.
            let end = playback.end.copy() ?? playback.end
            if playback.previous != playback.startProgress {
                _ = setPosition(end, playback.previous, delta: 0, phase: 4,
                                orientation: playback.orientation, keepVelocity: true)
            }
            post(end, proxy: proxy)
        }
        playback = nil
        landing = nil
        gesture = nil
        link?.invalidate()
        link = nil
    }

    private func receive(_ proxy: CGEventTapProxy, _ type: CGEventType,
                         _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let unchanged = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interrupt()
            if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return unchanged
        }
        guard type == SwipeField.type,
              event.getIntegerValueField(.eventSourceUserData) != SwipeField.posted,
              event.getIntegerValueField(SwipeField.kind) == 23,
              event.getIntegerValueField(SwipeField.axis) == 1 else { return unchanged }
        switch event.getIntegerValueField(SwipeField.phase) {
        case 1:
            interrupt(proxy: proxy)
            if let display = spaces?.display(at: event.location) {
                gesture = Gesture(display: display, rate: rate, location: event.location)
            }
        case 2:
            gesture?.changed = event.copy()
        case 4:
            guard let gesture else { return unchanged }
            self.gesture = nil
            if beginLanding(gesture, end: event) {
                // The physical sequence is already in progress. Continue from the
                // last real position and keep the release for the final frame.
                return nil
            }
        case 8:
            trace?("cancel p=\(event.getDoubleValueField(SwipeField.progress))")
            interrupt(proxy: proxy)
            report("已取消切换 · 系统原速回弹")
        default:
            break
        }
        return unchanged
    }

    private func beginLanding(_ gesture: Gesture, end: CGEvent) -> Bool {
        let progress = end.getDoubleValueField(SwipeField.progress)
        let velocity = end.getDoubleValueField(SwipeField.speed)
        let display = gesture.display
        guard progress.isFinite, velocity.isFinite, abs(progress) > 0.001,
              let target = display.neighbor(in: progress),
              let originX = spaces?.offset(of: display.spaces[display.origin]),
              let targetX = spaces?.offset(of: target) else { return false }
        let pitch = abs(originX - targetX)
        let gap = abs(targetX)
        guard display.matchesSpacePitch(pitch), gap > 4, gap < pitch,
              targetX * progress < 0 else { return false }

        // Leave indecisive releases and reversals entirely to the native recognizer.
        let committed = abs(progress) > 0.08 && progress * velocity > 0 && abs(velocity) > 1.5
        if gesture.rate > 1, committed, !rejectedDisplay.contains(display.screenID),
           let changed = gesture.changed, let savedEnd = end.copy(),
           let orientation = payload?.orientation(of: end, progress: progress) {
            changed.location = gesture.location
            savedEnd.location = gesture.location
            playback = Playback(changed: changed, end: savedEnd, originX: originX, targetX: targetX,
                                orientation: orientation, curve: curves[display.screenID] ?? .reference)
        }
        let run = Landing(display: display, target: target, gap: gap, pitch: pitch,
                          rate: playback != nil ? gesture.rate : 1)
        trace?("release rate=\(run.rate) p=\(progress) v=\(velocity) gap=\(gap) pitch=\(pitch)")
        landing = run
        let link = display.screen.displayLink(target: self, selector: #selector(frame(_:)))
        let maximum = Float(max(1, display.screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
        return playback != nil
    }

    private func post(_ event: CGEvent, proxy: CGEventTapProxy? = nil) {
        event.setIntegerValueField(.eventSourceUserData, value: SwipeField.posted)
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        if let proxy { event.tapPostEvent(proxy) }
        else { event.post(tap: .cghidEventTap) }
    }

    private func setPosition(_ event: CGEvent, _ position: Double, delta: Double, phase: UInt32,
                             orientation: Double, keepVelocity: Bool = false) -> Bool {
        guard payload?.update(event, phase: phase, progress: position, delta: delta,
                              orientation: orientation, keepVelocity: keepVelocity) == true else { return false }
        event.setIntegerValueField(SwipeField.phase, value: Int64(phase))
        event.setIntegerValueField(SwipeField.companionPhase, value: Int64(phase))
        event.setDoubleValueField(SwipeField.progress, value: position)
        event.setDoubleValueField(SwipeField.deltaX, value: delta)
        event.setDoubleValueField(SwipeField.deltaY, value: 0)
        if !keepVelocity {
            event.setDoubleValueField(SwipeField.speed, value: 0)
            event.setDoubleValueField(SwipeField.speedX, value: 0)
        }
        return true
    }

    @objc private func frame(_ sender: CADisplayLink) {
        guard let run = landing, let position = spaces?.offset(of: run.target) else {
            interrupt()
            return
        }
        let elapsed = CACurrentMediaTime() - run.start
        let distance = abs(position)
        let measured = 1 - distance / run.gap
        if let trace { trace("frame t=\(elapsed) gap=\(distance)") }
        if let playback {
            let fraction = playback.curve.progress(after: max(elapsed, sender.targetTimestamp - run.start), rate: run.rate)
            switch playback.step(targetX: position, fraction: fraction, elapsed: elapsed,
                                 frameInterval: sender.targetTimestamp - sender.timestamp) {
            case .wait:
                break
            case .unresponsive:
                if measured < 0.04 { rejectedDisplay.insert(run.display.screenID) }
                interrupt()
                report("未收到桌面位移反馈，本次由系统收尾")
                return
            case let .move(progress):
                guard let next = playback.changed.copy(),
                      setPosition(next, progress, delta: progress - playback.previous, phase: 2, orientation: playback.orientation) else {
                    interrupt()
                    report("当前系统未接受手势调速")
                    return
                }
                post(next)
                playback.previous = progress
            case .finish:
                let end = playback.end.copy() ?? playback.end
                if setPosition(end, playback.previous, delta: 0, phase: 4, orientation: playback.orientation) {
                    post(end)
                } else {
                    post(playback.end)
                }
                self.playback = nil
            }
        }

        let fraction = min(1, max(0, measured))
        if fraction >= run.samples.last!.progress {
            run.samples.append(TailPoint(time: elapsed, progress: fraction))
        }
        if distance > run.gap + max(10, run.pitch * 0.025) { run.movedAway = true }
        if distance <= 1.5 {
            if run.settledAt == nil { run.settledAt = elapsed }
            if playback == nil, spaces?.isCurrent(run.target, on: run.display) == true {
                finish(run)
                return
            }
            if playback == nil, run.movedAway,
               spaces?.isCurrent(run.display.spaces[run.display.origin], on: run.display) == true {
                interrupt()
                report("已回到原桌面 · 系统原速回弹")
                return
            }
        } else {
            run.settledAt = nil
        }
        if elapsed > 1.8 {
            interrupt()
            report("本次未确认到达目标桌面")
        }
    }

    private func finish(_ run: Landing) {
        guard let settled = run.settledAt else { return }
        if run.rate == 1, settled > 0.10, settled < 1.6 {
            let points = run.samples.filter { $0.time < settled && $0.progress < 1 }
            if let curve = TailCurve(points + [TailPoint(time: settled, progress: 1)]) {
                curves[run.display.screenID] = curve
            }
        }
        if let t90 = TailPoint.time(at: 0.90, in: run.samples) {
            let ms = Int((t90 * 1000).rounded())
            let label = run.rate == 1 ? "系统原速" : "\(run.rate.formatted(.number.precision(.fractionLength(0...2))))×"
            report("上次\(label) · 走完 90% 位移用了 \(ms) 毫秒")
        }
        interrupt()
    }
}
