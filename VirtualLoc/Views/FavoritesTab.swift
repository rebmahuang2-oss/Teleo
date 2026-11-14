import SwiftUI

struct FavoritesTab: View {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var store: Store
    @State private var section = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                Text("地標").tag(0)
                Text("路線").tag(1)
                Text("歷史").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            List {
                switch section {
                case 0: placesList
                case 1: routesList
                default: historyList
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.sheetBackground)
    }

    /// 每一列的玻璃卡片底，取代原本列表預設的白底。
    private func rowGlass() -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .padding(.vertical, 3)
    }

    @ViewBuilder private var placesList: some View {
        if store.places.isEmpty { Text("尚無地標。在單點定位的資訊卡按星號收藏。").foregroundColor(.secondary) }
        ForEach(store.places) { p in
            HStack {
                VStack(alignment: .leading) {
                    Text(p.name)
                    Text(Geo.format(p.coord)).font(.caption).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { engine.selected = p.coord }
                Spacer()
                Button("定位") {
                    engine.selected = p.coord
                    engine.goTo(p.coord)
                }
                .buttonStyle(.borderless)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(rowGlass())
        }
        .onDelete { store.places.remove(atOffsets: $0) }
    }

    @ViewBuilder private var routesList: some View {
        if store.routes.isEmpty { Text("尚無路線。在路線資訊卡按資料夾圖示儲存。").foregroundColor(.secondary) }
        ForEach(store.routes) { r in
            HStack {
                VStack(alignment: .leading) {
                    Text(r.name)
                    Text("\(r.points.count) 點 · \(Geo.pathLength(r.coords).distanceText)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("載入") { engine.setRoute(r.coords) }
                    .buttonStyle(.borderless)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(rowGlass())
        }
        .onDelete { store.routes.remove(atOffsets: $0) }
    }

    @ViewBuilder private var historyList: some View {
        if store.history.isEmpty { Text("尚無歷史紀錄").foregroundColor(.secondary) }
        ForEach(store.history) { h in
            HStack {
                VStack(alignment: .leading) {
                    Text(h.title)
                    Text(h.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("載入") {
                    if h.kind == .point, let c = h.coords.first {
                        engine.selected = c
                    } else {
                        engine.setRoute(h.coords)
                    }
                }
                .buttonStyle(.borderless)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(rowGlass())
        }
        .onDelete { store.history.remove(atOffsets: $0) }
        if !store.history.isEmpty {
            Button("清除歷史", role: .destructive) { store.clearHistory() }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }
}
