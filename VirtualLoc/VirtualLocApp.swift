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
                .onAppear {
                    engine.attach(store: store, keepAlive: keepAlive)
                    keepAlive.start()
                    expiry.requestPermission()
                }
        }
    }
}
