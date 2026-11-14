import SwiftUI

/// 浮在子母畫面視窗裡的內容。拉長成一條細長的狀態列（320×76），
/// 風格比照主畫面的膠囊卡片：深色底、teal 強調色、圓角分層，
/// 而不是隨便貼一塊黑底文字上去。
struct PiPOverlayWidgetView: View {
    @ObservedObject var overlay: PiPOverlay

    private var accent: Color { overlay.isPaused ? Color(red: 0.95, green: 0.55, blue: 0.15) : Color(red: 0.20, green: 0.85, blue: 0.80) }

    var body: some View {
        HStack(spacing: 12) {
            // 左：狀態圖示，外圈隨狀態發光，右下角疊一顆狀態小圓點
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 46, height: 46)
                Image(systemName: overlay.isPaused ? "pause.fill" : "location.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 46, height: 46)
                Circle()
                    .fill(accent)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
            }

            // 中：標題／進度文字／進度條
            VStack(alignment: .leading, spacing: 4) {
                Text(overlay.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(overlay.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                if let progress = overlay.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(accent)
                                .frame(width: max(4, geo.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右：大字時速 + 暫停/繼續按鈕
            VStack(alignment: .trailing, spacing: 6) {
                Text(overlay.speedText)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .lineLimit(1)
                Button {
                    NotificationCenter.default.post(name: .teleoPiPToggle, object: nil)
                } label: {
                    Image(systemName: overlay.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.09), Color.black],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1),
            alignment: .top
        )
    }
}

extension Notification.Name {
    /// 浮動視窗上的播放／暫停按鈕被按下
    static let teleoPiPToggle = Notification.Name("teleoPiPToggle")
}
