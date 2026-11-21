import AppKit
import ApplicationServices
import QuartzCore

private struct Gesture {
    let display: SwipeDisplay
    let rate: Double
    let location: CGPoint
    let trackingOriginX: Double
    var changed: CGEvent?
}

private enum LandingKind: Int64 {
    case nextSpace = 4
    case rebound = 8
}

private final class Landing {
    let kind: LandingKind
    let display: SwipeDisplay
    let target: UInt64
    let gap: Double
    let pitch: Double
    let start: CFTimeInterval
    let rate: Double
    var samples = [TailPoint(time: 0, progress: 0)]
    var settledAt: Double?
    var movedAway = false

    init(kind: LandingKind, display: SwipeDisplay, target: UInt64, gap: Double, pitch: Double, rate: Double) {
        self.kind = kind
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
        let targetBefore: Double
        let expectedStep: Double
    }

    let changed: CGEvent
    let end: CGEvent
    let kind: LandingKind
    let startProgress: Double
    let orientation: Double
    let curve: TailCurve
    private let targetAtLift: Double
    private var pointsPerUnit: Double
    private var pending: Pending?
    var previous: Double

    init?(kind: LandingKind, changed: CGEvent, end: CGEvent, trackingOriginX: Double,
          originX: Double, targetX: Double, orientation: Double, curve: TailCurve) {
        // The end event has not been forwarded. The on-screen position belongs
        // to a changed event, even when the lift carries another trackpad delta.
        let progress = changed.getDoubleValueField(SwipeField.progress)
        let tracked = originX - trackingOriginX
        guard progress.isFinite, abs(progress) > 0.001, tracked * progress > 0,
              kind == .rebound || targetX * progress < 0, abs(tracked) > 2 else { return nil }
        self.kind = kind
        self.changed = changed
        self.end = end
        self.startProgress = progress
        targetAtLift = targetX
        pointsPerUnit = abs(tracked / progress)
        self.orientation = orientation
        self.previous = progress
        self.curve = curve
    }

    /// Match compositor feedback to one outstanding tracking position. Both the
    /// conversion and the decision to release depend on the real Space transform.
    func step(targetX: Double, fraction: Double, elapsed: Double, frameInterval: Double) -> Step {
        if abs(targetX) <= 1 { return .finish }
        if let pending {
            let displacement = targetX - pending.targetBefore
            if displacement * pending.expectedStep > 0, abs(displacement) >= 0.75 {
                // Measure from lift onward. A second gesture can begin while its
                // starting desktop is still moving underneath it.
                let units = previous - startProgress
                let travel = targetX - targetAtLift
                if abs(travel) >= 4, travel * units > 0, abs(units) > 0.001 {
                    pointsPerUnit = travel / units
                }
            } else if abs(pending.expectedStep) > 1.5 {
                if elapsed - pending.issued > max(0.085, frameInterval * 4) { return .unresponsive }
                // An update can be dropped or coalesced. Repeat the absolute
                // position with zero delta until the compositor acknowledges it.
                return .move(previous)
            }
            self.pending = nil
        }
        let step = targetAtLift * (1 - fraction) - targetX
        // Wait when the compositor is already ahead of this frame on the curve.
        if targetX * targetAtLift > 0, step * targetX > 0 { return .wait }
        guard abs(step) >= 0.5 else { return .wait }
        let progress = previous + step / pointsPerUnit
        guard progress.isFinite else { return .unresponsive }
        pending = Pending(issued: elapsed, targetBefore: targetX, expectedStep: step)
        return .move(progress)
    }
}

