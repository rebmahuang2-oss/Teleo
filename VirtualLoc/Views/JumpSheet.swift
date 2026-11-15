import SwiftUI
import UIKit

/// 跳躍拉金盆：輸入多個座標，按開始後直接跳到第一個點，
/// 之後完全不會自動倒數換點——要換下一個點，就按資訊卡上的「下一點」，
/// 或切到其他 App 時，浮動視窗上那顆往前跳的按鈕（長得像系統的「快轉 30 秒」，
/// 但按下去是立刻跳到下一個點，不是等 30 秒）。
///
/// 跟「跳躍收果」的差別：跳躍收果是設定好停留秒數、時間到了自動換下一點；
/// 這個完全交給使用者自己決定什麼時候要換，比較適合像是要在遊戲裡手動
/// 收集完東西才能換下一個點的情境，沒辦法事先訂死要停留幾秒。
struct JumpSheet: View {
    @EnvironmentObject var engine: SimulationEngine
    @Environment(\.dismiss) private var dismiss

    @AppStorage("jumpText") private var text = ""
    @AppStorage("jumpSort") private var sortShortest = false
    @State private var error: String?

    private var entries: [Coord] { Geo.parseList(text) }
    private var lineCount: Int {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .autocorrectionDisabled()
                    HStack {
                        Text("辨識到 \(entries.count) 個點"
                             + (lineCount > entries.count ? "（略過 \(lineCount - entries.count) 行）" : ""))
                            .font(.caption)
                            .foregroundStyle(Theme.subtext)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("貼上剪貼簿") { pasteClipboard() }
                        Button("加入地圖選取點") { addSelected() }
                            .disabled(engine.selected == nil)
                        Spacer()
                        Button("清空", role: .destructive) { text = "" }
                            .disabled(text.isEmpty)
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                } header: {
                    Text("要跳的點")
                } footer: {
                    Text("每行一個點：緯度, 經度。按順序跳，第一個點先跳到，之後要換下一個點，靠手動按「下一點」。")
                }

                Section {
                    Toggle("依最短順序排列（3 個點以上）", isOn: $sortShortest)
                }

                Section {
                    Text("按開始後會直接跳到第一個點（不會沿路走過去）。之後不會自動倒數換點：要換下一個點，按資訊卡或浮動視窗上的「下一點」；按太快、距離太遠，遊戲可能判定位置移動異常。")
                        .font(.footnote)
                        .foregroundStyle(Theme.subtext)
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                }

                Section {
                    Button("只產生路線") { generate(start: false) }
                    Button("產生並跳到第一點") { generate(start: true) }
                        .disabled(!engine.isConnected)
                } footer: {
                    Text("會取代目前的路線。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheetBackground)
            .navigationTitle("跳躍拉金盆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func pasteClipboard() {
        guard let s = UIPasteboard.general.string, !s.isEmpty else {
            error = "剪貼簿是空的"
            return
        }
        error = nil
        text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + s
    }

    private func addSelected() {
        guard let c = engine.selected else { return }
        error = nil
        text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + Geo.format(c)
    }

    private func generate(start: Bool) {
        var list = entries
        guard list.count >= 2 else {
            error = list.isEmpty
                ? "沒有可辨識的座標，請每行輸入一個點：緯度, 經度"
                : "至少要 2 個點才能依序跳（只有 1 個點的話，用「單點定位」就好）"
            return
        }
        error = nil
        if sortShortest && list.count >= 3 && list.count <= 5000 {
            list = Geo.shortestOrder(list)
        }
        engine.buildJumpRoute(points: list)
        dismiss()
        if start { engine.startRoute(laps: 1) }
    }
}
