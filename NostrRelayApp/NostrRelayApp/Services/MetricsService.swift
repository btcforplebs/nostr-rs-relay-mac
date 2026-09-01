import Foundation

/// Scrapes the relay's built-in Prometheus endpoint (`/metrics`) and turns the
/// raw counters into dashboard-ready gauges, rates and latency percentiles.
///
/// The relay exposes counters (monotonic totals). Anything a human wants to see
/// per-second is derived here by differencing consecutive scrapes, so the UI
/// never has to remember previous values.
@MainActor
class MetricsService: ObservableObject {

    // MARK: - Parsed Prometheus exposition

    /// One `name{labels} value` line from the exposition format.
    struct Sample {
        let name: String
        let labels: [String: String]
        let value: Double
    }

    struct Scrape {
        var samples: [Sample] = []
        var at: Date = Date()

        /// Total across every label combination of a metric.
        func total(_ name: String) -> Double {
            samples.reduce(0) { $0 + ($1.name == name ? $1.value : 0) }
        }

        /// Value for one exact label pair, e.g. `sent_events{source="db"}`.
        func value(_ name: String, _ label: String, _ labelValue: String) -> Double {
            samples.first { $0.name == name && $0.labels[label] == labelValue }?.value ?? 0
        }

        /// Every label value of a metric with its count, largest first.
        func breakdown(_ name: String, by label: String) -> [(key: String, value: Double)] {
            samples
                .filter { $0.name == name && $0.labels[label] != nil }
                .map { (key: $0.labels[label]!, value: $0.value) }
                .sorted { $0.value > $1.value }
        }

        /// Histogram buckets (cumulative) sorted by upper bound.
        func buckets(_ name: String) -> [(le: Double, count: Double)] {
            samples
                .filter { $0.name == "\(name)_bucket" }
                .compactMap { s -> (le: Double, count: Double)? in
                    guard let leStr = s.labels["le"] else { return nil }
                    let le = leStr == "+Inf" ? Double.infinity : Double(leStr) ?? Double.infinity
                    return (le: le, count: s.value)
                }
                .sorted { $0.le < $1.le }
        }
    }

    /// A latency histogram reduced to the numbers a dashboard shows.
    struct Latency: Equatable {
        var count: Double = 0
        var sum: Double = 0
        /// Mean over the process lifetime.
        var mean: Double { count > 0 ? sum / count : 0 }
        var p50: Double = 0
        var p95: Double = 0
        var p99: Double = 0
        var hasData: Bool { count > 0 }
    }

    /// Everything the dashboard reads. Rates are per second unless named otherwise.
    struct Snapshot: Equatable {
        // Connections
        var connectionsTotal: Double = 0
        var disconnectsTotal: Double = 0
        var disconnectsByReason: [String: Double] = [:]
        /// Connections opened minus closed — the relay's live websocket count.
        var activeConnections: Double = 0
        var connectionsPerMin: Double = 0

        // Client commands
        var cmdEvent: Double = 0
        var cmdReq: Double = 0
        var cmdClose: Double = 0
        var cmdAuth: Double = 0
        var cmdEventRate: Double = 0
        var cmdReqRate: Double = 0
        var cmdCloseRate: Double = 0
        var cmdAuthRate: Double = 0

        // Outbound events
        var sentEventsDB: Double = 0
        var sentEventsRealtime: Double = 0
        var sentEventsTotal: Double { sentEventsDB + sentEventsRealtime }
        var sentEventsRate: Double = 0

        // Queries
        var queryAborts: [String: Double] = [:]
        var queryAbortsTotal: Double = 0
        var dbPoolConnections: Double = 0

        // Latency
        var subscriptionLatency = Latency()
        var filterLatency = Latency()
        var writeLatency = Latency()

        var lastScrape: Date? = nil
        var isReachable: Bool = false
        var lastError: String? = nil
    }

    /// One point of rolling history, for the sparklines.
    struct HistoryPoint: Identifiable {
        let id = UUID()
        let at: Date
        let eventsIn: Double
        let eventsOut: Double
        let requests: Double
        let connections: Double
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var history: [HistoryPoint] = []

    /// Kept so a dropped scrape doesn't blank the dashboard mid-refresh.
    private var previousScrape: Scrape?
    private var pollTimer: Timer?
    private var inFlight = false
    private let maxHistory = 120 // ~4 min at a 2s cadence

    // MARK: - Polling

    func startPolling(port: Int, interval: TimeInterval = 2.0) {
        stopPolling()
        Task { await scrape(port: port) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scrape(port: port)
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Clears derived state so a relay restart doesn't show a huge negative rate.
    func reset() {
        previousScrape = nil
        history.removeAll()
        snapshot = Snapshot()
    }

    private func scrape(port: Int) async {
        guard !inFlight else { return }
        guard let url = URL(string: "http://127.0.0.1:\(port)/metrics") else { return }
        inFlight = true
        defer { inFlight = false }

        var request = URLRequest(url: url, timeoutInterval: 3.0)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let text = String(data: data, encoding: .utf8) else { return }
            let scrape = Self.parse(text)
            apply(scrape)
        } catch {
            snapshot.isReachable = false
            snapshot.lastError = error.localizedDescription
        }
    }

    // MARK: - Exposition parsing

    /// Parses the Prometheus text exposition format. Comment lines (`# HELP`,
    /// `# TYPE`) are skipped; everything else is `name[{labels}] value`.
    nonisolated static func parse(_ text: String) -> Scrape {
        var samples: [Sample] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // Split the value off the end: everything after the last space that
            // is not inside the label braces.
            guard let lastSpace = line.lastIndex(of: " ") else { continue }
            let valuePart = line[line.index(after: lastSpace)...]
            guard let value = Double(valuePart) else { continue }
            let namePart = line[..<lastSpace].trimmingCharacters(in: .whitespaces)

            if let braceStart = namePart.firstIndex(of: "{"),
               let braceEnd = namePart.lastIndex(of: "}") {
                let name = String(namePart[..<braceStart])
                let labelBody = namePart[namePart.index(after: braceStart)..<braceEnd]
                samples.append(Sample(name: name, labels: parseLabels(String(labelBody)), value: value))
            } else {
                samples.append(Sample(name: namePart, labels: [:], value: value))
            }
        }

        return Scrape(samples: samples, at: Date())
    }

