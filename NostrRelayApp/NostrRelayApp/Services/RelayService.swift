import Foundation
import AppKit
import Combine

@MainActor
class RelayService: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var isServerReady: Bool = false
    @Published var statusMessage: String = "Stopped"
    @Published var logs: [LogMessage] = []

    /// PID of the live relay process, for process-level stats and socket lookups.
    @Published private(set) var processID: Int32?
    /// When the current process was launched; the dashboard derives uptime from it.
    @Published private(set) var startedAt: Date?
    /// Counts every launch this app session, so flapping is visible.
    @Published private(set) var startCount: Int = 0
    @Published private(set) var lastExitCode: Int32?

    /// Running totals over the app session, for the dashboard health panel.
    @Published private(set) var warningCount: Int = 0
    @Published private(set) var errorCount: Int = 0
    @Published private(set) var lastError: String?

    var uptime: TimeInterval? {
        guard isRunning, let startedAt = startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    struct LogMessage: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let message: String
        let type: LogType
        var count: Int = 1

        enum LogType {
            case info, warning, error
        }
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var isStarting = false

    // Log batching: buffer incoming lines and flush to the UI at most twice per second
    private var pendingLogs: [LogMessage] = []
    private var logFlushTimer: Timer?
    private let maxLogLines = 500

    private var readinessTask: Task<Void, Never>?

    init() {
        // Quitting the app must take the relay down with it. Nothing in the
        // SwiftUI quit path calls stop(), and a Process child outlives its
        // parent on macOS — the orphan keeps the port and the DB open.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let process = self.process, process.isRunning else { return }
                process.terminate()
                // Give the relay a moment to checkpoint its WAL before the app
                // exits, but never wedge the quit — past the deadline it keeps
                // shutting down on its own, and killStaleProcesses() reaps any
                // leftover on next start.
                let deadline = Date().addingTimeInterval(10)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
    }

    func start(configService: ConfigurationService) {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        isServerReady = false
        statusMessage = "Starting..."

        guard let binaryPath = Bundle.main.path(forResource: "nostr-rs-relay", ofType: "") else {
            appendLog("Could not find nostr-rs-relay binary.", type: .error)
            statusMessage = "Error: Binary missing"
            isStarting = false
            return
        }

        let port = UInt16(configService.config.port)
        let configPath = configService.getConfigPath()
        let verbose = configService.config.appSpecific.verboseLogging

        Task.detached(priority: .userInitiated) {
            // Kill old processes, then wait until the port is actually free
            Self.killStaleProcesses()
            let portFree = await Self.waitForPortFree(port, timeout: 6.0)

            await MainActor.run {
                if !portFree {
                    self.appendLog("Port \(port) is still in use; starting anyway.", type: .warning)
                }
                self.launchProcess(binaryPath: binaryPath, configPath: configPath, port: port, verbose: verbose)
                self.isStarting = false
            }
        }
    }

    func stop() {
        readinessTask?.cancel()
        readinessTask = nil
        guard let process = process, process.isRunning else {
            isRunning = false
            isServerReady = false
            processID = nil
            startedAt = nil
            statusMessage = "Stopped"
            return
        }
        process.terminate()
        isRunning = false
        isServerReady = false
        processID = nil
        startedAt = nil
        statusMessage = "Stopped"
        appendLog("Relay stopped.", type: .info)
    }

    private func launchProcess(binaryPath: String, configPath: String, port: UInt16, verbose: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--config", configPath]

        let configDir = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        process.currentDirectoryURL = configDir

        var env = ProcessInfo.processInfo.environment
        // Quiet by default: INFO logs every connection which burns CPU on busy relays.
        env["RUST_LOG"] = verbose ? "info,nostr_rs_relay=info" : "warn,nostr_rs_relay=warn"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.stdoutPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                Task { @MainActor [weak self] in
                    self?.parseOutput(text)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Ignore termination of an old process that has been replaced
                guard proc === self.process else { return }
                self.readinessTask?.cancel()
                self.readinessTask = nil
                self.isRunning = false
                self.isServerReady = false
                self.processID = nil
                self.startedAt = nil
                self.lastExitCode = proc.terminationStatus
                self.statusMessage = "Terminated (Code: \(proc.terminationStatus))"
                self.appendLog("Process exit: \(proc.terminationStatus)", type: .warning)
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            }
        }

        self.process = process

        do {
            try process.run()
            self.isRunning = true
            self.processID = process.processIdentifier
            self.startedAt = Date()
            self.startCount += 1
            self.statusMessage = "Running"
            appendLog("Relay started successfully.", type: .info)
            startReadinessProbe(port: port)
        } catch {
            self.statusMessage = "Failed to start"
            appendLog("Failed to run process: \(error.localizedDescription)", type: .error)
        }
    }

    /// Poll the relay's HTTP endpoint until it responds, instead of relying on
    /// INFO log lines (which are disabled unless verbose logging is on).
    private func startReadinessProbe(port: UInt16) {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
            for _ in 0..<30 { // up to ~15s
                if Task.isCancelled { return }
                var request = URLRequest(url: url, timeoutInterval: 1.0)
                request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse) != nil {
                    await MainActor.run {
                        guard let self = self, self.isRunning else { return }
                        self.isServerReady = true
                        self.statusMessage = "Running (Ready)"
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
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
                // Fast-path readiness when verbose logging is on
                isServerReady = true
                statusMessage = "Running (Ready)"
            }

            appendLog(cleanLine, type: type)
        }
    }

    private static let ansiRegex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[a-zA-Z]")

    private func stripANSI(_ string: String) -> String {
        // Fast path: most lines have no escape codes at all
        guard string.utf8.contains(0x1B), let regex = Self.ansiRegex else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
    }

    private func appendLog(_ message: String, type: LogMessage.LogType) {
        // Track severity totals for the dashboard health panel. Counted per line
        // (including coalesced repeats) so a flood registers at its true volume.
        switch type {
        case .warning: warningCount += 1
        case .error:
            errorCount += 1
            lastError = message
        case .info: break
        }

        // Coalesce repeated identical lines into one entry with a counter,
        // so floods (spam waves, crash loops) don't bury the log view.
        if let lastIndex = pendingLogs.indices.last,
           pendingLogs[lastIndex].message == message,
           pendingLogs[lastIndex].type == type {
            pendingLogs[lastIndex].count += 1
        } else {
            pendingLogs.append(LogMessage(date: Date(), message: message, type: type))
        }
        scheduleLogFlush()
    }

    private func scheduleLogFlush() {
        guard logFlushTimer == nil else { return }
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushLogs()
            }
        }
    }

    private func flushLogs() {
        logFlushTimer = nil
        guard !pendingLogs.isEmpty else { return }
        // Merge across the flush boundary too, so a line repeating slowly
        // (once per flush) still collapses into a single row.
        if let lastIndex = logs.indices.last,
           logs[lastIndex].message == pendingLogs[0].message,
           logs[lastIndex].type == pendingLogs[0].type {
            logs[lastIndex].count += pendingLogs[0].count
            pendingLogs.removeFirst()
        }
        logs.append(contentsOf: pendingLogs)
        pendingLogs.removeAll(keepingCapacity: true)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    nonisolated private static func killStaleProcesses() {
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

    /// Returns true once the port can be bound (i.e. the old process released it).
    nonisolated private static func waitForPortFree(_ port: UInt16, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPortFree(port) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isPortFree(port)
    }

    nonisolated private static func isPortFree(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
