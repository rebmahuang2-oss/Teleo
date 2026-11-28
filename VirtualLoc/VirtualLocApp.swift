import SwiftUI

@main
struct VirtualLocApp: App {
    @StateObject private var engine = SimulationEngine()
    @StateObject private var store = Store()
    @StateObject private var keepAlive = KeepAlive()
    @StateObject private var expiry = ExpiryReminder()
    @StateObject private var log = AppLog.shared
    @StateObject private var network = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(keepAlive)
                .environmentObject(expiry)
                .environmentObject(log)
                .environmentObject(network)
                .preferredColorScheme(.light)
                // 浮動視窗（子母畫面）要用的 AVSampleBufferDisplayLayer 必須是
                // 真的在 SwiftUI View 階層裡的東西，系統才會確實合成、顯示我們
                // 送進去的內容（詳見 PiPOverlay.swift 開頭註解）。放在 App 最
                // 外層，整個 App 生命週期都在，不會因為切分頁被拆掉重建。
                // opacity 很低、不接受互動，正常使用時完全看不出來。
                .background(
                    PiPSurfaceHost()
                        .frame(width: 340, height: 84)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                )
                .onAppear {
                    engine.attach(store: store, keepAlive: keepAlive)
                    keepAlive.start()
                    expiry.requestPermission()
                }
        }
    }
}
