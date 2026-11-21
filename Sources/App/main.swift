import AppKit
import Combine
import SwiftUI
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = MenuModel()
    private let popover = NSPopover()
    private let updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                       userDriverDelegate: nil)
    private var item: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var languageChanges: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies (or an old build under the legacy ID) would both hold the
        // same release event and accelerate one swipe twice.
        guard !otherInstanceIsRunning() else { return }
        NSApp.mainMenu = keyEquivalentMenu()
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
                self?.settingsWindow?.title = Self.settingsTitle(language)
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
        // Open the panel on its own when there is something to do, such as
        // granting access on first launch or after an update.
        if model.needsAccess || CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { self.togglePanel() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayChanged),
            name: NSWorkspace.willSleepNotification, object: nil)
    }

    private func otherInstanceIsRunning() -> Bool {
        let ids = Set([Bundle.main.bundleIdentifier, MenuModel.legacyBundleID].compactMap { $0 })
        let current = NSRunningApplication.current.processIdentifier
        let others = ids.flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
            .filter { $0.processIdentifier != current && !$0.isTerminated }
        guard !others.isEmpty else { return false }
        let lang = model.language
        let alert = NSAlert()
        alert.messageText = lang.text("DeskPace 已在运行", "DeskPace is already running")
        alert.informativeText = lang.text(
            "另一份 DeskPace 正在运行。请先从它的菜单栏面板点「退出」，再打开这一份。",
            "Another copy of DeskPace is running. Quit it from its menu bar panel, then open this copy again.")
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }

    /// An accessory app has no visible menu bar, but its main menu still
    /// supplies ⌘W and ⌘Q to the settings window and Sparkle's windows.
    private func keyEquivalentMenu() -> NSMenu {
        let commands = NSMenu()
        commands.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        commands.addItem(withTitle: "Quit DeskPace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = commands
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    private static func settingsTitle(_ language: AppLanguage) -> String {
        language.text("DeskPace 设置", "DeskPace Settings")
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model) { [weak self] in
                self?.updates.checkForUpdates(nil)
            })
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = Self.settingsTitle(model.language)
            // Open on the current desktop instead of switching back to an old one.
            window.collectionBehavior = .moveToActiveSpace
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
