import SwiftUI
import UIKit

/// 花農繞圈：輸入多朵花的座標，繞每朵花走圈，再換下一朵。
struct FarmSheet: View {
    @EnvironmentObject var engine: SimulationEngine
    @Environment(\.dismiss) private var dismiss

    @AppStorage("farmText") private var text = ""
    @AppStorage("farmRadiusText") private var radiusText = "30"
    @AppStorage("farmCircleLaps") private var circleLaps = 1
    @AppStorage("farmPoints") private var points = 12
    @AppStorage("farmJump") private var jump = false
    @AppStorage("farmSort") private var sortShortest = false
    @State private var error: String?

    private var flowers: [Coord] { Geo.parseList(text) }
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
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                    HStack {
                        Text("辨識到 \(flowers.count) 朵花" + (lineCount > flowers.count ? "（略過 \(lineCount - flowers.count) 行）" : ""))
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
                    Text("花的座標")
                } footer: {
                    Text("每行一朵花：緯度, 經度。會依你輸入的順序一朵接一朵走。")
                }

                Section("繞圈") {
                    HStack {
                        Text("半徑（公尺）")
                        Spacer()
                        TextField("30", text: $radiusText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    Stepper("每朵花繞 \(circleLaps) 圈", value: $circleLaps, in: 1...20)
                    Stepper("每圈 \(points) 個點", value: $points, in: 6...36)
                    Stepper("全部的花走 \(engine.flowerLaps) 輪", value: $engine.flowerLaps, in: 1...99)
                    SpeedRow(kmh: $engine.routeKmh)
                }

                Section {
                    Toggle("花與花之間直接瞬移", isOn: $jump)
                    Toggle("依最短順序排列花（3 朵以上）", isOn: $sortShortest)
                } header: {
                    Text("換下一朵花")
                } footer: {
                    Text(jump
                         ? "繞完一朵花就直接跳到下一朵花的圈上，不會走過去。距離很遠時，遊戲可能判定位置移動異常。"
                         : "繞完一朵花後，以上方設定的速度走到下一朵花。")
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                }

                Section {
                    Button("只產生路線") { generate(start: false) }
                    Button("產生並開始走") { generate(start: true) }
                        .disabled(!engine.isConnected)
                } footer: {
                    Text("會取代目前的路線。地圖上會畫出每朵花和繞圈範圍。")
                }
            }
            .navigationTitle("花農繞圈")
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
        var list = flowers
        guard !list.isEmpty else {
            error = "沒有可辨識的座標，請每行輸入一朵花：緯度, 經度"
            return
        }
        guard let radius = Double(radiusText.replacingOccurrences(of: ",", with: ".")),
              radius >= 1, radius <= 5000 else {
            error = "半徑請輸入 1～5000 公尺"
            return
        }
        error = nil
        if sortShortest && list.count >= 3 && list.count <= 5000 { list = Geo.shortestOrder(list) }
        engine.buildFarmRoute(flowers: list, radius: radius, circleLaps: circleLaps,
                              pointsPerCircle: points, jump: jump)
        dismiss()
        if start { engine.startRoute(laps: engine.flowerLaps) }
    }
}
