import SwiftUI

/// 浮在子母畫面視窗裡的內容，空間很小（260×90），只放得下重點資訊。
struct PiPOverlayWidgetView: View {
    @ObservedObject var overlay: PiPOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(overlay.isPaused ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(overlay.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    NotificationCenter.default.post(name: .teleoPiPToggle, object: nil)
                } label: {
                    Image(systemName: overlay.isPaused ? "play.fill" : "pause.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .bold))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }
            Text(overlay.subtitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }
}

extension Notification.Name {
    /// 浮動視窗上的播放／暫停按鈕被按下
    static let teleoPiPToggle = Notification.Name("teleoPiPToggle")
}
