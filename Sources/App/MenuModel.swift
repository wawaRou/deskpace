import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import Sparkle

final class MenuModel: ObservableObject {
    static let rates = 1.0...4.0
    /// The slider snaps to this step so a value shown as 1× is exactly 1×.
    static let rateStep = 0.05
    /// Bundle ID of v0.1.6 and earlier. Its speed and language fill in any
    /// setting this version has not saved yet.
    static let legacyBundleID = "dev.switchdesktop.prototype"

    private enum Key {
        static let rate = "landingRate"
        static let language = "appLanguage"
    }

    @Published private(set) var rate: Double
    @Published private(set) var status: SwipeStatus?
    @Published var language: AppLanguage {
        didSet { preferences.set(language.rawValue, forKey: Key.language) }
    }
    @Published private(set) var needsAccess = false
    /// Set after the first request. macOS shows its dialog only once per
    /// launch, so later requests also open System Settings.
    @Published private(set) var promptedForAccess = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var checksAutomatically = false
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginError: String?
    let engine = SwipeEngine()
    private var permissionTimer: Timer?
    private var updater: SPUUpdater?
    private let preferences = UserDefaults.standard

    init() {
        if let legacy = preferences.persistentDomain(forName: Self.legacyBundleID) {
            for key in [Key.rate, Key.language] where preferences.object(forKey: key) == nil {
                if let value = legacy[key] { preferences.set(value, forKey: key) }
            }
        }
        language = preferences.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .preferred
        let saved = preferences.double(forKey: Key.rate)
        rate = saved.isFinite && Self.rates.contains(saved) ? saved : 1
        engine.rate = rate
        engine.report = { [weak self] message in
            guard let self else { return }
            self.status = message
            self.engine.trace?("status \(AppLanguage.chinese.description(of: message))")
            // The tap can be disabled after access is revoked while running.
            if case .needsAccess = message, !self.needsAccess {
                DispatchQueue.main.async { self.refreshAccess() }
            }
        }
        if CommandLine.arguments.contains("--trace") {
            setvbuf(stdout, nil, _IOLBF, 0)
            engine.trace = { print($0) }
        }
    }

    private static func snapped(_ value: Double) -> Double {
        let steps = ((value - rates.lowerBound) / rateStep).rounded()
        return min(rates.upperBound, rates.lowerBound + steps * rateStep)
    }

    func observeUpdates(_ updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$checksAutomatically)
    }

    func setChecksAutomatically(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func setRate(_ newValue: Double) {
        guard newValue.isFinite else { return }
        rate = Self.snapped(min(Self.rates.upperBound, max(Self.rates.lowerBound, newValue)))
        engine.rate = rate
        preferences.set(rate, forKey: Key.rate)
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
        loginError = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        refreshLoginStatus()
        if enabled && loginStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if enabled {
                if loginStatus != .enabled { try service.register() }
            } else if loginStatus == .enabled || loginStatus == .requiresApproval {
                try service.unregister()
            }
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = service.status
    }

    /// Start the event tap when possible. Keep polling while access is missing
    /// or macOS has not yet allowed the tap, so either recovers without a relaunch.
    /// Missing private interfaces cannot recover, so they stop the polling.
    func refreshAccess() {
        needsAccess = !AXIsProcessTrusted()
        engine.trace?("access \(needsAccess ? "required" : "granted"), rate \(rate)")
        if needsAccess {
            engine.stop()
            status = .needsAccess
        } else {
            engine.start()
        }
        var recoverable = true
        if case .spacesUnavailable = status { recoverable = false }
        if needsAccess || (!engine.isRunning && recoverable) {
            if permissionTimer == nil {
                let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAccess() }
                RunLoop.main.add(timer, forMode: .common)
                permissionTimer = timer
            }
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    func requestAccess() {
        // The prompt also adds DeskPace back to the list after it was removed.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if promptedForAccess {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        }
        promptedForAccess = true
        refreshAccess()
    }
}
