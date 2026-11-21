import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI
import Sparkle

final class MenuModel: ObservableObject {
    static let rates = 1.0...4.0
    @Published private(set) var rate: Double
    @Published private(set) var status: SwipeStatus?
    @Published var language: AppLanguage {
        didSet { preferences.set(language.rawValue, forKey: "appLanguage") }
    }
    @Published private(set) var needsAccess = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginError: String?
    let engine = SwipeEngine()
    private var permissionTimer: Timer?
    private let preferences = UserDefaults.standard

    init() {
        if let legacy = preferences.persistentDomain(forName: "dev.switchdesktop.prototype") {
            for key in ["landingRate", "appLanguage"] where preferences.object(forKey: key) == nil {
                if let value = legacy[key] { preferences.set(value, forKey: key) }
            }
        }
        language = preferences.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .preferred
        let saved = preferences.double(forKey: "landingRate")
        rate = saved.isFinite && Self.rates.contains(saved) ? saved : 1
        engine.rate = rate
        engine.report = { [weak self] message in
            self?.status = message
            self?.engine.trace?("status \(AppLanguage.chinese.description(of: message))")
        }
        if CommandLine.arguments.contains("--trace") {
            setvbuf(stdout, nil, _IOLBF, 0)
            engine.trace = { print($0) }
        }
    }

    func observeUpdates(_ updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func setRate(_ newValue: Double) {
        guard newValue.isFinite else { return }
        rate = min(Self.rates.upperBound, max(Self.rates.lowerBound, newValue))
        engine.rate = rate
        preferences.set(rate, forKey: "landingRate")
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

    func refreshAccess() {
        needsAccess = !AXIsProcessTrusted()
        engine.trace?("access \(needsAccess ? "required" : "granted"), rate \(rate)")
        if needsAccess {
            engine.stop()
            status = .needsAccess
            if permissionTimer == nil {
                let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAccess() }
                RunLoop.main.add(timer, forMode: .common)
                permissionTimer = timer
            }
        } else {
            engine.start()
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccess()
    }
}

struct SpeedPanel: View {
    @ObservedObject var model: MenuModel
    let openSettings: () -> Void

    var body: some View {
        let lang = model.language
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(lang.text("四指切换桌面", "Four-finger desktop swipes")).font(.headline)
                Spacer()
                Text(model.rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(lang.text("抬手后的动画速度", "Animation speed after release")).font(.callout)
                Slider(value: Binding(get: { model.rate }, set: model.setRate), in: MenuModel.rates)
                    .accessibilityLabel(lang.text("收尾动画倍率", "Animation speed"))
                HStack {
                    Text("1×")
                    Spacer()
                    Text("4×")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let status = model.status {
                Text(lang.description(of: status)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsAccess {
                Button(lang.text("授权辅助功能…", "Grant Accessibility Access…"), action: model.requestAccess)
            }
            Divider()
            HStack {
                Button(lang.text("恢复原速", "Reset Speed")) { model.setRate(1) }.disabled(model.rate == 1)
                Spacer()
                Button(lang.text("设置…", "Settings…"), action: openSettings)
                Button(lang.text("退出", "Quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 290)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsView: View {
    @ObservedObject var model: MenuModel
    let checkForUpdates: () -> Void

    var body: some View {
        let lang = model.language
        Form {
            Picker(lang.text("语言", "Language"), selection: $model.language) {
                Text("简体中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            Toggle(lang.text("登录时启动", "Launch at Login"), isOn: Binding(
                get: { model.loginStatus == .enabled },
                set: model.setLaunchAtLogin
            ))
            .toggleStyle(.switch)
            if model.loginStatus == .requiresApproval {
                Button(lang.text("在系统设置中允许登录时启动…", "Allow in System Settings…")) {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else if let error = model.loginError {
                Text(lang.text("更改登录项失败：", "Couldn’t change the login item: ") + error)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(lang.text("检查更新…", "Check for Updates…"), action: checkForUpdates)
                .disabled(!model.canCheckForUpdates)
        }
        .formStyle(.grouped)
        .frame(width: 370)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = MenuModel()
    private let popover = NSPopover()
    private let updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                       userDriverDelegate: nil)
    private var item: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var languageChanges: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        if let button = item.button {
            if let url = Bundle.main.url(forResource: "logo-menubar", withExtension: "svg"),
               let logo = NSImage(contentsOf: url), logo.size.width > 0 {
                let width: CGFloat = 22
                logo.size = NSSize(width: width, height: width * logo.size.height / logo.size.width)
                button.image = logo
            } else {
                button.image = NSImage(systemSymbolName: "rectangle.2.swap", accessibilityDescription: nil)
            }
            button.image?.isTemplate = true
            languageChanges = model.$language.sink { [weak self, weak button] language in
                let label = language.text("桌面切换速度", "Desktop swipe speed")
                button?.setAccessibilityLabel(label)
                button?.toolTip = "DeskPace · " + label
                self?.settingsWindow?.title = language.text("DeskPace 设置", "DeskPace Settings")
            }
            button.target = self
            button.action = #selector(togglePanel)
        }
        popover.behavior = .transient
        updates.startUpdater()
        model.observeUpdates(updates.updater)
        popover.contentViewController = NSHostingController(rootView: SpeedPanel(model: model) { [weak self] in
            self?.showSettings()
        })
        model.refreshAccess()
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { self.togglePanel() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayChanged),
            name: NSWorkspace.willSleepNotification, object: nil)
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model) { [weak self] in
                self?.updates.checkForUpdates(nil)
            })
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = model.language.text("DeskPace 设置", "DeskPace Settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshLoginStatus()
    }

    @objc private func displayChanged() { model.engine.interrupt() }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item?.button, let controller = popover.contentViewController {
            model.refreshAccess()
            // AppKit anchors the popover using its size at presentation time.
            controller.view.layoutSubtreeIfNeeded()
            popover.contentSize = controller.view.fittingSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            controller.view.window?.makeKey()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { model.engine.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
