import Foundation

enum AppLanguage: String {
    case chinese = "zh-Hans"
    case english = "en"

    static var preferred: Self {
        let supported = [Self.english.rawValue, Self.chinese.rawValue]
        let first = Bundle.preferredLocalizations(from: supported).first
        return first == Self.chinese.rawValue ? .chinese : .english
    }

    func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }

    func description(of status: SwipeStatus) -> String {
        switch status {
        case .spacesUnavailable: return text("此系统的桌面接口暂不可用", "Desktop switching is unavailable on this system.")
        case .needsAccess: return text("等待辅助功能授权 · 当前为系统原速", "Grant Accessibility access to adjust the speed.")
        case .tapUnavailable: return text("系统尚未允许调节手势", "macOS hasn’t allowed swipe adjustments.")
        case .ready: return text("等待四指横移", "Ready for a four-finger swipe.")
        case .atEdge: return text("已到桌面边缘 · 系统原速回弹", "At the last desktop. Bouncing back at system speed.")
        case .feedbackTimeout: return text("未收到桌面位移反馈，本次由系统收尾", "Desktop position unavailable. macOS finished the swipe.")
        case .playbackUnavailable: return text("当前系统未接受手势调速", "macOS couldn’t apply the selected speed.")
        case .nativeRebound: return text("已回到原桌面 · 系统原速回弹", "Returned to the starting desktop at system speed.")
        case .landingUnconfirmed: return text("本次未确认到达目标桌面", "Couldn’t confirm arrival at the target desktop.")
        case let .completed(rebound, rate, ms):
            let speed = rate == 1 ? text("系统原速", "system speed") : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
            let action = rebound ? text("回弹", "bounce") : text("切换", "switch")
            return text("上次\(action) \(speed) · 走完 90% 位移用了 \(ms) 毫秒",
                        "Last \(action) at \(speed) · 90% of the distance in \(ms) ms")
        }
    }
}
