import AppKit
import ApplicationServices
import QuartzCore

private let clickTag: Int64 = 0x5357434C

final class ClickTarget: NSView {
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

final class ClickProbe {
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

/// Observe the outgoing end event downstream of the app and read the actual
/// target Space position. A fast T90 alone can miss a second native landing.
final class HandoffProbe {
    private let spaces: NativeSpaces
    enum Event: Equatable {
        case begin, nativeEnd(Int64), postedEnd(Int64)
    }

    private(set) var events: [Event] = []
    private var goal: UInt64?
    private var dropAllUpdates = false
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
            guard type == SwipeField.type, let pointer else { return Unmanaged.passUnretained(event) }
            let probe = Unmanaged<HandoffProbe>.fromOpaque(pointer).takeUnretainedValue()
            return probe.observe(event) ? Unmanaged.passUnretained(event) : nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw Failure("无法观测手势结束时的真实位置")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func observe(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(SwipeField.kind) == 23,
              event.getIntegerValueField(SwipeField.axis) == 1 else { return true }

        let phase = event.getIntegerValueField(SwipeField.phase)
        let posted = event.getIntegerValueField(.eventSourceUserData) == SwipeField.posted
        switch phase {
        case 1:
            events.append(.begin)
        case 4, 8:
            events.append(posted ? .postedEnd(phase) : .nativeEnd(phase))
            if posted, let goal { remaining = spaces.offset(of: goal).map(abs) }
        case 2 where posted:
            if dropAllUpdates {
                skippedUpdate = true
                return false
            }
            if let threshold = skipBelowGap, let goal, let offset = spaces.offset(of: goal), abs(offset) <= threshold {
                skipBelowGap = nil
                skippedUpdate = true
                return false
            }
        default:
            break
        }
        return true
    }

    func verify(_ expected: [Event], since index: Int) throws {
        let observed = events[index...]
        guard observed.elementsEqual(expected) else {
            throw Failure("事件交接异常：预期 \(expected)，实测 \(observed)")
        }
    }

    func watch(_ goal: UInt64, skipBelowGap: Double? = nil, dropAllUpdates: Bool = false) {
        self.dropAllUpdates = dropAllUpdates
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
