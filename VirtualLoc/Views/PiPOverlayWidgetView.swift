import SwiftUI

/// 浮在子母畫面視窗裡「純顯示」的部分：狀態圖示、標題／字幕、進度條、時速。
/// 風格比照主畫面的膠囊卡片：深色底、teal 強調色、圓角分層，
/// 而不是隨便貼一塊黑底文字上去。
///
/// 暫停/繼續、上一點、下一點那三顆按鈕「不」在這個檔案裡——它們是原生 UIButton，
/// 直接加在 `PiPOverlay.swift` 的 `PiPCallViewController` 的 UIKit 畫面上，
/// 疊在這層 SwiftUI 畫面之上。細節跟原因（為什麼按鈕不能用 SwiftUI 的 Button
/// 做）見 `PiPCallViewController` 開頭的註解。
/// 這裡右下角特意留白（時速文字對齊上方、下面用 Spacer 撐開），就是留給那幾顆
/// 原生按鈕疊上去的位置，排版時兩邊要對著改。
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

            // 右：大字時速，貼齊上緣。下面特意留白，是原生按鈕疊上去的位置。
            VStack(alignment: .trailing, spacing: 0) {
                Text(overlay.speedText)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
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
