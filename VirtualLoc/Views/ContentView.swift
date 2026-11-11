import SwiftUI
import MapKit

struct ContentView: View {
    enum PlanMode: Hashable { case point, edit, flower }
    enum Page { case map, joystick }

    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var keepAlive: KeepAlive

    @State private var mode: PlanMode = .point
    @State private var page: Page = .map
    @State private var collapsed = false
    @State private var recenter = 0
    @State private var focus = 0
    @State private var showSettings = false
    @State private var showFolder = false

    var body: some View {
        ZStack {
            MapPane(recenterToken: recenter, focusToken: focus)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                SearchBar(focus: $focus, showSettings: $showSettings)
                StatusPills()
                CapsuleSegmented(
                    items: [(PlanMode.point, "單點定位"), (.edit, "編輯路線"), (.flower, "種花路線")],
                    selection: $mode)

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        originalPill
                        restorePill
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        RoundIconButton(systemName: "location.viewfinder") { recenter += 1 }
                        RoundIconButton(systemName: "arrow.uturn.backward", enabled: undoEnabled) { undo() }
                    }
                }

                collapseHandle

                if !collapsed { card }

                BottomBar(page: $page, showFolder: $showFolder)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
        .onChange(of: mode) { newMode in
            engine.pickOnMap = newMode != .point
            engine.showCircles = newMode == .flower
            page = .map
        }
        .onChange(of: page) { newPage in
            if newPage == .joystick { engine.pickOnMap = false } else { engine.pickOnMap = mode != .point }
        }
        .sheet(isPresented: $showSettings) {
            SettingsTab()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showFolder) {
            NavigationStack {
                FavoritesTab()
                    .navigationTitle("資料夾")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { showFolder = false } }
                    }
            }
        }
    }

    // MARK: 資訊卡

    @ViewBuilder private var card: some View {
        switch page {
        case .joystick:
            JoystickCard()
        case .map:
            switch mode {
            case .point: PointCard()
            case .edit: RouteCard(flower: false)
            case .flower: RouteCard(flower: true)
            }
        }
    }

    private var collapseHandle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(collapsed ? "展開資訊卡" : "收合資訊卡")
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .pillBackground()
        }
    }

    // MARK: 左下角膠囊

    @ViewBuilder private var originalPill: some View {
        if let o = keepAlive.original {
            Button {
                engine.selected = o
                engine.goTo(o)
                focus += 1
            } label: {
                Label("原始定位", systemImage: "mappin.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.subtext)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .pillBackground()
            }
        }
    }

    private var restorePill: some View {
        let active = engine.current != nil
        return Button { engine.restoreRealGPS() } label: {
            Label("恢復 GPS", systemImage: "location.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warn)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface.opacity(0.96), in: Capsule())
                .overlay(Capsule().stroke(Theme.warn.opacity(0.7), lineWidth: 2))
                .opacity(active ? 1 : 0.55)
        }
        .disabled(!active)
    }

    // MARK: 復原

    private var undoEnabled: Bool {
        if page == .joystick { return false }
        if mode == .point { return engine.selected != nil }
        return !engine.routeRunning && !engine.route.isEmpty
    }

    private func undo() {
        if mode == .point {
            engine.selected = nil
        } else {
            engine.removeLastRoutePoint()
        }
    }
}

// MARK: 搜尋列

struct SearchBar: View {
    @EnvironmentObject var engine: SimulationEngine
    @Binding var focus: Int
    @Binding var showSettings: Bool
    @State private var query = ""
    @State private var searching = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.accent)
                TextField("地點、地址或緯度, 經度", text: $query)
                    .submitLabel(.search)
                    .onSubmit { search() }
                if searching {
                    ProgressView()
                } else if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.subtext)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .pillBackground()

            RoundIconButton(systemName: "gearshape") { showSettings = true }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let c = Geo.parseOne(q) {
            engine.selected = c
            focus += 1
            return
        }
        searching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        MKLocalSearch(request: req).start { resp, err in
            DispatchQueue.main.async {
                searching = false
                if let item = resp?.mapItems.first {
                    engine.selected = item.placemark.coordinate
                    engine.message = "已選取：\(item.name ?? q)"
                    focus += 1
                } else {
                    engine.message = err?.localizedDescription ?? "找不到地點"
                }
            }
        }
    }
}

// MARK: 狀態膠囊

struct StatusPills: View {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var network: NetworkMonitor
    @EnvironmentObject var expiry: ExpiryReminder

    private var dotColor: Color {
        switch engine.connection {
        case .connected: return Theme.accent
        case .connecting, .reconnecting: return Theme.warn
        case .disconnected: return Theme.danger
        }
    }

    private var text: String {
        switch engine.connection {
        case .connected: return "已連線"
        case .connecting: return "連線中"
        case .reconnecting(let n): return "重連中（\(n)）"
        case .disconnected: return "未連線，點此連線"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if engine.connection == .disconnected { engine.connect() }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(dotColor).frame(width: 12, height: 12)
                    Text(text).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .pillBackground()
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Image(systemName: network.icon)
                Text(network.label)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .pillBackground()

            if expiry.soon {
                Label("簽名將到期", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .pillBackground()
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 底部列

struct BottomBar: View {
    @Binding var page: ContentView.Page
    @Binding var showFolder: Bool

    var body: some View {
        HStack {
            item("map.fill", "地圖", selected: page == .map) { page = .map }
            item("folder", "資料夾", selected: false) { showFolder = true }
            item("dpad.fill", "搖桿", selected: page == .joystick) { page = .joystick }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.96), in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func item(_ icon: String, _ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 22))
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.subtext)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}
