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
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "server.rack")
                }
            
            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "terminal")
                }
            
            EventViewer()
                .tabItem {
                    Label("Data", systemImage: "tablecells")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}
