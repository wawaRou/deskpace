import CoreGraphics
import Darwin
import Foundation

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
        guard let source = read(event)?.takeRetainedValue(), kind(source) == 23,
              abs(progress) > 0.0001 else { return nil }
        let raw = getFloat(source, (23 << 16) + 2)
        guard raw.isFinite, abs(abs(raw) - abs(progress)) < 0.001, raw != 0 else { return nil }
        return raw.sign == progress.sign ? 1 : -1
    }

    func update(_ event: CGEvent, phase: UInt32, progress: Double, delta: Double,
                orientation: Double, keepVelocity: Bool) -> Bool {
        guard let source = read(event)?.takeRetainedValue(), kind(source) == 23,
              let copy = clone(nil, source)?.takeRetainedValue() else { return false }
        let dockSwipe: UInt32 = 23 << 16
        setPhase(copy, phase)
        setTime(copy, mach_absolute_time())
        setFloat(copy, dockSwipe + 2, orientation * progress)
        setFloat(copy, dockSwipe + 3, orientation * delta)
        setFloat(copy, dockSwipe + 4, 0)
        if !keepVelocity, let velocity = child(copy, 9, 0)?.takeUnretainedValue() {
            let velocityX: UInt32 = 9 << 16
            setFloat(velocity, velocityX, 0)
            setFloat(velocity, velocityX + 1, 0)
        }
        attach(event, copy)
        return true
    }
}
