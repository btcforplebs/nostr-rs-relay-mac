import Foundation

/// Collects everything about the relay that lives outside its metrics endpoint:
/// OS process cost, the live TCP peer list, and the relay's own NIP-11 document.
///
/// All shell-outs run off the main actor on a utility queue; each has a short
/// timeout so a hung `lsof` can never stall the dashboard.
@MainActor
class SystemStatsService: ObservableObject {

    struct ProcessStats: Equatable {
        var pid: Int32? = nil
        var cpuPercent: Double? = nil
        var residentBytes: Int64? = nil
        var virtualBytes: Int64? = nil
        var threadCount: Int? = nil
        var elapsed: String? = nil
        var isAlive: Bool = false
    }

    struct Peer: Identifiable, Equatable {
        var id: String { ip }
        let ip: String
        /// Number of established sockets this address currently holds.
        let count: Int
    }

    struct PeerStats: Equatable {
        /// Established inbound websocket sockets on the relay's port.
        var establishedCount: Int = 0
        var listenerCount: Int = 0
        /// Busiest remote addresses first.
        var topPeers: [Peer] = []
        var uniquePeers: Int = 0
        /// True when at least one peer is not on the loopback interface.
        var hasExternalPeers: Bool = false
    }

    /// The relay's NIP-11 relay information document.
    struct RelayInfo: Codable, Equatable {
        var name: String?
        var description: String?
        var pubkey: String?
        var contact: String?
        var supported_nips: [Int]?
        var software: String?
        var version: String?
        var limitation: Limitation?

        struct Limitation: Codable, Equatable {
            var max_message_length: Int?
            var max_subscriptions: Int?
            var max_filters: Int?
            var max_limit: Int?
            var max_subid_length: Int?
            var max_event_tags: Int?
            var max_content_length: Int?
            var min_pow_difficulty: Int?
            var auth_required: Bool?
            var payment_required: Bool?
            var created_at_lower_limit: Int64?
            var created_at_upper_limit: Int64?
        }
    }

    struct HostStats: Equatable {
        var diskFreeBytes: Int64? = nil
        var diskTotalBytes: Int64? = nil
        var physicalMemoryBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
        var activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
        var thermalState: String = "Nominal"
        var systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    }

    @Published private(set) var process = ProcessStats()
    @Published private(set) var peers = PeerStats()
    @Published private(set) var relayInfo: RelayInfo?
    @Published private(set) var host = HostStats()

    private var timer: Timer?
    private var inFlight = false
    /// NIP-11 is static for the life of the process; fetch it once per start.
    private var fetchedInfoForPort: Int?

    func startPolling(pid: Int32?, port: Int, dataDirectory: URL, interval: TimeInterval = 5.0) {
        stopPolling()
        refresh(pid: pid, port: port, dataDirectory: dataDirectory)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(pid: pid, port: port, dataDirectory: dataDirectory)
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        process = ProcessStats()
        peers = PeerStats()
        relayInfo = nil
        fetchedInfoForPort = nil
    }

    func refresh(pid: Int32?, port: Int, dataDirectory: URL) {
        guard !inFlight else { return }
        inFlight = true

        if fetchedInfoForPort != port {
            Task { await fetchRelayInfo(port: port) }
        }

        Task.detached(priority: .utility) {
            let processStats = pid.map { Self.readProcessStats(pid: $0) } ?? ProcessStats()
            let peerStats = Self.readPeerStats(pid: pid, port: port)
            let hostStats = Self.readHostStats(dataDirectory: dataDirectory)

            await MainActor.run {
                self.process = processStats
                self.peers = peerStats
                self.host = hostStats
                self.inFlight = false
            }
        }
    }

    // MARK: - Process

    nonisolated private static func readProcessStats(pid: Int32) -> ProcessStats {
        var stats = ProcessStats()
        stats.pid = pid

        // `=` suffixes suppress the header row, giving a single whitespace-
        // separated line: %cpu rss vsz etime
        guard let out = shell("/bin/ps", ["-o", "%cpu=,rss=,vsz=,etime=", "-p", "\(pid)"]),
              !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return stats
        }

