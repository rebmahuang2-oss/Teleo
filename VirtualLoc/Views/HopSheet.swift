import SwiftUI
import UIKit

/// 跳躍收果：輸入多個座標，依序直接跳到每個點、停留指定秒數，再跳下一個點。
struct HopSheet: View {
    @EnvironmentObject var engine: SimulationEngine
    @Environment(\.dismiss) private var dismiss

    @AppStorage("hopText") private var text = ""
    @AppStorage("hopDwell") private var dwell = 8
    @AppStorage("hopSort") private var sortShortest = false
    /// 各點專屬的停留秒數（以座標文字為鍵）；沒設定的點用預設秒數
    @AppStorage("hopOverrides") private var overridesJSON = "{}"
    @State private var error: String?

    private var entries: [(coord: Coord, dwell: Double?)] { Geo.parseListWithDwell(text) }
    private var lineCount: Int {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// 預估一輪需要的時間（秒）
    private var estimatedSeconds: Double {
        entries.reduce(0) { $0 + effectiveDwell($1) }
    }

    private var overrides: [String: Int] {
        guard let data = overridesJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return dict
    }

    private func setOverride(_ key: String, _ value: Int?) {
        var dict = overrides
        if let value { dict[key] = value } else { dict.removeValue(forKey: key) }
        if let data = try? JSONEncoder().encode(dict), let s = String(data: data, encoding: .utf8) {
            overridesJSON = s
        }
    }

    private func key(_ c: Coord) -> String { Geo.format(c) }

    /// 這個點實際停留的秒數：個別設定 > 預設秒數
    private func effectiveDwell(_ e: (coord: Coord, dwell: Double?)) -> Double {
        if let v = overrides[key(e.coord)] { return Double(v) }
        return e.dwell ?? Double(dwell)
    }

    private func pointRow(_ index: Int, _ e: (coord: Coord, dwell: Double?)) -> some View {
        let k = key(e.coord)
        let value = Int(effectiveDwell(e))
        let custom = overrides[k] != nil
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, alignment: .leading)
            Text(k)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.subtext)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text("\(value) 秒")
                .font(.subheadline.weight(custom ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(custom ? Theme.accent : Theme.subtext)
                .frame(width: 58, alignment: .trailing)
            Stepper("", value: Binding(get: { value }, set: { setOverride(k, $0) }), in: 1...300)
                .labelsHidden()
        }
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
                             + (lineCount > entries.count ? "（略過 \(lineCount - entries.count) 行）" : "")
                             + (entries.isEmpty ? "" : " · 一輪約 \(estimatedSeconds.durationText)"))
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
                    Text("要停留的點")
                } footer: {
                    Text("每行一個點：緯度, 經度。每個點停留幾秒，可以在下方「各點停留秒數」個別調整。")
                }

                Section("停留與輪數") {
                    Stepper("預設每點停留 \(dwell) 秒", value: $dwell, in: 1...300)
                    Stepper("全部的點走 \(engine.flowerLaps) 輪", value: $engine.flowerLaps, in: 1...99)
                    Toggle("依最短順序排列（3 個點以上）", isOn: $sortShortest)
                }

                if !entries.isEmpty {
                    Section {
                        DisclosureGroup("各點停留秒數（\(entries.count) 點）") {
                            ForEach(Array(entries.prefix(200).enumerated()), id: \.offset) { i, e in
                                pointRow(i, e)
                            }
                            if entries.count > 200 {
                                Text("只顯示前 200 點，其餘用預設秒數")
                                    .font(.caption).foregroundStyle(Theme.subtext)
                            }
                            Button("全部恢復預設秒數", role: .destructive) { overridesJSON = "{}" }
                                .disabled(overrides.isEmpty)
                        }
                    } footer: {
                        Text("藍色粗體的秒數是你個別調整過的點，其他點用上方的預設秒數。")
                    }
                }

                Section {
                    Text("依序直接跳到每個點，不會沿路走過去。距離很遠或停留時間很短時，遊戲可能判定位置移動異常。")
                        .font(.footnote)
                        .foregroundStyle(Theme.subtext)
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                }

                Section {
                    Button("只產生路線") { generate(start: false) }
                    Button("產生並開始跳") { generate(start: true) }
                        .disabled(!engine.isConnected)
                } footer: {
                    Text("會取代目前的路線。")
                }
            }
            .navigationTitle("跳躍收果")
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
                : "至少要 2 個點才能依序跳"
            return
        }
        error = nil
        list = list.map { (coord: $0.coord, dwell: effectiveDwell($0)) }   // 先套用各點設定，排序時才會跟著點走
        if sortShortest && list.count >= 3 && list.count <= 5000 {
            // 排序時要連同各點的停留秒數一起移動
            let order = Geo.shortestOrder(list.map { $0.coord })
            var pool = list
            list = order.compactMap { c in
                guard let i = pool.firstIndex(where: { $0.coord.latitude == c.latitude && $0.coord.longitude == c.longitude })
                else { return nil }
                return pool.remove(at: i)
            }
        }
        engine.buildHopRoute(points: list.map { $0.coord },
                             dwells: list.map { $0.dwell },
                             defaultDwell: Double(dwell))
        dismiss()
        if start { engine.startRoute(laps: engine.flowerLaps) }
    }
}
