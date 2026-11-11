import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: 共用小元件

struct SpeedRow: View {
    @Binding var kmh: Double
    var range: ClosedRange<Double> = 1...120

    var body: some View {
        HStack {
            Image(systemName: "speedometer")
            Text("速度 \(Int(kmh)) km/h")
                .font(.headline)
                .monospacedDigit()
            Spacer()
            stepButton("minus") { kmh = max(range.lowerBound, kmh - 1) }
            stepButton("plus") { kmh = min(range.upperBound, kmh + 1) }
        }
        .foregroundStyle(Theme.accent)
    }

    private func stepButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 64, height: 48)
                .background(Theme.accentSoft, in: Capsule())
        }
    }
}

struct MessageLine: View {
    @EnvironmentObject var engine: SimulationEngine
    var body: some View {
        if !engine.message.isEmpty {
            Text(engine.message)
                .font(.caption)
                .foregroundStyle(Theme.subtext)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: 單點定位

struct PointCard: View {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var store: Store
    @State private var showSave = false
    @State private var saveName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("單點定位").font(.headline)
                Spacer()
                if engine.current != nil {
                    Label("模擬中", systemImage: "location.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.warn)
                }
            }

            if let c = engine.selected {
                Text(Geo.format(c))
                    .font(.system(.title3, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button { UIPasteboard.general.string = Geo.format(c) } label: {
                        Label("複製座標", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SoftButtonStyle())
                    Button { pasteCoordinate() } label: {
                        Label("貼上座標", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            } else {
                Text("輕點地圖選擇位置，或在上方搜尋地名、貼上「緯度, 經度」")
                    .font(.subheadline)
                    .foregroundStyle(Theme.subtext)
                Button { pasteCoordinate() } label: {
                    Label("貼上座標", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(SoftButtonStyle())
            }

            HStack(spacing: 10) {
                Button {
                    if let c = engine.selected { engine.goTo(c) }
                } label: {
                    Label("定位到此", systemImage: "paperplane.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(engine.selected == nil)

                Button {
                    saveName = ""
                    showSave = true
                } label: {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 26))
                        .frame(width: 64, height: 56)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .disabled(engine.selected == nil)
                .opacity(engine.selected == nil ? 0.5 : 1)
            }

            MessageLine()
        }
        .card()
        .alert("加入收藏", isPresented: $showSave) {
            TextField("名稱", text: $saveName)
            Button("儲存") {
                if let c = engine.selected {
                    let name = saveName.isEmpty ? Geo.format(c) : saveName
                    if !store.addPlace(name: name, coord: c) {
                        engine.message = "地標已達 \(Store.placeLimit) 筆上限"
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func pasteCoordinate() {
        guard let s = UIPasteboard.general.string, let c = Geo.parseOne(s) else {
            engine.message = "剪貼簿裡沒有可辨識的座標"
            return
        }
        engine.selected = c
    }
}

// MARK: 編輯路線／種花路線

struct RouteCard: View {
    /// true = 種花路線（圈數、點間瞬移），false = 一般編輯路線
    let flower: Bool

    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var store: Store
    @AppStorage("sortOnPaste") private var sortOnPaste = false

    @State private var showGPX = false
    @State private var showPaste = false
    @State private var showSave = false
    @State private var showStart = false
    @State private var showFlowerSettings = false
    @State private var showFarm = false
    @State private var showHop = false
    @State private var appendToRoute = false
    @State private var pasteText = ""
    @State private var saveName = ""
    @State private var startText = ""

    private var title: String { flower ? "種花" : "路線" }
    private var hopping: Bool { (flower && engine.flowerHop) || engine.hopRouteActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !engine.routeRunning, !flower, let last = engine.route.last {
                VStack(alignment: .leading, spacing: 6) {
                    Text("第 \(engine.route.count) 點座標").font(.subheadline.weight(.semibold))
                    Text(Geo.format(last))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Theme.subtext)
                    Button { UIPasteboard.general.string = Geo.format(last) } label: {
                        Label("複製座標", systemImage: "doc.on.doc")
                    }
                    .font(.subheadline)
                }
            }

            if engine.routeRunning {
                runningInfo
            } else {
                Text("輕點地圖加入下一點，拖曳可移動地圖")
                    .font(.footnote)
                    .foregroundStyle(Theme.subtext)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack {
                loadMenu
                Spacer()
                if !engine.routeRunning {
                    Button(startText.isEmpty ? "選擇起跑點" : "起跑點 \(startText)") { showStart = true }
                        .font(.subheadline.weight(.semibold))
                }
            }

            if !engine.routeRunning {
                VStack(alignment: .leading, spacing: 8) {
                    if flower {
                        HStack(spacing: 8) {
                            Button { showFarm = true } label: {
                                Label("花農繞圈", systemImage: "leaf.circle")
                            }
                            .buttonStyle(SoftButtonStyle())
                            Button { showHop = true } label: {
                                Label("跳躍收果", systemImage: "arrow.up.forward.circle")
                            }
                            .buttonStyle(SoftButtonStyle())
                        }
                    }
                    Button { pasteText = ""; showPaste = true } label: {
                        Label("輸入多筆座標", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !hopping {
                SpeedRow(kmh: $engine.routeKmh)
            }

            if flower {
                flowerRow
            } else if !engine.routeRunning {
                CapsuleSegmented(
                    items: SimulationEngine.RouteRepeat.allCases.map { ($0, $0.rawValue) },
                    selection: $engine.routeRepeat)
            }

            controls
            MessageLine()
        }
        .card()
        .fileImporter(isPresented: $showGPX, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let n = engine.loadGPX(data: data)
                    engine.message = n > 0 ? "已載入 \(n) 個路點" : "檔案中沒有找到有效的路點"
                } else {
                    engine.message = "無法讀取檔案"
                }
            case .failure(let err):
                engine.message = "匯入失敗：\(err.localizedDescription)"
            }
        }
        .sheet(isPresented: $showPaste) { pasteSheet }
        .sheet(isPresented: $showFlowerSettings) { FlowerSettingsSheet() }
        .sheet(isPresented: $showFarm) { FarmSheet() }
        .sheet(isPresented: $showHop) { HopSheet() }
        .alert("儲存路線", isPresented: $showSave) {
            TextField("名稱", text: $saveName)
            Button("儲存") {
                let name = saveName.isEmpty ? "\(title) \(engine.route.count) 點" : saveName
                if !store.addRoute(name: name, coords: engine.route) {
                    engine.message = "路線已達 \(Store.routeLimit) 筆上限"
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("從第幾點開始", isPresented: $showStart) {
            TextField("1", text: $startText).keyboardType(.numberPad)
            Button("好") {}
            Button("清除", role: .cancel) { startText = "" }
        }
    }

    // MARK: 區塊

    private var header: some View {
        HStack {
            Menu {
                if store.routes.isEmpty {
                    Text("尚無收藏路線")
                } else {
                    ForEach(store.routes) { r in
                        Button("\(r.name)（\(r.points.count) 點）") { engine.setRoute(r.coords) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(title) · \(engine.route.count) 點").font(.headline)
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                }
                .foregroundStyle(Theme.text)
            }
            Spacer()
            Button(role: .destructive) { engine.clearRoute() } label: {
                Label("清除路線", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.danger)
            }
            .disabled(engine.route.isEmpty)
        }
    }

    private var runningInfo: some View {
        VStack(spacing: 4) {
            if flower, let limit = engine.lapsTotalText {
                Text(limit).font(.subheadline.weight(.semibold))
            }
            if let farm = engine.farmProgressText {
                Text(farm).font(.subheadline.weight(.semibold))
            }
            if let hop = engine.hopProgressText {
                Text(hop).font(.subheadline.weight(.semibold))
            }
            Text("第 \(engine.routeIndex + 1) 點"
                 + (hopping ? "" : " · 剩餘 \(engine.remainingMeters.distanceText) · 約 \(engine.remainingSeconds.durationText)"))
                .font(.footnote)
                .foregroundStyle(Theme.subtext)
            if engine.routePaused {
                Text("已暫停").font(.footnote.weight(.semibold)).foregroundStyle(Theme.warn)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var loadMenu: some View {
        Menu {
            Button { pasteText = ""; showPaste = true } label: { Label("貼上座標清單", systemImage: "doc.on.clipboard") }
            Button { showGPX = true } label: { Label("匯入 GPX 檔", systemImage: "square.and.arrow.down") }
            Divider()
            Button { engine.sortRouteShortest() } label: { Label("排成最短路線", systemImage: "arrow.triangle.swap") }
                .disabled(engine.routeRunning || engine.route.count < 3)
            Button { engine.reverseRoute() } label: { Label("反轉方向", systemImage: "arrow.left.arrow.right") }
                .disabled(engine.routeRunning || engine.route.count < 2)
            Button {
                UIPasteboard.general.string = engine.route.map { Geo.format($0) }.joined(separator: "\n")
                engine.message = "已複製 \(engine.route.count) 點座標"
            } label: { Label("複製全部座標", systemImage: "doc.on.doc") }
                .disabled(engine.route.isEmpty)
        } label: {
            Text("載入座標").font(.subheadline.weight(.semibold))
        }
        .disabled(engine.routeRunning)
    }

    private var flowerRow: some View {
        HStack {
            Text("種花設定 · \(engine.flowerLaps) 輪")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Spacer()
            Button { showFlowerSettings = true } label: {
                HStack(spacing: 4) {
                    Text(engine.flowerHop ? "花點間瞬移" : "步行經過")
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if engine.routeRunning {
            HStack(spacing: 8) {
                if engine.routePaused {
                    Button { engine.resumeRoute() } label: { Label("回到暫停點並繼續", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button { engine.pauseRoute() } label: { Label("暫停", systemImage: "pause.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                roundSmall("backward.end.fill") { engine.previousPoint() }
                roundSmall("forward.end.fill") { engine.nextPoint() }
                roundSmall("stop.fill", tint: Theme.danger) { engine.stopRoute() }
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    let n = max(1, Int(startText) ?? 1)
                    engine.startRoute(from: n - 1, laps: flower ? engine.flowerLaps : nil)
                } label: {
                    Label("開始路線", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(engine.route.count < 2)

                Button {
                    saveName = ""
                    showSave = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 22))
                        .frame(width: 64, height: 56)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .disabled(engine.route.count < 2)
                .opacity(engine.route.count < 2 ? 0.5 : 1)
            }
        }
    }

    private func roundSmall(_ name: String, tint: Color = Theme.accent, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 50, height: 54)
                .background(Theme.accentSoft, in: Capsule())
        }
    }

    /// 依貼上頁的選項載入座標：取代目前路線，或接在後面。回傳辨識到的座標數。
    private func applyPaste() -> Int {
        if appendToRoute && !engine.route.isEmpty {
            let added = Geo.parseList(pasteText)
            if !added.isEmpty { engine.setRoute(engine.route + added) }
            return added.count
        }
        return engine.loadRouteText(pasteText, sortShortest: sortOnPaste)
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("每行一個座標：緯度, 經度").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pasteText)
                    .font(.system(.body, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.4)))
                HStack {
                    Text("辨識到 \(Geo.parseList(pasteText).count) 個座標")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("貼上剪貼簿") {
                        if let s = UIPasteboard.general.string, !s.isEmpty {
                            pasteText += (pasteText.isEmpty || pasteText.hasSuffix("\n") ? "" : "\n") + s
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                Toggle("接在目前路線後面（\(engine.route.count) 點）", isOn: $appendToRoute)
                    .disabled(engine.route.isEmpty)
                Toggle("自動排列最短路線（3～5000 點）", isOn: $sortOnPaste)
                    .disabled(appendToRoute)
                Text(appendToRoute ? "依輸入順序接在後面" : (sortOnPaste ? "起點可能會改變" : "依輸入順序"))
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    let parsed = applyPaste()
                    showPaste = false
                    if engine.route.count >= 2 {
                        engine.startRoute(laps: flower ? engine.flowerLaps : nil)
                    } else {
                        engine.message = parsed == 0 ? "沒有可辨識的座標" : "至少要 2 個座標才能開始走"
                    }
                } label: {
                    Label("載入並開始走", systemImage: "figure.walk")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
            .navigationTitle("貼上座標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showPaste = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("載入") {
                        let n = applyPaste()
                        engine.message = n > 0 ? "已載入 \(n) 個座標" : "沒有可辨識的座標"
                        showPaste = false
                    }
                }
            }
        }
    }
}

// MARK: 種花設定

struct FlowerSettingsSheet: View {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var keepAlive: KeepAlive
    @Environment(\.dismiss) private var dismiss
    @State private var centerText = ""
    @State private var radiusText = "30"
    @State private var circlePoints = 8
    @State private var circleError: String?

    /// 產生繞圈路線：圓心取自輸入欄（留空則用選取點、目前位置、原始位置）。
    private func makeCircle(start: Bool) {
        let typed = centerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let center: Coord?
        if typed.isEmpty {
            center = engine.selected ?? engine.current ?? keepAlive.original
        } else {
            center = Geo.parseOne(typed)
            if center == nil { circleError = "圓心座標格式不正確，請輸入「緯度, 經度」"; return }
        }
        guard let c = center else {
            circleError = "請輸入圓心座標，或先在地圖上選一個點"
            return
        }
        guard let meters = Double(radiusText.replacingOccurrences(of: ",", with: ".")),
              meters >= 1, meters <= 5000 else {
            circleError = "半徑請輸入 1～5000 公尺"
            return
        }
        circleError = nil
        let n = max(3, circlePoints)
        let dLat = meters / 111_320.0
        let dLon = meters / (111_320.0 * max(cos(c.latitude * .pi / 180), 0.01))
        var pts: [Coord] = (0..<n).map { i in
            let a = 2 * Double.pi * Double(i) / Double(n)
            return Coord(latitude: c.latitude + dLat * sin(a), longitude: c.longitude + dLon * cos(a))
        }
        if let first = pts.first { pts.append(first) }      // 封閉成一圈
        engine.setRoute(pts)
        engine.message = "已產生繞圈路線：半徑 \(Int(meters)) 公尺、\(n) 點"
        dismiss()
        if start { engine.startRoute(laps: engine.flowerLaps) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("圓心座標：緯度, 經度（留空＝用選取點）", text: $centerText)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    HStack {
                        Text("半徑（公尺）")
                        Spacer()
                        TextField("30", text: $radiusText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    Stepper("\(circlePoints) 個點", value: $circlePoints, in: 3...36)
                    if let circleError {
                        Text(circleError).font(.caption).foregroundStyle(Theme.danger)
                    }
                    Button("產生繞圈路線") { makeCircle(start: false) }
                    Button("產生並開始走") { makeCircle(start: true) }
                        .disabled(!engine.isConnected)
                } header: {
                    Text("繞圈路線")
                } footer: {
                    Text("以圓心為中心，在指定半徑上均分出路線點（預設 8 點）並連成一圈，依下方設定的圈數走。會取代目前的路線。")
                }
                Section("圈數") {
                    Stepper("走 \(engine.flowerLaps) 輪", value: $engine.flowerLaps, in: 1...99)
                }
                Section {
                    Toggle("花點間瞬移", isOn: $engine.flowerHop)
                    if engine.flowerHop {
                        Stepper("每點停留 \(Int(engine.flowerDwell)) 秒",
                                value: $engine.flowerDwell, in: 1...120, step: 1)
                    }
                } footer: {
                    Text(engine.flowerHop
                         ? "依序跳到每個路線點，每點停留指定秒數；不會沿路走過去。"
                         : "沿著路線以設定的速度走過每個點。")
                }
                Section {
                    Stepper("圈圈半徑 \(Int(engine.flowerRadius)) 公尺",
                            value: $engine.flowerRadius, in: 10...300, step: 5)
                } footer: {
                    Text("只影響地圖上圈圈的大小，方便對照路線點的範圍。")
                }
            }
            .navigationTitle("種花設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: 搖桿

struct JoystickCard: View {
    @EnvironmentObject var engine: SimulationEngine
    @State private var knob = CGSize.zero
    private let radius: CGFloat = 62

    var body: some View {
        VStack(spacing: 12) {
            SpeedRow(kmh: $engine.joystickKmh, range: 1...60)

            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: radius * 2, height: radius * 2)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 52, height: 52)
                    .offset(knob)
            }
            .frame(width: radius * 2 + 52, height: radius * 2 + 52)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let dx = g.translation.width
                        let dy = g.translation.height
                        let len = max(hypot(dx, dy), 0.0001)
                        let clamped = min(len, radius)
                        knob = CGSize(width: dx / len * clamped, height: dy / len * clamped)
                        // 螢幕 y 向下為正；北方為上，所以 dy 要反向
                        engine.setJoystick(CGVector(dx: knob.width / radius, dy: -knob.height / radius))
                    }
                    .onEnded { _ in
                        knob = .zero
                        engine.setJoystick(.zero)
                    }
            )

            Text(hint)
                .font(.footnote)
                .foregroundStyle(Theme.subtext)
                .multilineTextAlignment(.center)
            MessageLine()
        }
        .card()
    }

    private var hint: String {
        if !engine.isConnected { return "請先連線（右上角設定）" }
        if engine.current == nil && engine.selected == nil { return "先在地圖點一個起點，再拖曳搖桿開始移動" }
        return "拖曳圓點移動，離中心越遠越快；放開即停止。路線進行中使用搖桿會暫停路線，之後可回到暫停點繼續。"
    }
}