        let fields = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        if fields.count >= 4 {
            stats.isAlive = true
            stats.cpuPercent = Double(fields[0])
            // ps reports rss/vsz in kilobytes.
            stats.residentBytes = Int64(fields[1]).map { $0 * 1024 }
            stats.virtualBytes = Int64(fields[2]).map { $0 * 1024 }
            stats.elapsed = fields[3]
        }

        // `ps -M` lists one row per thread after a header line.
        if let threadsOut = shell("/bin/ps", ["-M", "-p", "\(pid)"]) {
            let lines = threadsOut.split(separator: "\n").filter { !$0.isEmpty }
            stats.threadCount = max(0, lines.count - 1)
        }

        return stats
    }

    // MARK: - Sockets

    nonisolated private static func readPeerStats(pid: Int32?, port: Int) -> PeerStats {
        // Scope lsof to the relay process when we know it — that is far cheaper
        // than scanning every socket on the machine.
        var args = ["-nP", "-w"]
        if let pid = pid {
            args += ["-a", "-p", "\(pid)"]
        }
        args += ["-iTCP:\(port)"]

        guard let out = shell("/usr/sbin/lsof", args, timeout: 3.0) else { return PeerStats() }
        return parsePeerOutput(out)
    }

    /// Parses `lsof -nP` output. Rows look like:
    /// `nostr-rs- 15617 user 23u IPv4 0x… 0t0 TCP 127.0.0.1:8080->127.0.0.1:59272 (ESTABLISHED)`
    nonisolated static func parsePeerOutput(_ out: String) -> PeerStats {
        var stats = PeerStats()
        var counts: [String: Int] = [:]

        for line in out.split(separator: "\n").dropFirst() { // drop header
            if line.contains("(LISTEN)") {
                stats.listenerCount += 1
                continue
            }
            // Sockets in teardown (CLOSE_WAIT, FIN_WAIT) are not live clients.
            guard line.contains("(ESTABLISHED)") else { continue }
            stats.establishedCount += 1

            guard let arrow = line.range(of: "->") else { continue }
            let remote = line[arrow.upperBound...]
                .split(separator: " ").first.map(String.init) ?? ""
            let ip = remoteIP(from: remote)
            guard !ip.isEmpty else { continue }
            counts[ip, default: 0] += 1
        }

        stats.uniquePeers = counts.count
        stats.hasExternalPeers = counts.keys.contains { !isLoopback($0) }
        stats.topPeers = counts
            .map { Peer(ip: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.ip < $1.ip }
            .prefix(6)
            .map { $0 }

        return stats
    }

    /// Strips the port from `1.2.3.4:5678` and from bracketed IPv6 `[::1]:5678`.
    nonisolated private static func remoteIP(from endpoint: String) -> String {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[..<colon])
    }

    nonisolated private static func isLoopback(_ ip: String) -> Bool {
        ip == "::1" || ip == "localhost" || ip.hasPrefix("127.")
    }

    // MARK: - Host

    nonisolated private static func readHostStats(dataDirectory: URL) -> HostStats {
        var stats = HostStats()
        let info = ProcessInfo.processInfo
        stats.systemUptime = info.systemUptime
        stats.physicalMemoryBytes = Int64(info.physicalMemory)
        stats.activeProcessorCount = info.activeProcessorCount

        switch info.thermalState {
        case .nominal: stats.thermalState = "Nominal"
        case .fair: stats.thermalState = "Fair"
        case .serious: stats.thermalState = "Serious"
        case .critical: stats.thermalState = "Critical"
        @unknown default: stats.thermalState = "Unknown"
        }

        if let values = try? dataDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]) {
            stats.diskFreeBytes = values.volumeAvailableCapacityForImportantUsage
            stats.diskTotalBytes = values.volumeTotalCapacity.map(Int64.init)
        }
        return stats
    }

    // MARK: - NIP-11

    private func fetchRelayInfo(port: Int) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        var request = URLRequest(url: url, timeoutInterval: 3.0)
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let info = try? JSONDecoder().decode(RelayInfo.self, from: data) else { return }

        relayInfo = info
        fetchedInfoForPort = port
    }

    // MARK: - Shell helper

    /// Runs a command and returns stdout, or nil on failure/timeout.
    nonisolated private static func shell(
        _ path: String,
        _ args: [String],
        timeout: TimeInterval = 2.0
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if task.isRunning {
            task.terminate()
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
