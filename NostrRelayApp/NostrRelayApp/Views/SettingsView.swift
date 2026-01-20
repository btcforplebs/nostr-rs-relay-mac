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
                TextField("Max Message Size (Bytes)", value: $configService.config.maxMessageSize, formatter: NumberFormatter())
            }
            .disabled(configService.config.appSpecific.useManualConfig)
            
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
        }
        .padding()
    }
}
