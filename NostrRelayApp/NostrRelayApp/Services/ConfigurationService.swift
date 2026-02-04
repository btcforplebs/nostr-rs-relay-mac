import Foundation

struct RelayConfig: Codable, Equatable {
    // Info
    var name: String = "NostrRelay"
    var description: String = "A fresh nostr-rs-relay"
    var pubkey: String = "" // Admin pubkey
    var contact: String = ""
    var url: String = "ws://localhost:8080"
    var icon: String = ""
    
    // Network
    var bindAddress: String = "0.0.0.0"
    var port: Int = 8080
    
    // Limits
    var maxEventSize: Int = 131072 // 128KB
    var maxWSMessageBytes: Int = 131072 // 128KB
    var maxWSFrameBytes: Int = 131072 // 128KB
    
    // Security / Spam
    var spamFilterEnabled: Bool = false
    var blockedPubkeys: [String] = []
    var blockedKeywords: [String] = []
    
    var appSpecific: AppSpecific = AppSpecific()
    
    struct AppSpecific: Codable, Equatable {
        var launchAtLogin: Bool = false
        var autoStart: Bool = false // Start relay when app launches
        var useManualConfig: Bool = false // If true, don't overwrite config.toml from UI
    }
}

@MainActor
class ConfigurationService: ObservableObject {
    @Published var config: RelayConfig
    
    private let fileManager = FileManager.default
    private let appSupportDir: URL
    private let configFileURL: URL
    private let tomlFileURL: URL
    
    init() {
        // Setup paths
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Cannot access Application Support directory")
        }
        
        self.appSupportDir = appSupport.appendingPathComponent("NostrRelayApp")
        self.configFileURL = self.appSupportDir.appendingPathComponent("settings.json")
        self.tomlFileURL = self.appSupportDir.appendingPathComponent("config.toml")
        
        // Create directory if needed
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        // Load config
        if let data = try? Data(contentsOf: configFileURL),
           let loaded = try? JSONDecoder().decode(RelayConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = RelayConfig()
        }
        
        // Ensure TOML exists (only if not manual mode or file missing)
        if !config.appSpecific.useManualConfig || !fileManager.fileExists(atPath: tomlFileURL.path) {
            save()
        }
    }
    
    func save() {
        // 1. Save JSON for App State
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFileURL)
        }
        
        // 2. Generate TOML for Relay (ONLY if not using manual config)
        if !config.appSpecific.useManualConfig {
            let toml = generateTOML()
            try? toml.write(to: tomlFileURL, atomically: true, encoding: .utf8)
        }
    }
    
    func loadRawTOML() -> String {
        guard let data = try? Data(contentsOf: tomlFileURL),
              let str = String(data: data, encoding: .utf8) else {
            return generateTOML() // Fallback to current generated state
        }
        return str
    }
    
    func saveRawTOML(_ content: String) {
        try? content.write(to: tomlFileURL, atomically: true, encoding: .utf8)
        // If we are saving raw TOML, we infer manual mode might be desired, 
        // but we respect the explicit flag in settings. 
        // Ideally, the UI sets the flag.
    }
    
    func getConfigPath() -> String {
        return tomlFileURL.path
    }
    
    func getDataDirectory() -> URL {
        let dataDir = appSupportDir.appendingPathComponent("data")
        try? fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        return dataDir
    }
    
    private func generateTOML() -> String {
        return """
        # NostrRelayApp Configuration
        # Generated: \(Date())

        [info]
        relay_url = "\(config.url)"
        name = "\(config.name)"
        description = "\(config.description)"
        pubkey = "\(config.pubkey)"
        contact = "\(config.contact)"
        relay_icon = "\(config.icon)"

        [network]
        address = "\(config.bindAddress)"
        port = \(config.port)

        [database]
        engine = "sqlite"
        data_directory = "\(getDataDirectory().path)"

        [limits]
        max_event_bytes = \(config.maxEventSize)
        max_ws_message_bytes = \(config.maxWSMessageBytes)
        max_ws_frame_bytes = \(config.maxWSFrameBytes)

        [logging]
        # We don't set a folder path here because we capture stdout/stderr directly from the process
        # But we can set log level via env var RUST_LOG
        
        [options]
        reject_future_seconds = 1800

        [spam_filter]
        enabled = \(config.spamFilterEnabled)
        blocked_pubkeys = [\(config.blockedPubkeys.map { "\"\($0)\"" }.joined(separator: ", "))]
        blocked_keywords = [\(config.blockedKeywords.map { "\"\($0)\"" }.joined(separator: ", "))]
        """
    }
}
