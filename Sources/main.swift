import AppKit
import ApplicationServices
import SwiftUI

final class MenuModel: ObservableObject {
    static let rates = 1.0...4.0
    @Published private(set) var rate: Double
    @Published var status = ""
    @Published private(set) var needsAccess = false
    let engine = SwipeEngine()
    private var permissionTimer: Timer?
    private let preferences = UserDefaults.standard

    init() {
        let saved = preferences.double(forKey: "landingRate")
        rate = saved.isFinite && Self.rates.contains(saved) ? saved : 1
        engine.rate = rate
        engine.report = { [weak self] message in
            self?.status = message
            self?.engine.trace?("status \(message)")
        }
        if CommandLine.arguments.contains("--trace") {
            setvbuf(stdout, nil, _IOLBF, 0)
            engine.trace = { print($0) }
        }
    }

    func setRate(_ newValue: Double) {
        guard newValue.isFinite else { return }
        rate = min(Self.rates.upperBound, max(Self.rates.lowerBound, newValue))
        engine.rate = rate
        preferences.set(rate, forKey: "landingRate")
    }

    func refreshAccess() {
        needsAccess = !AXIsProcessTrusted()
        engine.trace?("access \(needsAccess ? "required" : "granted"), rate \(rate)")
        if needsAccess {
            engine.stop()
            status = "等待辅助功能授权 · 当前为系统原速"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("四指切换桌面").font(.headline)
                Spacer()
                Text(model.rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("抬手后的动画速度").font(.callout)
                Slider(value: Binding(get: { model.rate }, set: model.setRate), in: MenuModel.rates)
                    .accessibilityLabel("收尾动画倍率")
                HStack {
                    Text("1×")
                    Spacer()
                    Text("4×")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsAccess {
                Button("授权辅助功能…", action: model.requestAccess)
            }
            Divider()
            HStack {
                Button("恢复原速") { model.setRate(1) }.disabled(model.rate == 1)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 290)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MenuModel()
    private let popover = NSPopover()
    private var item: NSStatusItem?

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
            button.setAccessibilityLabel("桌面切换速度")
            button.toolTip = "Switch Desktop · 桌面切换速度"
            button.target = self
            button.action = #selector(togglePanel)
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SpeedPanel(model: model))
        model.refreshAccess()
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { self.togglePanel() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayChanged),
            name: NSWorkspace.willSleepNotification, object: nil)
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
