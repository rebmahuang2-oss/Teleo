import SwiftUI

/// 介面主題：淡綠色調、毛玻璃質感的浮動卡片／膠囊／按鈕。
///
/// 整體風格改成「玻璃透明」：不再用不透明色塊當底，而是系統的模糊材質
/// （.ultraThinMaterial）疊一層淡淡的主題色染色，邊緣再加一圈由亮到淡的
/// 高光線條，模擬玻璃邊緣反光的感覺。因為這個 App 大部分浮動元件都是蓋在
/// 地圖上面，玻璃模糊的效果會把底下的地圖顏色透出來，比原本的不透明淡綠色
/// 色塊更有層次、也更接近 Apple 原生地圖／天氣 App 的質感。
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

    /// 玻璃邊緣高光的漸層：上緣亮、往下漸漸透明，模擬光線從上方打在玻璃邊上的感覺。
    static var glassEdge: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.65), Color.white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// 玻璃感容器：系統模糊材質 + 主題色染色 + 邊緣高光 + 柔和陰影。
    /// `tint` 預設用 Theme.surface（淡綠），不透明度越低、玻璃感越重。
    func glass<S: InsettableShape>(_ shape: S, tint: Color = Theme.surface, tintOpacity: Double = 0.45,
                                    shadowRadius: CGFloat = 10, shadowY: CGFloat = 3) -> some View {
        self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(tint.opacity(tintOpacity))
                }
            }
            .overlay { shape.stroke(Theme.glassEdge, lineWidth: 1) }
            .shadow(color: .black.opacity(0.16), radius: shadowRadius, y: shadowY)
    }

    /// 浮動資訊卡
    func card() -> some View {
        self
            .padding(16)
            .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), shadowRadius: 14, shadowY: 5)
    }

    /// 膠囊底
    func pillBackground() -> some View {
        self.glass(Capsule())
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
                .glass(Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 主要大按鈕：維持實心飽和色，是畫面上最主要的行動呼籲，
/// 跟其他玻璃感元件形成對比，讓使用者一眼找到「該按哪個」。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .overlay(
                Capsule().stroke(Color.white.opacity(configuration.isPressed ? 0.1 : 0.25), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// 次要按鈕（玻璃底，加一圈主題色邊框，跟主要按鈕的實心做出區別）
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .glass(Capsule(), tint: tint, tintOpacity: isEnabled ? 0.18 : 0.08, shadowRadius: 6, shadowY: 2)
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

extension Theme {
    /// 給設定頁等 Sheet／Form 用的底色漸層，跟卡片的玻璃色調一致，
    /// 搭配 `.scrollContentBackground(.hidden)` 使用，讓 Form 的每一列
    /// 用 `.listRowBackground(.ultraThinMaterial)` 變成毛玻璃卡片飄在上面。
    static var sheetBackground: some View {
        LinearGradient(colors: [surface, surfaceStrong], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
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
                        .foregroundStyle(selection == item.0 ? .white : Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if selection == item.0 {
                                Capsule().fill(Theme.accent)
                                    .shadow(color: Theme.accent.opacity(0.4), radius: 6, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glass(Capsule())
    }
}
