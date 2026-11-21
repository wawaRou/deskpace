import CoreGraphics
import Darwin
import Foundation

// Observed on physical, horizontal four-finger swipes. The CGEvent carries
// absolute progress as a Double, a per-update delta, and two phase fields.
// None of these numbers are public. Tests/GestureFixture.swift keeps its own copy.
enum SwipeField {
    /// Quartz event type of Dock gestures.
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

    /// `kind` of a Dock swipe, the same number as its IOHIDEvent type.
    static let dockSwipe: Int64 = 23
    /// `axis` of a left or right swipe.
    static let horizontal: Int64 = 1
    /// `phase` values before release. The two terminal values are `LandingKind`.
    static let began: Int64 = 1
    static let changed: Int64 = 2
    /// Source user data on events DeskPace posts itself: "SWDT" in ASCII,
    /// from the project's earlier name. It never leaves this process.
    static let posted: Int64 = 0x53574454
}

/// IOHIDEvent fields are addressed as (event type << 16) | field index.
private enum HIDField {
    static let dockSwipe: UInt32 = 23
    static let progress = dockSwipe << 16 | 2
    /// Despite its name, this carries the per-update delta of a swipe.
    static let positionX = dockSwipe << 16 | 3
    static let positionY = dockSwipe << 16 | 4
    static let velocity: UInt32 = 9
    static let velocityX = velocity << 16
    static let velocityY = velocity << 16 | 1
}

/// Keep the Quartz event and its attached trackpad swipe in agreement.
/// Natural scrolling can give the two coordinate systems opposite signs.
final class SwipePayload {
    private typealias Read = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void
    private typealias Clone = @convention(c) (CFAllocator?, CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Kind = @convention(c) (CFTypeRef) -> UInt32
    private typealias SetPhase = @convention(c) (CFTypeRef, UInt32) -> Void
    private typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void
    private typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double
    private typealias SetTime = @convention(c) (CFTypeRef, UInt64) -> Void
    private typealias Child = @convention(c) (CFTypeRef, UInt32, UInt32) -> Unmanaged<CFTypeRef>?

    private let read: Read, attach: Attach, clone: Clone, kind: Kind
    private let setPhase: SetPhase, setFloat: SetFloat, setTime: SetTime, child: Child
    private let getFloat: GetFloat
    private let libraries: [UnsafeMutableRawPointer]

    init?() {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            dlclose(sky)
            return nil
        }
        guard let read = dlsym(sky, "SLEventCopyIOHIDEvent"), let attach = dlsym(sky, "SLEventSetIOHIDEvent"),
              let clone = dlsym(io, "IOHIDEventCreateCopy"), let kind = dlsym(io, "IOHIDEventGetType"),
              let setPhase = dlsym(io, "IOHIDEventSetPhase"), let setFloat = dlsym(io, "IOHIDEventSetFloatValue"),
              let getFloat = dlsym(io, "IOHIDEventGetFloatValue"),
              let setTime = dlsym(io, "IOHIDEventSetTimeStamp"), let child = dlsym(io, "IOHIDEventGetEventWithOptions") else {
            dlclose(io)
            dlclose(sky)
            return nil
        }
        libraries = [sky, io]
        self.read = unsafeBitCast(read, to: Read.self)
        self.attach = unsafeBitCast(attach, to: Attach.self)
        self.clone = unsafeBitCast(clone, to: Clone.self)
        self.kind = unsafeBitCast(kind, to: Kind.self)
        self.setPhase = unsafeBitCast(setPhase, to: SetPhase.self)
        self.setFloat = unsafeBitCast(setFloat, to: SetFloat.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloat.self)
        self.setTime = unsafeBitCast(setTime, to: SetTime.self)
        self.child = unsafeBitCast(child, to: Child.self)
    }

    deinit { for library in libraries.reversed() { dlclose(library) } }

    func orientation(of event: CGEvent, progress: Double) -> Double? {
        guard let source = read(event)?.takeRetainedValue(), kind(source) == HIDField.dockSwipe,
              abs(progress) > 0.0001 else { return nil }
        let raw = getFloat(source, HIDField.progress)
        guard raw.isFinite, abs(abs(raw) - abs(progress)) < 0.001, raw != 0 else { return nil }
        return raw.sign == progress.sign ? 1 : -1
    }

    /// Rewrite both copies of the swipe. `keepVelocity` leaves the lift speed in
    /// an interrupted release, so macOS can finish that landing at its own pace.
    func update(_ event: CGEvent, phase: Int64, progress: Double, delta: Double,
                orientation: Double, keepVelocity: Bool = false) -> Bool {
        guard let source = read(event)?.takeRetainedValue(), kind(source) == HIDField.dockSwipe,
              let copy = clone(nil, source)?.takeRetainedValue() else { return false }
        setPhase(copy, UInt32(phase))
        setTime(copy, mach_absolute_time())
        setFloat(copy, HIDField.progress, orientation * progress)
        setFloat(copy, HIDField.positionX, orientation * delta)
        setFloat(copy, HIDField.positionY, 0)
        if !keepVelocity, let velocity = child(copy, HIDField.velocity, 0)?.takeUnretainedValue() {
            setFloat(velocity, HIDField.velocityX, 0)
            setFloat(velocity, HIDField.velocityY, 0)
        }
        attach(event, copy)
        event.setIntegerValueField(SwipeField.phase, value: phase)
        event.setIntegerValueField(SwipeField.companionPhase, value: phase)
        event.setDoubleValueField(SwipeField.progress, value: progress)
        event.setDoubleValueField(SwipeField.deltaX, value: delta)
        event.setDoubleValueField(SwipeField.deltaY, value: 0)
        if !keepVelocity {
            event.setDoubleValueField(SwipeField.speed, value: 0)
            event.setDoubleValueField(SwipeField.speedX, value: 0)
        }
        return true
    }
}
