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

// Lenient decoding. Swift's synthesized init(from:) throws keyNotFound for any key
// missing from the stored JSON, even when the property has a default value — so
// adding a field to RelayConfig would silently reset every saved setting back to
// its default. Decoding key by key keeps older settings.json files readable.
extension RelayConfig {
    // Keys written by earlier versions that no longer map to a property.
    private enum LegacyKeys: String, CodingKey {
        case maxMessageSize // v1.2: split into maxWSMessageBytes / maxWSFrameBytes
    }

    init(from decoder: Decoder) throws {
        self.init() // start from the defaults above
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let v = try c.decodeIfPresent(String.self, forKey: .name) { name = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .description) { description = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .pubkey) { pubkey = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .contact) { contact = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .url) { url = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .icon) { icon = v }

        if let v = try c.decodeIfPresent(String.self, forKey: .bindAddress) { bindAddress = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .port) { port = v }

        if let v = try c.decodeIfPresent(Int.self, forKey: .maxEventSize) { maxEventSize = v }

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let legacyMessageSize = try legacy.decodeIfPresent(Int.self, forKey: .maxMessageSize)
        if let v = try c.decodeIfPresent(Int.self, forKey: .maxWSMessageBytes) ?? legacyMessageSize {
            maxWSMessageBytes = v
        }
        if let v = try c.decodeIfPresent(Int.self, forKey: .maxWSFrameBytes) ?? legacyMessageSize {
            maxWSFrameBytes = v
        }

        if let v = try c.decodeIfPresent(Bool.self, forKey: .spamFilterEnabled) { spamFilterEnabled = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .blockedPubkeys) { blockedPubkeys = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .blockedKeywords) { blockedKeywords = v }

        if let v = try c.decodeIfPresent(AppSpecific.self, forKey: .appSpecific) { appSpecific = v }
    }
}

extension RelayConfig.AppSpecific {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) { launchAtLogin = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .autoStart) { autoStart = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .useManualConfig) { useManualConfig = v }
    }
}

enum ConfigError: LocalizedError {
    case encodeFailed(underlying: Error)
    case writeFailed(path: String, underlying: Error)
    case readFailed(path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let underlying):
            return "Could not encode settings: \(underlying.localizedDescription)"
        case .writeFailed(let path, let underlying):
            return "Could not write \(path): \(underlying.localizedDescription)"
        case .readFailed(let path, let underlying):
            return "Could not read \(path): \(underlying.localizedDescription)"
        }
    }
}

@MainActor
class ConfigurationService: ObservableObject {
    @Published var config: RelayConfig

    /// Non-nil when the last save or load failed. Surfaced in Settings so that a
    /// failed write is visible instead of being swallowed by `try?`.
    @Published var lastError: String?
    @Published var lastSavedAt: Date?

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
        do {
            try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        } catch {
            self.lastError = ConfigError.writeFailed(path: appSupportDir.path, underlying: error).localizedDescription
        }

        // Load config
        self.config = RelayConfig()
        if fileManager.fileExists(atPath: configFileURL.path) {
            do {
                let data = try Data(contentsOf: configFileURL)
                self.config = try JSONDecoder().decode(RelayConfig.self, from: data)
            } catch {
                // Keep the defaults, but say so rather than pretending the file was empty.
                self.lastError = ConfigError.readFailed(path: configFileURL.path, underlying: error).localizedDescription
            }
        }

        // Materialise config.toml only when it is missing. Regenerating it on every
        // launch silently discarded hand-edited TOML.
        //
        // This writes the TOML directly rather than calling save(), on purpose:
        // save() would also rewrite settings.json with the defaults we just fell
        // back to — destroying a settings.json we failed to read — and would clear
        // the load error before the user ever saw it. An unreadable settings.json
        // now survives until the user explicitly saves over it.
        if !fileManager.fileExists(atPath: tomlFileURL.path) {
            do {
                try generateTOML().write(to: tomlFileURL, atomically: true, encoding: .utf8)
            } catch {
                self.lastError = ConfigError.writeFailed(path: tomlFileURL.path, underlying: error).localizedDescription
            }
        }
    }

    /// Persists settings.json and, unless manual mode is on, regenerates config.toml.
    /// Returns false and populates `lastError` when anything failed to write.
    @discardableResult
    func save() -> Bool {
        do {
            try performSave()
            lastError = nil
            lastSavedAt = Date()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func performSave() throws {
        // 1. Save JSON for App State
        let data: Data
        do {
            data = try JSONEncoder().encode(config)
        } catch {
            throw ConfigError.encodeFailed(underlying: error)
        }

        do {
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            throw ConfigError.writeFailed(path: configFileURL.path, underlying: error)
        }

        // 2. Generate TOML for Relay (ONLY if not using manual config, or if the
        // file is missing entirely — the relay needs something to launch with).
        if !config.appSpecific.useManualConfig || !fileManager.fileExists(atPath: tomlFileURL.path) {
            do {
                try generateTOML().write(to: tomlFileURL, atomically: true, encoding: .utf8)
            } catch {
                throw ConfigError.writeFailed(path: tomlFileURL.path, underlying: error)
            }
        }
    }

    func loadRawTOML() -> String {
        guard fileManager.fileExists(atPath: tomlFileURL.path) else {
            return generateTOML() // Nothing on disk yet: show what we would write
        }
        do {
            let data = try Data(contentsOf: tomlFileURL)
            guard let str = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            lastError = nil
            return str
        } catch {
            lastError = ConfigError.readFailed(path: tomlFileURL.path, underlying: error).localizedDescription
            return generateTOML()
        }
    }

    /// Writes config.toml verbatim. Returns false and populates `lastError` on failure.
    @discardableResult
    func saveRawTOML(_ content: String) -> Bool {
        do {
            try content.write(to: tomlFileURL, atomically: true, encoding: .utf8)
            lastError = nil
            lastSavedAt = Date()
            return true
        } catch {
            lastError = ConfigError.writeFailed(path: tomlFileURL.path, underlying: error).localizedDescription
            return false
        }
    }

    func getConfigPath() -> String {
        return tomlFileURL.path
    }

    func getDataDirectory() -> URL {
        let dataDir = appSupportDir.appendingPathComponent("data")
        try? fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        return dataDir
    }

    /// Escapes a value for a TOML basic string. Without this, a quote or backslash in
    /// a pubkey, keyword or path produces invalid TOML and the relay refuses to start.
    private func tomlEscape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private func tomlStringArray(_ values: [String]) -> String {
        return values.map { "\"\(tomlEscape($0))\"" }.joined(separator: ", ")
    }

    private func generateTOML() -> String {
        return """
        # NostrRelayApp Configuration
        # Generated: \(Date())

        [info]
        relay_url = "\(tomlEscape(config.url))"
        name = "\(tomlEscape(config.name))"
        description = "\(tomlEscape(config.description))"
        pubkey = "\(tomlEscape(config.pubkey))"
        contact = "\(tomlEscape(config.contact))"
        relay_icon = "\(tomlEscape(config.icon))"

        [network]
        address = "\(tomlEscape(config.bindAddress))"
        port = \(config.port)

        [database]
        engine = "sqlite"
        data_directory = "\(tomlEscape(getDataDirectory().path))"

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
        blocked_pubkeys = [\(tomlStringArray(config.blockedPubkeys))]
        blocked_keywords = [\(tomlStringArray(config.blockedKeywords))]
        """
    }
}
