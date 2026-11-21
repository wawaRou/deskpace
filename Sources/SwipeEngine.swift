import AppKit
import ApplicationServices
import QuartzCore

private struct Gesture {
    let display: SwipeDisplay
    let rate: Double
    let location: CGPoint
    let trackingOriginX: Double
    let visited: ClosedRange<Int>
    var changed: CGEvent?
    /// When the tap received `changed`. Physical event timestamps do not
    /// share a clock with the display link on every Mac.
    var changedAt: CFTimeInterval?
}

/// The terminal `SwipeField.phase`: 4 completes a switch, 8 cancels the swipe.
enum LandingKind: Int64 {
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
    let visited: ClosedRange<Int>
    let approachingAtLift: Bool
    var samples = [TailPoint(time: 0, progress: 0)]
    var settledAt: Double?
    var movedAway = false

    init(kind: LandingKind, gesture: Gesture, target: UInt64, gap: Double, pitch: Double,
         rate: Double, approachingAtLift: Bool) {
        self.kind = kind
        self.display = gesture.display
        self.visited = gesture.visited
        self.approachingAtLift = approachingAtLift
        self.target = target
        self.gap = gap
        self.pitch = pitch
        self.rate = rate
        start = CACurrentMediaTime()
    }
}

/// Time on the landing curve. Advance only when the preceding tracking update
/// has been acknowledged, so a late callback cannot merge several frame steps.
struct PlaybackClock {
    private var time = 0.0

    mutating func advance(toward target: Double, frameInterval: Double) -> Double {
        guard frameInterval > 0, frameInterval.isFinite else {
            time = max(time, target)
            return time
        }
        let budget = frameInterval * (time == 0 ? 1 : 1.03)
        time = max(time, min(target, time + budget))
        return time
    }
}

final class Playback {
    enum Step {
        case wait, finish, unresponsive, awaitingFeedback
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
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var forwardedProgress: Double
    let orientation: Double
    let curve: TailCurve
    private let trackingAgeAtLift: Double
    private var targetAtStart: Double
    private var pointsPerUnit: Double
    private var pending: Pending?
    private var clock = PlaybackClock()
    /// The last position sent to macOS, updated when `step` returns `.move`.
    private(set) var previous: Double

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
        forwardedProgress = progress
        trackingAgeAtLift = end.timestamp >= changed.timestamp
            ? Double(end.timestamp - changed.timestamp) * 1e-9 : 0
        targetAtStart = targetX
        pointsPerUnit = abs(tracked / progress)
        self.orientation = orientation
        self.previous = progress
        self.curve = curve
    }

    /// Match compositor feedback to one outstanding tracking position. Both the
    /// conversion and the decision to release depend on the real Space transform.
    func step(targetX: Double, presentationTime: Double, rate: Double, elapsed: Double, frameInterval: Double) -> Step {
        if abs(targetX) <= DisplayFeedback.landingTolerance { return .finish }
        if previous == startProgress, targetX == targetAtStart,
           trackingAgeAtLift + elapsed < frameInterval,
           changed.getDoubleValueField(SwipeField.deltaX) != 0 {
            // The last physical delta can still arrive after this callback.
            // In a cancellation it moves against our first step, making a
            // delivered event look unacknowledged for the entire timeout.
            return .wait
        }
        // A physical changed event can reach the compositor after lift. Until
        // we send our first position, that travel belongs to finger tracking.
        if previous == startProgress, targetX != targetAtStart {
            let tracked = pointsPerUnit * startProgress + (targetX - targetAtStart)
            if tracked * startProgress > 0, abs(tracked) > 2, targetX * targetAtStart > 0 {
                pointsPerUnit = tracked / startProgress
                targetAtStart = targetX
            }
        }
        if let pending {
            let displacement = targetX - pending.targetBefore
            if displacement * pending.expectedStep > 0, abs(displacement) >= 0.75 {
                // Measure from lift onward. A second gesture can begin while its
                // starting desktop is still moving underneath it.
                let units = previous - startProgress
                let travel = targetX - targetAtStart
                if abs(travel) >= 4, travel * units > 0, abs(units) > 0.001 {
                    pointsPerUnit = travel / units
                }
            } else if abs(pending.expectedStep) > 1.5 {
                if elapsed - pending.issued > max(0.085, frameInterval * 4) { return .unresponsive }
                // An update can be dropped or coalesced. Repeat the absolute
                // position with zero delta until the compositor acknowledges it.
                return .awaitingFeedback
            }
            self.pending = nil
        }
        let playbackTime = clock.advance(toward: presentationTime, frameInterval: frameInterval)
        let fraction = curve.progress(after: playbackTime, rate: rate)
        let step = targetAtStart * (1 - fraction) - targetX
        // Wait when the compositor is already ahead of this frame on the curve.
        if targetX * targetAtStart > 0, step * targetX > 0 { return .wait }
        guard abs(step) >= 0.5 else { return .wait }
        let progress = previous + step / pointsPerUnit
        guard progress.isFinite else { return .unresponsive }
        pending = Pending(issued: elapsed, targetBefore: targetX, expectedStep: step)
        previous = progress
        return .move(progress)
    }
}

