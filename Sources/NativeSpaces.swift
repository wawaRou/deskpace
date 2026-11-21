import AppKit
import CoreGraphics
import Darwin

/// A snapshot at gesture begin. Space order includes full-screen applications.
struct SwipeDisplay {
    let screen: NSScreen
    let identifier: String
    let screenID: CGDirectDisplayID
    let spaces: [UInt64]
    let fullScreenSpaces: Set<UInt64>
    let origin: Int

    func neighbor(in direction: Double) -> UInt64? {
        let next = origin + (direction > 0 ? 1 : -1)
        return spaces.indices.contains(next) ? spaces[next] : nil
    }

    func matchesSpacePitch(_ pitch: Double) -> Bool {
        let screens = NSScreen.screensHaveSeparateSpaces ? [screen] : NSScreen.screens
        return screens.contains { pitch > $0.frame.width * 0.7 && pitch < $0.frame.width * 1.5 }
    }
}

/// These read-only functions are looked up at launch because they are private.
/// The third argument of SLSSpaceGetTransform receives space flags, not an error code.
final class NativeSpaces {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias CopyDisplays = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias GetTransform = @convention(c) (UInt32, UInt64, UnsafeMutablePointer<Int32>) -> CGAffineTransform

    private let library: UnsafeMutableRawPointer
    private let connection: UInt32
    private let copyDisplays: CopyDisplays
    private let getTransform: GetTransform

    init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let library = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let connection = dlsym(library, "SLSMainConnectionID"),
              let displays = dlsym(library, "SLSCopyManagedDisplaySpaces"),
              let transform = dlsym(library, "SLSSpaceGetTransform") else {
            dlclose(library)
            return nil
        }
        self.library = library
        self.connection = unsafeBitCast(connection, to: Connection.self)()
        copyDisplays = unsafeBitCast(displays, to: CopyDisplays.self)
        getTransform = unsafeBitCast(transform, to: GetTransform.self)
    }

    deinit { dlclose(library) }

    private func rows() -> [[String: Any]] {
        copyDisplays(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value
    }

    func display(at quartzPoint: CGPoint) -> SwipeDisplay? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { screen in
            guard let id = Self.screenID(screen) else { return false }
            return CGDisplayBounds(id).contains(quartzPoint)
        }), let id = Self.screenID(screen) else { return nil }

        let displays = rows()
        let row: [String: Any]?
        if !NSScreen.screensHaveSeparateSpaces || (displays.count == 1 && screens.count == 1) {
            row = displays.first
        } else {
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let key = uuid.flatMap { CFUUIDCreateString(nil, $0) as String? }
            row = displays.first {
                guard let name = $0["Display Identifier"] as? String else { return false }
                return name.caseInsensitiveCompare(key ?? "") == .orderedSame
                    || (name == "Main" && id == CGMainDisplayID())
            }
        }
        guard let row, let identifier = row["Display Identifier"] as? String,
              let list = row["Spaces"] as? [[String: Any]],
              let current = row["Current Space"] as? [String: Any],
              let currentID = current["ManagedSpaceID"] as? NSNumber else { return nil }
        let ids = list.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        guard ids.count == list.count, let origin = ids.firstIndex(of: currentID.uint64Value) else { return nil }
        let fullscreen = list.filter { ($0["type"] as? NSNumber)?.intValue == 4 }
            .compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        return SwipeDisplay(screen: screen, identifier: identifier, screenID: id, spaces: ids,
                            fullScreenSpaces: Set(fullscreen), origin: origin)
    }

    func isCurrent(_ space: UInt64, on display: SwipeDisplay) -> Bool {
        guard let row = rows().first(where: { $0["Display Identifier"] as? String == display.identifier }),
              let current = row["Current Space"] as? [String: Any] else { return false }
        return (current["ManagedSpaceID"] as? NSNumber)?.uint64Value == space
    }

    func offset(of space: UInt64) -> Double? {
        var flags: Int32 = 0
        let matrix = getTransform(connection, space, &flags)
        guard matrix.tx.isFinite, abs(matrix.a - 1) < 0.001, abs(matrix.d - 1) < 0.001,
              abs(matrix.b) < 0.001, abs(matrix.c) < 0.001 else { return nil }
        return Double(matrix.tx)
    }
}
