import Foundation
import Combine

@MainActor
class RelayService: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var isServerReady: Bool = false
    @Published var statusMessage: String = "Stopped"
    @Published var logs: [LogMessage] = []
    
    struct LogMessage: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let message: String
        let type: LogType
        
        enum LogType {
            case info, warning, error
        }
    }
    
    private var process: Process?
    private var stdoutPipe: Pipe?
    
    func start(configService: ConfigurationService) {
        // 1. Pre-flight check
        guard !isRunning else { return }
        isRunning = true // Prevent re-entry immediately
        isServerReady = false
        statusMessage = "Starting..."
        
        // 2. Locate Binary
        guard let binaryPath = Bundle.main.path(forResource: "nostr-rs-relay", ofType: "") else {
            appendLog("Could not find nostr-rs-relay binary.", type: .error)
            statusMessage = "Error: Binary missing"
            isRunning = false
            return
        }
        
        // 3. Prepare logic on background thread
        Task.detached(priority: .userInitiated) {
            // Kill old processes
            self.killStaleProcesses()
            
            // Wait for ports to release (2 seconds)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            await MainActor.run {
                self.launchProcess(binaryPath: binaryPath, configPath: configService.getConfigPath())
            }
        }
    }
    
    func stop() {
        guard let process = process, process.isRunning else { return }
        process.terminate()
        isRunning = false
        isServerReady = false
        statusMessage = "Stopped"
        appendLog("Relay stopped.", type: .info)
    }
    
    private func launchProcess(binaryPath: String, configPath: String) {
        // Permissions
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--config", configPath]
        
        // CWD to config location
        let configDir = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        process.currentDirectoryURL = configDir
        
        // Environment
        var env = ProcessInfo.processInfo.environment
        env["RUST_LOG"] = "info,nostr_rs_relay=info"
        process.environment = env
        
        // Piping
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.stdoutPipe = pipe
        
        // Output Handler
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                Task { @MainActor [weak self] in
                    self?.parseOutput(text)
                }
            }
        }
        
        // Termination Handler
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.statusMessage = "Terminated (Code: \(proc.terminationStatus))"
                self?.appendLog("Process exit: \(proc.terminationStatus)", type: .warning)
                self?.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            }
        }
        
        self.process = process
        
        do {
            try process.run()
            self.isRunning = true
            self.statusMessage = "Running"
            appendLog("Relay started successfully.", type: .info)
        } catch {
            self.statusMessage = "Failed to start"
            appendLog("Failed to run process: \(error.localizedDescription)", type: .error)
        }
    }

    private func parseOutput(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            let cleanLine = stripANSI(line)
            var type: LogMessage.LogType = .info
            if cleanLine.contains("ERROR") { type = .error }
            if cleanLine.contains("WARN") { type = .warning }
            if cleanLine.contains("panicked") { type = .error }
            
            if cleanLine.contains("control message listener started") {
                Task { @MainActor in
                    self.isServerReady = true
                    self.statusMessage = "Running (Ready)"
                }
            }
            
            appendLog(cleanLine, type: type)
        }
    }
    
    private func stripANSI(_ string: String) -> String {
        return string.replacingOccurrences(of: "\\x1B\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
    }
    
    private func appendLog(_ message: String, type: LogMessage.LogType) {
        let log = LogMessage(date: Date(), message: message, type: type)
        logs.append(log)
        // Keep logs bounded
        if logs.count > 1000 {
            logs.removeFirst(100)
        }
    }
    
    nonisolated private func killStaleProcesses() {
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        // Use pkill -9 -U <uid> to force kill only OUR instances
        task.arguments = ["-9", "-U", "\(getuid())", "nostr-rs-relay"]
        
        // Silence output (prevents "Unable to obtain a task name port right" noise)
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        
        try? task.run()
        task.waitUntilExit()
    }
}
