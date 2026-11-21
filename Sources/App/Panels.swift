import ServiceManagement
import SwiftUI

struct SpeedPanel: View {
    @ObservedObject var model: MenuModel
    let openSettings: () -> Void

    var body: some View {
        let lang = model.language
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(lang.text("四指切换桌面", "Four-finger desktop swipes")).font(.headline)
                Spacer()
                Text(model.rate.rateText)
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(lang.text("松手后的动画速度", "Animation speed after release")).font(.callout)
                Slider(value: Binding(get: { model.rate }, set: model.setRate), in: MenuModel.rates)
                    .accessibilityLabel(lang.text("收尾动画倍率", "Animation speed"))
                    .accessibilityValue(model.rate.rateText)
                HStack {
                    Text(MenuModel.rates.lowerBound.rateText)
                    Spacer()
                    Text(MenuModel.rates.upperBound.rateText)
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let status = model.status {
                Text(lang.description(of: status)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsAccess {
                if model.promptedForAccess {
                    Text(lang.text("如果系统设置里的 DeskPace 已开启，这里仍在等待，请用「−」移除所有 DeskPace 条目，再点下面的按钮，重新开启 DeskPace。",
                                   "If DeskPace is already on in System Settings but this panel is still waiting, remove every DeskPace entry with −, click the button below, and turn DeskPace on again."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.promptedForAccess
                       ? lang.text("打开辅助功能设置…", "Open Accessibility Settings…")
                       : lang.text("授权辅助功能…", "Grant Accessibility Access…"),
                       action: model.requestAccess)
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
            // A pending approval still counts as on, so it can be turned off here.
            Toggle(lang.text("登录时启动", "Launch at Login"), isOn: Binding(
                get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
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
            Toggle(lang.text("自动检查更新", "Check for Updates Automatically"), isOn: Binding(
                get: { model.checksAutomatically },
                set: model.setChecksAutomatically
            ))
            .toggleStyle(.switch)
            Button(lang.text("检查更新…", "Check for Updates…"), action: checkForUpdates)
                .disabled(!model.canCheckForUpdates)
        }
        .formStyle(.grouped)
        .frame(width: 370)
        .fixedSize(horizontal: false, vertical: true)
    }
}
