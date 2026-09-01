import SwiftUI

@main
struct NostrRelayApp: App {
    @StateObject private var relayService = RelayService()
    @StateObject private var configService = ConfigurationService()
    @StateObject private var eventService = EventViewerService()
    
    @Environment(\.openWindow) var openWindow
    
    var body: some Scene {
        WindowGroup(id: "dashboard") {
            ContentView()
                .environmentObject(relayService)
                .environmentObject(configService)
                .environmentObject(eventService)
                .frame(minWidth: 500, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        
        MenuBarExtra("Nostr Relay", systemImage: "network.badge.shield.half.filled") {
            Button("Open Dashboard") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            }
            .keyboardShortcut("d")
            
            Divider()
            
            Button(relayService.isRunning ? "Stop Relay" : "Start Relay") {
                if relayService.isRunning {
                    relayService.stop()
                } else {
                    relayService.start(configService: configService)
                }
            }
            
            Divider()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct ContentView: View {
    @EnvironmentObject var relayService: RelayService
    @EnvironmentObject var configService: ConfigurationService
    @EnvironmentObject var eventService: EventViewerService

    enum Tab: Hashable {
        case dashboard, logs, data, settings
    }

    @State private var selection: Tab = .dashboard

    var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "server.rack")
                }
                .tag(Tab.dashboard)

            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "terminal")
                }
                .tag(Tab.logs)

            EventViewer()
                .tabItem {
                    Label("Data", systemImage: "tablecells")
                }
                .tag(Tab.data)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(Tab.settings)
        }
        .onChange(of: selection) { _ in updateLiveConnection() }
        .onChange(of: relayService.isServerReady) { _ in updateLiveConnection() }
        .task {
            // Bring the relay up as soon as the app is running. start() already
            // guards on isRunning/isStarting, so reopening this window (the app
            // stays alive in the menu bar after it is closed) is a no-op.
            if configService.config.appSpecific.autoStart {
                relayService.start(configService: configService)
            }
        }
    }

    /// Only hold a live event subscription when a tab that displays events is
    /// visible — the stream costs CPU/energy on a busy relay.
    private func updateLiveConnection() {
        let needsLive = (selection == .dashboard || selection == .data) && relayService.isServerReady
        // isActive (not isConnected) so a connection that is mid-retry
        // isn't torn down and rebuilt on tab switches.
        if needsLive && !eventService.isActive {
            eventService.connect(port: configService.config.port, config: configService.config)
        } else if !needsLive && eventService.isActive {
            eventService.disconnect()
        }
    }
}