final class SwipeEngine: NSObject {
    var rate = 1.0
    var report: (String) -> Void = { _ in }
    var trace: ((String) -> Void)?
    private var feedback = DisplayFeedback()
    private let spaces = NativeSpaces()
    private let payload = SwipePayload()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var link: CADisplayLink?
    private var gesture: Gesture?
    private var landing: Landing?
    private var playback: Playback?
    private var curves: [LandingKind: [CGDirectDisplayID: TailCurve]] = [:]

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
        releasePlayback(.interrupted, proxy: proxy)
        landing = nil
        gesture = nil
        link?.invalidate()
        link = nil
    }

    private enum ReleaseReason { case arrived, interrupted }

    private func releasePlayback(_ reason: ReleaseReason, proxy: CGEventTapProxy? = nil) {
        guard let playback else { return }
        // Consume the held end before posting so later callbacks cannot release it again.
        self.playback = nil
        let end = playback.end
        if reason == .arrived || playback.previous != playback.startProgress {
            _ = payload?.update(end, phase: UInt32(playback.kind.rawValue), progress: playback.previous,
                                delta: 0, orientation: playback.orientation, keepVelocity: reason == .interrupted)
        }
        post(end, proxy: proxy)
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
            let preceding = landing
            interrupt(proxy: proxy)
            if var display = spaces?.display(at: event.location) {
                var trackingOriginX = 0.0
                // Current Space can still name the old desktop when the next
                // physical gesture already tracks from the preceding destination.
                if let preceding, preceding.display.screenID == display.screenID,
                   preceding.display.identifier == display.identifier,
                   preceding.display.spaces == display.spaces,
                   let index = display.spaces.firstIndex(of: preceding.target),
                   display.origin == preceding.display.origin || display.origin == index,
                   let offset = spaces?.offset(of: preceding.target) {
                    display.origin = index
                    trackingOriginX = offset
                }
                gesture = Gesture(display: display, rate: rate, location: event.location, trackingOriginX: trackingOriginX)
            }
        case 2:
            gesture?.changed = event.copy()
        case 4, 8:
            guard let gesture, let kind = LandingKind(rawValue: event.getIntegerValueField(SwipeField.phase)) else {
                interrupt(proxy: proxy)
                return unchanged
            }
            self.gesture = nil
            if beginLanding(gesture, end: event, kind: kind) {
                // The physical sequence is already in progress. Continue from the
                // last real position and keep the release for the final frame.
                return nil
            }
        default:
            break
        }
        return unchanged
    }

    private func beginLanding(_ gesture: Gesture, end: CGEvent, kind: LandingKind) -> Bool {
        let progress = end.getDoubleValueField(SwipeField.progress)
        let velocity = end.getDoubleValueField(SwipeField.speed)
        let display = gesture.display
        let home = display.spaces[display.origin]
        guard let originX = spaces?.offset(of: home) else { return false }
        let target: UInt64, targetX: Double
        switch kind {
        case .nextSpace:
            guard progress.isFinite, velocity.isFinite, abs(progress) > 0.001,
                  let neighbor = display.neighbor(in: progress), let x = spaces?.offset(of: neighbor),
                  display.matchesSpacePitch(abs(originX - x)), x * progress < 0 else { return false }
            // In a rapid A → B → C switch, B can still be moving toward the
            // center when the second swipe begins. Measure approach to C from
            // that starting position, which can be more than one Space away.
            let travel = originX - gesture.trackingOriginX
            let targetAtStart = x - travel
            guard abs(x) < abs(targetAtStart) else { return false }
            target = neighbor
            targetX = x
        case .rebound:
            target = home
            targetX = originX
        }
        let pitch = abs(originX - targetX)
        let gap = abs(targetX)
        guard gap > 1 else { return false }

        // The terminal phase distinguishes a switch from a cancellation even
        // if the fingers paused or reversed direction before lifting.
        if gesture.rate > 1, feedback.canAccelerate(on: display.screenID),
           let changed = gesture.changed, let savedEnd = end.copy(),
           let orientation = payload?.orientation(of: changed, progress: changed.getDoubleValueField(SwipeField.progress)) {
            changed.location = gesture.location
            savedEnd.location = gesture.location
            playback = Playback(kind: kind, changed: changed, end: savedEnd,
                                trackingOriginX: gesture.trackingOriginX, originX: originX, targetX: targetX,
                                orientation: orientation, curve: curves[kind]?[display.screenID] ?? .reference)
        }
        let run = Landing(kind: kind, display: display, target: target, gap: gap, pitch: pitch,
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
                if measured < 0.04 {
                    feedback.missedFeedback(on: run.display.screenID)
                }
                interrupt()
                report("未收到桌面位移反馈，本次由系统收尾")
                return
            case let .move(progress):
                guard let next = playback.changed.copy(),
                      payload?.update(next, phase: 2, progress: progress, delta: progress - playback.previous,
                                      orientation: playback.orientation) == true else {
                    interrupt()
                    report("当前系统未接受手势调速")
                    return
                }
                post(next)
                playback.previous = progress
            case .finish:
                releasePlayback(.arrived)
            }
        }

        let fraction = min(1, max(0, measured))
        if fraction >= run.samples.last!.progress {
            run.samples.append(TailPoint(time: elapsed, progress: fraction))
        }
        if run.kind == .nextSpace, distance > run.gap + max(10, run.pitch * 0.025) { run.movedAway = true }
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
        let id = run.display.screenID
        if run.rate > 1 {
            feedback.confirmedPlayback(on: id)
        } else if run.samples.contains(where: { $0.progress > 0 && $0.progress < 1 }) {
            feedback.confirmedNativeLanding(on: id)
        }
        if run.rate == 1, settled > 0.10, settled < 1.6 {
            let points = run.samples.filter { $0.time < settled && $0.progress < 1 }
            if let curve = TailCurve(points + [TailPoint(time: settled, progress: 1)]) {
                curves[run.kind, default: [:]][run.display.screenID] = curve
            }
        }
        if let t90 = TailPoint.time(at: 0.90, in: run.samples) {
            let ms = Int((t90 * 1000).rounded())
            let label = run.rate == 1 ? "系统原速" : "\(run.rate.formatted(.number.precision(.fractionLength(0...2))))×"
            let action = run.kind == .rebound ? "回弹" : "切换"
            report("上次\(action) \(label) · 走完 90% 位移用了 \(ms) 毫秒")
        }
        interrupt()
    }
}