enum SwipeStatus {
    case spacesUnavailable, needsAccess, tapUnavailable, ready, atEdge
    case feedbackTimeout, playbackUnavailable, nativeRebound, landingUnconfirmed
    case completed(rebound: Bool, rate: Double, milliseconds: Int)
}

final class SwipeEngine: NSObject {
    /// A landing that has not settled by then is handed back to macOS.
    static let landingTimeout = 1.8 // seconds

    var rate = 1.0
    var report: (SwipeStatus) -> Void = { _ in }
    var trace: ((String) -> Void)?
    var observeFrameInterval: ((CFTimeInterval) -> Void)?
    private var feedback = DisplayFeedback()
    private let spaces = NativeSpaces()
    private let payload = SwipePayload()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var link: CADisplayLink?
    private var gesture: Gesture?
    private var landing: Landing?
    private var playback: Playback?
    // Keep the only copy of the end here. A null event wakes the tap after a
    // frame callback. If it bypasses a disabled tap, Dock sees no swipe.
    private var pendingEnd: CGEvent?
    private let releaseWake = CGEvent(source: nil)
    private var curves: [LandingKind: [CGDirectDisplayID: TailCurve]] = [:]

    var isRunning: Bool { tap.map(CGEvent.tapIsEnabled(tap:)) ?? false }

    // The tap holds an unretained pointer to the engine.
    deinit { stop() }

