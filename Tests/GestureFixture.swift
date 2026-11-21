import ApplicationServices
import Darwin
import Foundation

/// A reproducible horizontal swipe for the live test. This code is excluded
/// from the app. Samples use the same progress and velocity in both directions.
/// It writes the event with its own field numbers instead of `SwipeField`, so
/// a wrong number in the app cannot also slip into the gestures that test it.
final class GestureFixture {
    private enum Raw {
        static let type = CGEventType(rawValue: 30)!
        static let kind = CGEventField(rawValue: 110)!
        static let axis = CGEventField(rawValue: 123)!
        static let progress = CGEventField(rawValue: 124)!
        static let deltaX = CGEventField(rawValue: 125)!
        static let speed = CGEventField(rawValue: 129)!
        static let speedX = CGEventField(rawValue: 130)!
        static let phase = CGEventField(rawValue: 132)!
        static let companionPhase = CGEventField(rawValue: 134)!
    }

    private typealias MakeSwipe = @convention(c) (CFAllocator?, UInt64, UInt32, UInt16, Double, Double, Double, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias MakeVelocity = @convention(c) (CFAllocator?, UInt64, Double, Double, Double, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    private typealias SetInt = @convention(c) (CFTypeRef, UInt32, Int) -> Void
    private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void

    private let makeSwipe: MakeSwipe
    private let makeVelocity: MakeVelocity
    private let append: Append
    private let setInt: SetInt
    private let attach: Attach
    private let io, sky: UnsafeMutableRawPointer

    init?() {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { dlclose(sky); return nil }
        guard let swipe = dlsym(io, "IOHIDEventCreateDockSwipeEvent"),
              let velocity = dlsym(io, "IOHIDEventCreateVelocityEvent"), let append = dlsym(io, "IOHIDEventAppendEvent"),
              let setInt = dlsym(io, "IOHIDEventSetIntegerValue"), let attach = dlsym(sky, "SLEventSetIOHIDEvent") else {
            dlclose(io); dlclose(sky); return nil
        }
        self.io = io
        self.sky = sky
        makeSwipe = unsafeBitCast(swipe, to: MakeSwipe.self)
        makeVelocity = unsafeBitCast(velocity, to: MakeVelocity.self)
        self.append = unsafeBitCast(append, to: Append.self)
        self.setInt = unsafeBitCast(setInt, to: SetInt.self)
        self.attach = unsafeBitCast(attach, to: Attach.self)
    }

    deinit { dlclose(io); dlclose(sky) }

    func send(at point: CGPoint, phase: UInt32, progress: Double, delta: Double, velocity: Double = 0) {
        let stamp = mach_absolute_time()
        guard let event = CGEvent(source: nil),
              let raw = makeSwipe(nil, stamp, phase == 1 && progress > 0 ? 4 : 0, 1,
                                  -progress, -delta, 0, phase << 24)?.takeRetainedValue() else { return }
        setInt(raw, (23 << 16) + 5, 3)
        if phase == 4, let axis = makeVelocity(nil, stamp, -velocity, -velocity, 0, 0)?.takeRetainedValue() {
            append(raw, axis, 0)
        }
        event.type = Raw.type
        event.location = point
        event.setIntegerValueField(Raw.kind, value: 23)
        event.setIntegerValueField(Raw.axis, value: 1)
        event.setIntegerValueField(Raw.phase, value: Int64(phase))
        event.setIntegerValueField(Raw.companionPhase, value: Int64(phase))
        event.setDoubleValueField(Raw.progress, value: progress)
        event.setDoubleValueField(Raw.deltaX, value: delta)
        event.setDoubleValueField(Raw.speed, value: velocity)
        event.setDoubleValueField(Raw.speedX, value: velocity)
        attach(event, raw)
        event.post(tap: .cghidEventTap)
    }
}
