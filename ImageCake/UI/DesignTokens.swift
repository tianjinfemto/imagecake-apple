import SwiftUI

// 设计令牌。与 imagecake 的 design_tokens.h 同一套深色棚拍配色：
// 画布比面板更暗，滑块与强调色只有一种蓝。深色是刻意的——修图时
// 周围环境越暗，眼睛对颜色的判断越准。

enum Tokens {
    static let bgWindow = Color(hex: 0x1E1F22)
    static let bgPanel = Color(hex: 0x252629)
    static let bgCanvas = Color(hex: 0x17181A)
    static let bgElevated = Color(hex: 0x2E3033)
    static let accent = Color(hex: 0x4A9EFF)
    static let accentHover = Color(hex: 0x6CB0FF)
    static let textPrimary = Color(hex: 0xE3E5E8)
    static let textSecondary = Color(hex: 0x9AA0A6)
    static let border = Color(hex: 0x3A3D42)
    static let groove = Color(hex: 0x404249)
    static let danger = Color(hex: 0xFF6B6B)
    static let ok = Color(hex: 0x51C878)

    static let panelWidth: CGFloat = 344
    static let corner: CGFloat = 10
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// 零碎的跨平台差异集中在这里。
///
/// 为什么不用 `#if` 直接包一行修饰符：`视图\n#if os(iOS)\n.inline\n#endif`
/// 里的 `.inline` 是链的延续，不是一条完整语句，Swift 不接受。用空操作包装
/// 之后，调用点只有一种写法。
extension View {
    /// iOS：导航栏标题用 inline；macOS：无操作。
    @ViewBuilder
    func compactNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// macOS：鼠标悬停提示；iPadOS：无操作（触摸设备没有 hover）。
    @ViewBuilder
    func macHelp(_ text: String) -> some View {
        #if os(macOS)
        self.help(text)
        #else
        self
        #endif
    }
}

/// 面板里的一张卡片：标题 + 内容，无多余装饰。
struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    // 显式 init 而不是靠 `@ViewBuilder var content` 的成员初始化：
    // 后者在不同 Swift 版本上对"属性上的 result builder"支持不一，
    // 写成显式闭包参数是确定的。
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
            content
        }
        .padding(12)
        .background(Tokens.bgElevated.opacity(0.55), in: RoundedRectangle(cornerRadius: Tokens.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.corner)
                .stroke(Tokens.border.opacity(0.7), lineWidth: 1)
        )
    }
}

/// 一行滑杆：名称 + 值 + 可拖动条。值可双击归零（修图里最常用的动作）。
struct SliderRow: View {
    let title: String
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { String(Int($0.rounded())) }
    @Binding var value: Double
    var defaultValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value == defaultValue ? Tokens.textSecondary : Tokens.accent)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Tokens.accent)
                .controlSize(.small)
                .onTapGesture(count: 2) { value = defaultValue }
        }
    }
}

/// 令牌徽标：把 AI 报告里的 `[no_model:xxx]` 原样显示，不改写成"失败"。
struct TokenBadge: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone { case neutral, good, bad }

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .neutral: return Tokens.textSecondary
        case .good: return Tokens.ok
        case .bad: return Tokens.danger
        }
    }
}

/// 忙碌遮罩：显示当前在做什么 + 一句"这一步大概多久"。
struct BusyOverlay: View {
    let title: String
    let detail: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Tokens.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Tokens.bgPanel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border, lineWidth: 1))
        }
    }
}

/// 空态：一句话说清"下一步做什么"，不放插画。
struct EmptyCanvasView: View {
    var onOpen: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(Tokens.textSecondary)
            Text("打开一张照片开始精修")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.textPrimary)
            Text("全部计算在本机完成；AI 权重按需下载，缺失时面板会点名到文件。")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("打开照片…", action: onOpen)
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgCanvas)
    }
}