    /// `reason="normal",source="db"` -> dictionary. Values are always quoted by
    /// the Rust client, and none of the relay's label values contain commas.
    nonisolated private static func parseLabels(_ body: String) -> [String: String] {
        var labels: [String: String] = [:]
        for pair in body.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            labels[key] = value
        }
        return labels
    }

    // MARK: - Derivation

    private func apply(_ scrape: Scrape) {
        var s = Snapshot()
        s.isReachable = true
        s.lastError = nil
        s.lastScrape = scrape.at

        s.connectionsTotal = scrape.total("nostr_connections_total")
        s.disconnectsTotal = scrape.total("nostr_disconnects_total")
        s.disconnectsByReason = Dictionary(
            scrape.breakdown("nostr_disconnects_total", by: "reason").map { ($0.key, $0.value) },
            uniquingKeysWith: { a, _ in a }
        )
        // A connection that opened and never recorded a disconnect is still live.
        s.activeConnections = max(0, s.connectionsTotal - s.disconnectsTotal)

        s.cmdEvent = scrape.total("nostr_cmd_event_total")
        s.cmdReq = scrape.total("nostr_cmd_req_total")
        s.cmdClose = scrape.total("nostr_cmd_close_total")
        s.cmdAuth = scrape.total("nostr_cmd_auth_total")

        s.sentEventsDB = scrape.value("nostr_events_sent_total", "source", "db")
        s.sentEventsRealtime = scrape.value("nostr_events_sent_total", "source", "realtime")

        s.queryAborts = Dictionary(
            scrape.breakdown("nostr_query_abort_total", by: "reason").map { ($0.key, $0.value) },
            uniquingKeysWith: { a, _ in a }
        )
        s.queryAbortsTotal = scrape.total("nostr_query_abort_total")
        s.dbPoolConnections = scrape.total("nostr_db_connections")

        s.subscriptionLatency = Self.latency(from: scrape, name: "nostr_query_seconds")
        s.filterLatency = Self.latency(from: scrape, name: "nostr_filter_seconds")
        s.writeLatency = Self.latency(from: scrape, name: "nostr_events_write_seconds")

        // Rates need a previous scrape to difference against.
        if let prev = previousScrape {
            let elapsed = scrape.at.timeIntervalSince(prev.at)
            if elapsed > 0.05 {
                func rate(_ name: String) -> Double {
                    // A restarted relay resets counters; clamp instead of showing negatives.
                    max(0, scrape.total(name) - prev.total(name)) / elapsed
                }
                s.cmdEventRate = rate("nostr_cmd_event_total")
                s.cmdReqRate = rate("nostr_cmd_req_total")
                s.cmdCloseRate = rate("nostr_cmd_close_total")
                s.cmdAuthRate = rate("nostr_cmd_auth_total")
                s.sentEventsRate = rate("nostr_events_sent_total")
                s.connectionsPerMin = rate("nostr_connections_total") * 60
            }
        }

        snapshot = s

        history.append(HistoryPoint(
            at: scrape.at,
            eventsIn: s.cmdEventRate,
            eventsOut: s.sentEventsRate,
            requests: s.cmdReqRate,
            connections: s.activeConnections
        ))
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }

        previousScrape = scrape
    }

    /// Reduces a Prometheus histogram to mean + interpolated percentiles.
    nonisolated private static func latency(from scrape: Scrape, name: String) -> Latency {
        var l = Latency()
        l.count = scrape.total("\(name)_count")
        l.sum = scrape.total("\(name)_sum")
        guard l.count > 0 else { return l }

        let buckets = scrape.buckets(name)
        l.p50 = percentile(0.50, buckets: buckets, total: l.count)
        l.p95 = percentile(0.95, buckets: buckets, total: l.count)
        l.p99 = percentile(0.99, buckets: buckets, total: l.count)
        return l
    }

    /// Standard histogram_quantile: find the bucket holding the rank, then
    /// interpolate linearly between its lower and upper bound.
    nonisolated private static func percentile(
        _ q: Double,
        buckets: [(le: Double, count: Double)],
        total: Double
    ) -> Double {
        guard total > 0, !buckets.isEmpty else { return 0 }
        let rank = q * total
        var lowerBound = 0.0
        var lowerCount = 0.0

        for bucket in buckets {
            if bucket.count >= rank {
                // The +Inf bucket has no finite upper bound to interpolate to.
                guard bucket.le.isFinite else { return lowerBound }
                let bucketCount = bucket.count - lowerCount
                guard bucketCount > 0 else { return bucket.le }
                let fraction = (rank - lowerCount) / bucketCount
                return lowerBound + (bucket.le - lowerBound) * fraction
            }
            lowerBound = bucket.le.isFinite ? bucket.le : lowerBound
            lowerCount = bucket.count
        }
        return lowerBound
    }
}
