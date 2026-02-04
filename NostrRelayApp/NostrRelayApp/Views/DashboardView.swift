import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var relayService: RelayService
    @EnvironmentObject var configService: ConfigurationService
    @EnvironmentObject var eventService: EventViewerService
    
    var body: some View {
        VStack(spacing: 24) {
            // Status Card
            VStack {
                HStack {
                    Circle()
                        .fill(relayService.isRunning ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    
                    Text(relayService.statusMessage)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                }
                
                Divider()
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("Address")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(configService.config.url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    
                    Spacer()
                    
                    // Button to open in Browser
                    Button(action: {
                        if let url = URL(string: "http://localhost:\(configService.config.port)") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.plain)
                    .disabled(!relayService.isRunning)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .onChange(of: relayService.isServerReady) { _, isReady in
                if isReady {
                    print("✅ Server confirms READY. Connecting viewer...")
                    eventService.connect(port: configService.config.port, config: configService.config)
                } else {
                    eventService.disconnect()
                }
            }

            
            // Big Toggle Button
            Button(action: {
                if relayService.isRunning {
                    relayService.stop()
                    // Disconnect happens automatically via .onChange above
                } else {
                    relayService.start(configService: configService)
                    // Connection happens automatically via .onChange above once logs confirm ready
                }
            }) {
                HStack {
                    Image(systemName: relayService.isRunning ? "stop.fill" : "play.fill")
                    Text(relayService.isRunning ? "Stop Relay" : "Start Relay")
                }
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(relayService.isRunning ? .red : .green)
            .controlSize(.large)
            
            // Recent Events Preview
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Activity")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    if eventService.isConnected {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Live").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if eventService.events.isEmpty {
                            Text("Waiting for events...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            ForEach(eventService.events.prefix(10)) { event in
                                EventRow(event: event)
                                    .padding(.horizontal, 8)
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: 250) // Taller for events
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
        }
        .padding()
    }
}
