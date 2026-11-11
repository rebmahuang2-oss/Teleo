import SwiftUI

/// 介面主題：淡綠色底、膠囊標籤、浮動卡片、圓形按鈕。
enum Theme {
    static let surface = Color(red: 0.89, green: 0.96, blue: 0.87)
    static let surfaceStrong = Color(red: 0.78, green: 0.90, blue: 0.80)
    static let accent = Color(red: 0.09, green: 0.51, blue: 0.69)
    static let accentSoft = Color(red: 0.74, green: 0.88, blue: 0.84)
    static let teal = Color(red: 0.05, green: 0.72, blue: 0.78)
    static let warn = Color(red: 0.95, green: 0.55, blue: 0.15)
    static let danger = Color(red: 0.86, green: 0.20, blue: 0.20)
    static let text = Color(red: 0.08, green: 0.16, blue: 0.12)
    static let subtext = Color(red: 0.30, green: 0.42, blue: 0.34)
}

extension View {
    /// 浮動資訊卡
    func card() -> some View {
        self
            .padding(16)
            .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    /// 膠囊底
    func pillBackground() -> some View {
        self
            .background(Theme.surface.opacity(0.96), in: Capsule())
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }
}

/// 圓形圖示按鈕
struct RoundIconButton: View {
    let systemName: String
    var tint: Color = Theme.accent
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Theme.surface.opacity(0.96), in: Circle())
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 主要大按鈕
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// 次要按鈕（淡色底）
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Theme.accentSoft.opacity(isEnabled ? 1 : 0.5), in: Capsule())
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// 膠囊分段選擇器
struct CapsuleSegmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = item.0 }
                } label: {
                    Text(item.1)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selection == item.0 ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surface.opacity(0.96), in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }
}
