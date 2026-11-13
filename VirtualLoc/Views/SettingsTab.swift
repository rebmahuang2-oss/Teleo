import SwiftUI
import UIKit
import CoreLocation

struct SettingsTab: View {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var keepAlive: KeepAlive
    @EnvironmentObject var expiry: ExpiryReminder

    @State private var showImporter = false
    @State private var pairingExists = PairingStore.exists
    @State private var importMessage: String?
    @AppStorage(RemotePairingDiscovery.overrideDefaultsKey) private var remotePairingPortOverride = 0
    @AppStorage("pipOverlayEnabled") private var pipEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section("連線") {
                    HStack {
                        Text("狀態")
                        Spacer()
                        Text(engine.connectionText).foregroundColor(.secondary)
                    }
                    if engine.connection == .disconnected {
                        Button("連線") { engine.connect() }
                            .disabled(!pairingExists)
                    } else {
                        Button("中斷連線", role: .destructive) { engine.disconnect() }
                    }
                    Toggle("啟動時自動連線", isOn: $engine.autoConnect)
                    Text("連線前請先開啟 LocalDevVPN 並連上 Wi-Fi。")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Text("無線配對連接埠")
                        Spacer()
                        TextField("自動", value: $remotePairingPortOverride, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Text("只有在用「無線配對」格式的配對檔時才會用到。App 會自動嘗試常見埠號跟掃描；如果一直連不上，可以在這裡手動填一個固定埠號（0 表示自動）。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("配對檔") {
                    HStack {
                        Text("配對檔")
                        Spacer()
                        Text(pairingExists ? "已匯入" : "未匯入").foregroundColor(.secondary)
                    }
                    Button(pairingExists ? "重新匯入配對檔" : "匯入配對檔") { showImporter = true }
                    if pairingExists {
                        Button("刪除配對檔", role: .destructive) {
                            engine.disconnect()
                            PairingStore.remove()
                            pairingExists = PairingStore.exists
                        }
                    }
                    if let m = importMessage {
                        Text(m).font(.caption).foregroundColor(.secondary)
                    }
                    Text("配對檔等同這支手機的開發者權限，只會存放在這個 App 裡，不會上傳。請勿分享給別人。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("背景保活與原始位置") {
                    Toggle("背景保活（持續定位）", isOn: $keepAlive.enabled)
                    HStack {
                        Text("定位權限")
                        Spacer()
                        Text(authText).foregroundColor(.secondary)
                    }
                    if let o = keepAlive.original {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("原始位置 \(Geo.format(o))")
                            if let acc = keepAlive.originalAccuracy, let d = keepAlive.originalDate {
                                Text("誤差約 \(Int(acc)) 公尺 · \(d.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("尚未取得原始位置").foregroundColor(.secondary)
                    }
                    Button("重新取得原始位置") { keepAlive.refreshOriginal() }
                        .disabled(engine.current != nil)
                    Text("背景保活會讓 App 在切到背景後繼續送出定位，螢幕上方會出現藍色定位指示。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("浮動視窗") {
                    Toggle("切到其他 App 時顯示浮動進度列", isOn: $pipEnabled)
                    Text("路線或搖桿進行中，切到遊戲等其他 App 時，畫面上方會浮一條小視窗顯示目前速度、走到第幾點、還剩多久，也能直接暫停／繼續。這是借用「子母畫面」機制做出來的效果，不保證在所有情況下都能穩定顯示；關閉後可以省一點電。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("簽名到期提醒") {
                    HStack {
                        Text("簽名")
                        Spacer()
                        Text(expiry.remainingText).foregroundColor(.secondary)
                    }
                    Toggle("到期前提醒", isOn: $expiry.enabled)
                    Stepper("提前 \(expiry.daysBefore) 天", value: $expiry.daysBefore, in: 0...6)
                    Picker("提醒時間", selection: $expiry.hour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                }

                Section("說明") {
                    NavigationLink("錯誤日誌") { LogView() }
                    NavigationLink("使用步驟") { HelpView() }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                do {
                    try PairingStore.importFile(from: url)
                    pairingExists = PairingStore.exists
                    importMessage = "已匯入配對檔"
                } catch {
                    importMessage = "匯入失敗：\(error.localizedDescription)"
                }
            case .failure(let err):
                importMessage = "匯入失敗：\(err.localizedDescription)"
            }
        }
    }

    private var authText: String {
        switch keepAlive.authorization {
        case .notDetermined: return "尚未詢問"
        case .restricted: return "受限制"
        case .denied: return "已拒絕（請到系統設定開啟）"
        case .authorizedAlways: return "永遠允許"
        case .authorizedWhenInUse: return "使用期間"
        @unknown default: return "未知"
        }
    }
}

struct LogView: View {
    @EnvironmentObject var log: AppLog

    var body: some View {
        ScrollView {
            Text(log.lines.isEmpty ? "目前沒有紀錄" : log.text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("錯誤日誌")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("複製") { UIPasteboard.general.string = log.text }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清除", role: .destructive) { log.clear() }
            }
        }
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                第一次使用
                1. iPhone「設定 → 隱私權與安全性」開啟開發者模式。
                2. 安裝 LocalDevVPN（App Store），開啟並連上 VPN；手機需連上 Wi-Fi。
                3. 用電腦取得這支手機的配對檔，傳到手機後在「設定」匯入。
                4. 回到「設定」按「連線」，狀態變成「已連線」。

                使用
                • 定位：點地圖或輸入座標，按「定位到此」。
                • 路線：匯入 GPX、貼上座標，或點地圖加入路線點，設定速度後開始。
                • 搖桿：先選起點，拖曳搖桿移動。
                • 結束：按「恢復真實定位」。

                注意
                • 重新開機後，開發者磁碟映像需要重新掛載，否則連線會失敗。
                • 斷線時路線進度會保留，連線恢復後會自動接續。
                • 側載簽名約 7 天到期，請定期重新簽名。
                """)
                .font(.callout)
            }
            .padding()
        }
        .navigationTitle("使用步驟")
    }
}