    func start() {
        guard !isRunning else { return }
        stop()
        guard spaces != nil, payload != nil, releaseWake != nil else { report(.spacesUnavailable); return }
        guard AXIsProcessTrusted() else { report(.needsAccess); return }
        let mask = (CGEventMask(1) << SwipeField.type.rawValue) | (CGEventMask(1) << CGEventType.null.rawValue)
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
            report(.tapUnavailable)
            return
        }
        self.tap = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        report(.ready)
    }

    func stop() {
        interrupt()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        // No callback can consume the wake after the tap has been removed.
        deliverPendingEnd(proxy: nil)
    }

    private func deliverPendingEnd(proxy: CGEventTapProxy?) {
        guard let end = pendingEnd else { return }
        pendingEnd = nil
        post(end, proxy: proxy)
    }

    private func wakeForPendingEnd() {
        if pendingEnd != nil, let releaseWake { post(releaseWake) }
    }

    func interrupt(proxy: CGEventTapProxy? = nil) {
        if let proxy { deliverPendingEnd(proxy: proxy) }
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
        if reason == .arrived || playback.forwardedProgress != playback.startProgress {
            _ = payload?.update(end, phase: playback.kind.rawValue, progress: playback.forwardedProgress,
                                delta: 0, orientation: playback.orientation, keepVelocity: reason == .interrupted)
        }
        if let proxy {
            post(end, proxy: proxy)
        } else {
            pendingEnd = end
            wakeForPendingEnd()
        }
    }

    private func receive(_ proxy: CGEventTapProxy, _ type: CGEventType,
                         _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let unchanged = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: tap, enable: true)
                // A previous wake may have passed while the tap was disabled.
                wakeForPendingEnd()
                interrupt()
            } else {
                stop()
                report(.needsAccess)
            }
            return unchanged
        }
        if type == .null, event.getIntegerValueField(.eventSourceUserData) == SwipeField.posted {
            deliverPendingEnd(proxy: proxy)
            return nil
        }
        guard type == SwipeField.type,
              event.getIntegerValueField(SwipeField.kind) == SwipeField.dockSwipe else { return unchanged }
        let phase = event.getIntegerValueField(SwipeField.phase)
        if event.getIntegerValueField(.eventSourceUserData) == SwipeField.posted {
            // Frame callbacks post through the HID queue. A physical begin can
            // overtake a frame even after that callback has finished. Both the
            // playback boundary and our event stamps use the same uptime clock.
            if phase == SwipeField.changed {
                guard let playback, event.timestamp >= playback.startedAt else { return nil }
                playback.forwardedProgress = event.getDoubleValueField(SwipeField.progress)
            }
            return unchanged
        }
        guard event.getIntegerValueField(SwipeField.axis) == SwipeField.horizontal else {
            // A vertical Dock gesture, such as Mission Control, must not begin
            // while the release of a horizontal swipe is still held.
            if phase == SwipeField.began { interrupt(proxy: proxy) }
            return unchanged
        }
        switch phase {
        case SwipeField.began:
            let preceding = landing
            interrupt(proxy: proxy)
            if var display = spaces?.display(at: event.location) {
                var trackingOriginX = 0.0
                var visited = display.origin...display.origin
                // Current Space can still name the old desktop when the next
                // physical gesture already tracks from the preceding destination.
                if let preceding, preceding.display.screenID == display.screenID,
                   preceding.display.identifier == display.identifier,
                   preceding.display.spaces == display.spaces,
                   let index = display.spaces.firstIndex(of: preceding.target),
                   preceding.visited.contains(display.origin) || display.origin == index,
                   let offset = spaces?.offset(of: preceding.target) {
                    display.origin = index
                    trackingOriginX = offset
                    visited = min(preceding.visited.lowerBound, index)...max(preceding.visited.upperBound, index)
                }
                gesture = Gesture(display: display, rate: rate, location: event.location,
                                  trackingOriginX: trackingOriginX, visited: visited)
            }
        case SwipeField.changed:
            gesture?.changed = event.copy()
            gesture?.changedAt = CACurrentMediaTime()
            if link == nil, let gesture, gesture.rate > 1 { startFrames(on: gesture.display) }
        case LandingKind.nextSpace.rawValue, LandingKind.rebound.rawValue:
            guard let gesture, let kind = LandingKind(rawValue: phase) else {
                interrupt(proxy: proxy)
                return unchanged
            }
            self.gesture = nil
            if beginLanding(gesture, end: event, kind: kind) {
                // The physical sequence is already in progress. Continue from the
                // last real position and keep the release for the final frame.
                return nil
            }
            if landing == nil { interrupt() }
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
        let approaching: Bool
        switch kind {
        case .nextSpace:
            guard progress.isFinite, velocity.isFinite, abs(progress) > 0.001,
                  let neighbor = display.neighbor(in: progress), let x = spaces?.offset(of: neighbor),
                  display.matchesSpacePitch(abs(originX - x)) else { return false }
            // In a rapid A → B → C switch, B can still be moving toward the
            // center when the second swipe begins. Measure approach to C from
            // that starting position, which can be more than one Space away.
            let travel = originX - gesture.trackingOriginX
            let targetAtStart = x - travel
            approaching = x * progress < 0 && abs(x) < abs(targetAtStart)
            // During A → B → C → B the reverse swipe can start before B
            // crosses center. Let macOS resolve that leg, keeping its target
            // for the next handoff without learning its atypical curve.
            guard approaching || gesture.trackingOriginX != 0 else { return false }
            target = neighbor
            targetX = x
        case .rebound:
            approaching = true
            // At an outer edge macOS rubber-bands the current Space. Its
            // displacement does not follow the linear two-Space tracking scale.
            guard display.neighbor(in: originX) != nil else {
                if abs(originX) > 1 { report(.atEdge) }
                return false
            }
            target = home
            targetX = originX
        }
        let pitch = abs(originX - targetX)
        let gap = abs(targetX)
        guard gap > 1 else { return false }

        // The terminal phase distinguishes a switch from a cancellation even
        // if the fingers paused or reversed direction before lifting.
        if approaching, gesture.rate > 1, feedback.canAccelerate(on: display.screenID),
           let changed = gesture.changed, let savedEnd = end.copy(),
           let orientation = payload?.orientation(of: changed, progress: changed.getDoubleValueField(SwipeField.progress)) {
            changed.location = gesture.location
            savedEnd.location = gesture.location
            playback = Playback(kind: kind, changed: changed, end: savedEnd,
                                trackingOriginX: gesture.trackingOriginX, originX: originX, targetX: targetX,
                                orientation: orientation, curve: curves[kind]?[display.screenID] ?? .reference)
        }
        if let playback {
            // The release stays held until the landing finishes. Hand it back
            // even if display link callbacks stop, for example when the display sleeps.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingTimeout + 0.2) { [weak self] in
                guard let self, self.playback === playback else { return }
                self.interrupt()
                self.report(.landingUnconfirmed)
            }
        }
        let run = Landing(kind: kind, gesture: gesture, target: target, gap: gap, pitch: pitch,
                          rate: playback != nil ? gesture.rate : 1, approachingAtLift: approaching)
        trace?("release rate=\(run.rate) p=\(progress) v=\(velocity) gap=\(gap) pitch=\(pitch)")
        landing = run
        if link == nil { startFrames(on: display) }
        return playback != nil
    }

    private func startFrames(on display: SwipeDisplay) {
        let link = display.screen.displayLink(target: self, selector: #selector(frame(_:)))
        let maximum = Float(max(1, display.screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func post(_ event: CGEvent, proxy: CGEventTapProxy? = nil) {
        event.setIntegerValueField(.eventSourceUserData, value: SwipeField.posted)
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        if let proxy { event.tapPostEvent(proxy) }
        else { event.post(tap: .cghidEventTap) }
    }

    private func advance(_ playback: Playback, for run: Landing, position: Double,
                         deadline: Double, interval: Double, allowRetry: Bool) {
        let now = CACurrentMediaTime()
        let previousProgress = playback.previous
        let step = playback.step(targetX: position, presentationTime: max(now, deadline) - run.start,
                                 rate: run.rate, elapsed: now - run.start, frameInterval: interval)
        let progress: Double, delta: Double
        switch step {
        case .awaitingFeedback:
            let delay = min(0.002, interval / 4)
            if allowRetry, delay > 0, now + delay < deadline {
                // The previous position can become visible just after the
                // callback. Recheck once before this presentation deadline.
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.landing === run, self.playback === playback,
                          self.link?.targetTimestamp == deadline, CACurrentMediaTime() < deadline,
                          let current = self.spaces?.offset(of: run.target) else { return }
                    self.advance(playback, for: run, position: current, deadline: deadline,
                                 interval: interval, allowRetry: false)
                }
                return
            }
            progress = playback.previous
            delta = 0
        case let .move(next):
            progress = next
            delta = next - previousProgress
        case .wait: return
        case .finish:
            releasePlayback(.arrived)
            return
        case .unresponsive:
            feedback.missedFeedback(on: run.display.screenID)
            interrupt()
            report(.feedbackTimeout)
            return
        }
        guard let next = playback.changed.copy(),
              payload?.update(next, phase: SwipeField.changed, progress: progress, delta: delta,
                              orientation: playback.orientation) == true else {
            interrupt()
            report(.playbackUnavailable)
            return
        }
        post(next)
    }

    @objc private func frame(_ sender: CADisplayLink) {
        guard let run = landing else {
            // Establish the refresh cadence during tracking. A long hold
            // releases the link until movement resumes or the fingers lift.
            if let changedAt = gesture?.changedAt, CACurrentMediaTime() - changedAt > 0.5 {
                sender.invalidate()
                link = nil
            }
            return
        }
        guard let position = spaces?.offset(of: run.target) else {
            interrupt()
            return
        }
        let frameInterval = sender.targetTimestamp - sender.timestamp
        let elapsed = CACurrentMediaTime() - run.start
        let distance = abs(position)
        if distance > DisplayFeedback.landingTolerance { observeFrameInterval?(frameInterval) }
        let measured = 1 - distance / run.gap
        if let trace { trace("frame t=\(elapsed) gap=\(distance)") }
        if let playback {
            advance(playback, for: run, position: position, deadline: sender.targetTimestamp,
                    interval: frameInterval, allowRetry: true)
            guard landing === run else { return }
        }

        let fraction = min(1, max(0, measured))
        if fraction >= run.samples.last?.progress ?? 0 {
            run.samples.append(TailPoint(time: elapsed, progress: fraction))
        }
        if run.kind == .nextSpace, distance > run.gap + max(10, run.pitch * 0.025) { run.movedAway = true }
        if distance <= DisplayFeedback.landingTolerance {
            if run.settledAt == nil { run.settledAt = elapsed }
            if playback == nil, spaces?.isCurrent(run.target, on: run.display) == true {
                finish(run)
                return
            }
            if playback == nil, run.movedAway,
               spaces?.isCurrent(run.display.spaces[run.display.origin], on: run.display) == true {
                interrupt()
                report(.nativeRebound)
                return
            }
        } else {
            run.settledAt = nil
        }
        if elapsed > Self.landingTimeout {
            interrupt()
            report(.landingUnconfirmed)
        }
    }

    private func finish(_ run: Landing) {
        guard let settled = run.settledAt else { return }
        let id = run.display.screenID
        if run.rate > 1 {
            feedback.confirmedPlayback(on: id)
        } else if run.approachingAtLift {
            feedback.confirmedNativeLanding(on: id, gap: run.gap, samples: run.samples)
        }
        if run.rate == 1, run.approachingAtLift,
           let curve = TailCurve(learnedFrom: run.samples, settledAt: settled) {
            curves[run.kind, default: [:]][run.display.screenID] = curve
        }
        if let t90 = TailPoint.time(at: 0.90, in: run.samples) {
            let ms = Int((t90 * 1000).rounded())
            report(.completed(rebound: run.kind == .rebound, rate: run.rate, milliseconds: ms))
        }
        interrupt()
    }
}
