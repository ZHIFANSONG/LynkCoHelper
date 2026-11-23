//
//  Design.swift
//  设计系统：颜色 / 圆角 / 阴影 / 字体 / 触感
//

import SwiftUI

// MARK: - 调色板

enum Palette {
    // 品牌绿（领克青绿 + 小米式荧光绿点缀）
    static let brand = Color(red: 0.00, green: 0.78, blue: 0.55)
    static let brandDeep = Color(red: 0.00, green: 0.55, blue: 0.42)

    // 深色
    static let darkBG = Color(red: 0.055, green: 0.058, blue: 0.063)
    static let darkBG2 = Color(red: 0.098, green: 0.102, blue: 0.110)
    static let darkCard = Color(red: 0.125, green: 0.129, blue: 0.137)
    static let darkCard2 = Color(red: 0.16, green: 0.165, blue: 0.175)
    static let darkLine = Color.white.opacity(0.08)
    static let darkText = Color.white
    static let darkTextSub = Color.white.opacity(0.55)

    // 浅色
    static let lightBG = Color(red: 0.96, green: 0.965, blue: 0.972)
    static let lightBG2 = Color(red: 0.925, green: 0.933, blue: 0.945)
    static let lightCard = Color.white
    static let lightLine = Color.black.opacity(0.07)
    static let lightText = Color(red: 0.08, green: 0.09, blue: 0.10)
    static let lightTextSub = Color.black.opacity(0.45)

    static func bg(_ s: ColorScheme) -> Color { s == .dark ? darkBG : lightBG }
    static func bg2(_ s: ColorScheme) -> Color { s == .dark ? darkBG2 : lightBG2 }
    static func card(_ s: ColorScheme) -> Color { s == .dark ? darkCard : lightCard }
    static func card2(_ s: ColorScheme) -> Color { s == .dark ? darkCard2 : lightBG2 }
    static func line(_ s: ColorScheme) -> Color { s == .dark ? darkLine : lightLine }
    static func text(_ s: ColorScheme) -> Color { s == .dark ? darkText : lightText }
    static func sub(_ s: ColorScheme) -> Color { s == .dark ? darkTextSub : lightTextSub }

    /// 续航条颜色：>50% 绿 / 20-50% 黄 / <20% 红
    static func range(_ pct: Double) -> Color {
        if pct > 0.5 { return brand }
        if pct > 0.2 { return Color(red: 1.0, green: 0.74, blue: 0.16) }
        return Color(red: 1.0, green: 0.29, blue: 0.29)
    }
}

// MARK: - 车漆色板（可换色）

struct PaintOption: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
}

let paintOptions: [PaintOption] = [
    .init(name: "量子灰", color: Color(red: 0.62, green: 0.66, blue: 0.72)),
    .init(name: "极地白", color: Color(red: 0.94, green: 0.95, blue: 0.96)),
    .init(name: "曜石黑", color: Color(red: 0.10, green: 0.11, blue: 0.13)),
    .init(name: "帕尔马紫", color: Color(red: 0.48, green: 0.36, blue: 0.72)),
    .init(name: "熔岩橙", color: Color(red: 0.93, green: 0.42, blue: 0.14)),
    .init(name: "深海蓝", color: Color(red: 0.13, green: 0.28, blue: 0.52)),
]

// MARK: - 卡片

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.card(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Palette.line(scheme), lineWidth: 1)
                    )
            )
            .shadow(color: scheme == .dark
                    ? Color.black.opacity(0.45)
                    : Color.black.opacity(0.07),
                    radius: scheme == .dark ? 18 : 12, x: 0, y: 8)
    }
}

// MARK: - 圆形控制按钮

struct RoundActionButton: View {
    enum Kind { case icon(String), symbol(String) }
    let title: String
    let kind: Kind
    let tint: Color
    var isLoading: Bool = false
    var isActive: Bool = false
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var pressed = false

    var body: some View {
        Button(action: {
            Haptics.tap()
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pressed = false }
            }
            action()
        }) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: isActive
                                ? [tint.opacity(0.95), tint.opacity(0.65)]
                                : [Palette.card2(scheme), Palette.card(scheme)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 62, height: 62)
                        .overlay(
                            Circle().strokeBorder(
                                isActive ? tint.opacity(0.35) : Palette.line(scheme),
                                lineWidth: 1)
                        )
                        .shadow(color: isActive ? tint.opacity(0.45) : .clear,
                                radius: 14, x: 0, y: 6)

                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(isActive ? .black : Palette.text(scheme))
                            .scaleEffect(0.85)
                    } else {
                        iconView
                            .foregroundStyle(isActive ? Color.black.opacity(0.85)
                                                      : Palette.text(scheme))
                    }
                }
                .scaleEffect(pressed ? 0.92 : 1.0)

                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.sub(scheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    @ViewBuilder private var iconView: some View {
        switch kind {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 22, weight: .semibold))
        case .icon(let name):
            Image(name)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        }
    }
}

// MARK: - 触感

enum Haptics {
    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
}

// MARK: - 顶部弹出提示

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var ok: Bool
}

struct ToastView: View {
    let toast: Toast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(toast.ok ? Palette.brand : Color.orange)
            Text(toast.text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(scheme == .dark
                           ? Color(red: 0.18, green: 0.19, blue: 0.20)
                           : Color.white)
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
        )
        .padding(.horizontal, 24)
    }
}

// MARK: - 小工具

extension View {
    /// 条件修饰
    @ViewBuilder func `if`<T: View>(_ cond: Bool, _ transform: (Self) -> T) -> some View {
        if cond { transform(self) } else { self }
    }
}
