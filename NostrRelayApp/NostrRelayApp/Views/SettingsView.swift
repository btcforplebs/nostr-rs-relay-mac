import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configService: ConfigurationService
    @EnvironmentObject var relayService: RelayService
    @State private var rawTOML: String = ""
    @State private var showingAlert = false
    
    var body: some View {
        TabView {
            BasicSettingsView()
                .tabItem {
                    Label("Basic", systemImage: "slider.horizontal.3")
                }
            
            AdvancedSettingsView(rawTOML: $rawTOML)
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .padding()
        .onAppear {
            rawTOML = configService.loadRawTOML()
        }
    }
}

struct BasicSettingsView: View {
    @EnvironmentObject var configService: ConfigurationService
    @EnvironmentObject var relayService: RelayService
    
    var body: some View {
        Form {
            Section("General") {
                TextField("Relay Name", text: $configService.config.name)
                TextField("Description", text: $configService.config.description)
                TextField("Pubkey", text: $configService.config.pubkey)
                TextField("Contact", text: $configService.config.contact)
            }
            .disabled(configService.config.appSpecific.useManualConfig)
            
            Section("Network") {
                TextField("Bind Address", text: $configService.config.bindAddress)
                TextField("Port", value: $configService.config.port, formatter: NumberFormatter())
                TextField("Public URL", text: $configService.config.url)
            }
            .disabled(configService.config.appSpecific.useManualConfig)
            
            Section("Limits") {
                TextField("Max Event Size (Bytes)", value: $configService.config.maxEventSize, formatter: NumberFormatter())
                TextField("Max WS Message (Bytes)", value: $configService.config.maxWSMessageBytes, formatter: NumberFormatter())
                TextField("Max WS Frame (Bytes)", value: $configService.config.maxWSFrameBytes, formatter: NumberFormatter())
                TextField("Events Per Second (0 = unlimited)", value: $configService.config.messagesPerSec, formatter: NumberFormatter())
                TextField("Subscriptions Per Minute (0 = unlimited)", value: $configService.config.subscriptionsPerMin, formatter: NumberFormatter())
                Text("Events per second is relay-wide: it slows the single database writer rather than limiting any one client. Subscriptions per minute is per connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .disabled(configService.config.appSpecific.useManualConfig)
            
            Section("Security") {
                Toggle("Enable Spam Filter", isOn: $configService.config.spamFilterEnabled)
                if configService.config.spamFilterEnabled {
                    TextField("Blocked Pubkeys (comma separated)", text: Binding(
                        get: { configService.config.blockedPubkeys.joined(separator: ", ") },
                        set: { configService.config.blockedPubkeys = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
                    TextField("Blocked Keywords (comma separated)", text: Binding(
                        get: { configService.config.blockedKeywords.joined(separator: ", ") },
                        set: { configService.config.blockedKeywords = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
                }
            }
            .disabled(configService.config.appSpecific.useManualConfig)

            Section("Startup") {
                Toggle("Start relay when app launches", isOn: $configService.config.appSpecific.autoStart)
                    .onChange(of: configService.config.appSpecific.autoStart) { _ in
                        configService.save()
                    }
                Text("The relay comes up automatically when you open the app. Turn this off to start it yourself from the dashboard or the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Logging") {
                Toggle("Verbose relay logs", isOn: $configService.config.appSpecific.verboseLogging)
                    .onChange(of: configService.config.appSpecific.verboseLogging) { _ in
                        configService.save()
                    }
                Text("Off logs only warnings and errors, which saves CPU and energy on a busy relay. Turn on for full connection/event logs. Restart the relay to apply.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if configService.config.appSpecific.useManualConfig {
                Section {
                    Text("Settings are managed manually in the Advanced tab.")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    Button("Save Configuration") {
                        configService.save()
                    }
                    SaveStatusView()
                }
            }
            
            if relayService.isRunning {
                Section {
                    Text("Note: Restart the relay to apply network changes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Reports the outcome of the last save so a failed write is visible rather than silent.
struct SaveStatusView: View {
    @EnvironmentObject var configService: ConfigurationService

    var body: some View {
        if let error = configService.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
        } else if let savedAt = configService.lastSavedAt {
            Label("Saved at \(savedAt.formatted(date: .omitted, time: .standard))",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject var configService: ConfigurationService
    @EnvironmentObject var relayService: RelayService
    @Binding var rawTOML: String
    
    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Enable Manual Configuration (Edit config.toml directly)", isOn: $configService.config.appSpecific.useManualConfig)
                .padding(.bottom)
                .onChange(of: configService.config.appSpecific.useManualConfig) { newValue in
                    configService.save() // Save the toggle state
                    if !newValue {
                        // Reload from generated if we turn off manual mode
                        // We might want to warn the user that their manual edits will be lost on next save
                    }
                }
            
            Text("Edit config.toml")
                .font(.headline)
            
            TextEditor(text: $rawTOML)
                .font(.custom("Menlo", size: 12))
                .border(Color.gray.opacity(0.2))
            
            HStack {
                Button("Reload from Disk") {
                    rawTOML = configService.loadRawTOML()
                }
                
                Spacer()
                
                Button("Save TOML") {
                    configService.saveRawTOML(rawTOML)
                }
                .disabled(!configService.config.appSpecific.useManualConfig)
                
                if !configService.config.appSpecific.useManualConfig {
                    Text("(Enable manual config to save)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top)

            SaveStatusView()
                .padding(.top, 4)
        }
        .padding()
    }
}
