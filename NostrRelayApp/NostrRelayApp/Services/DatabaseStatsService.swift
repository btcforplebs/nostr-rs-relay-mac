import Foundation

/// Reads on-disk size, storage internals and event statistics from the relay's
/// SQLite database.
///
/// Queries run read-only against the live database via the system sqlite3 CLI,
/// so they never block or lock the relay's writer. Every shell-out carries a
/// hard deadline and is SIGKILLed on expiry — a query that cannot finish on a
/// large database costs one bounded child process, never a wedged scanner.
///
/// Work is split by cost, not by wish:
/// - `light` (timer, 15s): O(1) pragmas, file sizes, rowid approximations and
///   index-backed lookups. Never touches unindexed columns.
/// - `activity` (same timer): indexed `created_at` range counts and buckets.
///   Runs as its own child so a slow week-window can't take the pragmas down.
/// - `deep` (on demand only): full-table scans — exact counts, DISTINCT
///   authors, content sizes, `first_seen` min/max. May take minutes on a big
///   database; the UI shows it running and reports a timeout honestly.
@MainActor
class DatabaseStatsService: ObservableObject {

    struct KindCount: Identifiable, Equatable {
        var id: Int { kind }
        let kind: Int
        let count: Int
    }

    struct AuthorCount: Identifiable, Equatable {
        var id: String { pubkey }
        let pubkey: String
        let count: Int
    }

    struct Bucket: Identifiable, Equatable {
        let id: Int
        let label: String
        let count: Int
    }

    struct Stats: Equatable {
        // Files on disk
        var databaseBytes: Int64 = 0
        var walBytes: Int64 = 0
        var shmBytes: Int64 = 0
        var totalBytes: Int64 { databaseBytes + walBytes + shmBytes }

        // Storage internals
        var pageCount: Int? = nil
        var pageSize: Int? = nil
        var freelistCount: Int? = nil
        var journalMode: String? = nil
        var schemaVersion: Int? = nil
        /// Share of allocated pages that are on the freelist — reclaimable by VACUUM.
        var fragmentationPercent: Double? {
            guard let pages = pageCount, pages > 0, let free = freelistCount else { return nil }
            return Double(free) / Double(pages) * 100
        }

        // Content — approximate (max rowid; free at any size, overcounts deletes)
        var eventCountApprox: Int? = nil
        var tagCountApprox: Int? = nil

        // Content — exact, deep scan only
        var eventCount: Int? = nil
        var tagCount: Int? = nil
        var hiddenCount: Int? = nil
        var expiringCount: Int? = nil
        var delegatedCount: Int? = nil
        var distinctAuthors: Int? = nil
        var distinctKinds: Int? = nil
        var contentBytes: Int64? = nil
        var avgEventBytes: Int? = nil
        var maxEventBytes: Int? = nil

        /// Best available event count: exact when a deep scan has run, else approximate.
        var bestEventCount: Int? { eventCount ?? eventCountApprox }
        var bestTagCount: Int? { tagCount ?? tagCountApprox }
        var eventCountIsApprox: Bool { eventCount == nil && eventCountApprox != nil }

        // Time span (created_at is indexed; first_seen is not → deep scan)
        var oldestCreatedAt: Date? = nil
        var newestCreatedAt: Date? = nil
        var firstSeen: Date? = nil
        var lastSeen: Date? = nil

        // Volume by author time (indexed created_at ranges)
        var eventsLastHour: Int? = nil
        var eventsLast24h: Int? = nil
        var eventsLast7d: Int? = nil

        // Distributions
        var topKinds: [KindCount] = []
        var topAuthors: [AuthorCount] = []
        var hourlyActivity: [Bucket] = []
        var dailyActivity: [Bucket] = []

        var lastLightRefresh: Date? = nil
        var lastDeepRefresh: Date? = nil
        /// The last attempt of each tier hit its deadline and was killed.
        var lightTimedOut: Bool = false
        var activityTimedOut: Bool = false
        var deepTimedOut: Bool = false
        var databaseExists: Bool = false

        /// Mean events per day over the observed 7-day window.
        var eventsPerDay: Double? {
            guard let week = eventsLast7d else { return nil }
            return Double(week) / 7.0
        }

        /// Average on-disk cost of one event, including tags and indexes.
        var bytesPerEvent: Int64? {
            guard let count = bestEventCount, count > 0 else { return nil }
            return databaseBytes / Int64(count)
        }
    }

    @Published private(set) var stats = Stats()
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDeepScanning = false

    private var refreshTimer: Timer?
    /// Live sqlite3 children, so stop/teardown can kill them instead of orphaning.
    private let children = ChildRegistry()

    nonisolated private static let lightTimeout: TimeInterval = 5
    nonisolated private static let deepTimeout: TimeInterval = 180

    deinit {
        refreshTimer?.invalidate()
        children.killAll()
    }

    // MARK: - Refresh

    /// `deep: true` additionally runs the full-scan tier. Deep scans only ever
    /// run from an explicit request — never from the timer.
    func refresh(dataDirectory: URL, deep: Bool = false) {
        refreshLight(dataDirectory: dataDirectory)
        if deep { runDeepScan(dataDirectory: dataDirectory) }
    }

    private func refreshLight(dataDirectory: URL) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let dbURL = dataDirectory.appendingPathComponent("nostr.db")
        let previous = stats
        let registry = children

        Task.detached(priority: .utility) {
            var result = previous
            result.databaseBytes = Self.fileSize(dbURL.path)
            result.walBytes = Self.fileSize(dbURL.path + "-wal")
            result.shmBytes = Self.fileSize(dbURL.path + "-shm")
            result.databaseExists = FileManager.default.fileExists(atPath: dbURL.path)

            if result.databaseExists {
                Self.applyLightStats(dbPath: dbURL.path, into: &result, registry: registry)
                Self.applyActivityStats(dbPath: dbURL.path, into: &result, registry: registry)
                if !result.lightTimedOut { result.lastLightRefresh = Date() }
            }

            let final = result
            await MainActor.run {
                self.stats = final
                self.isRefreshing = false
            }
        }
    }

    /// Full-table statistics. Explicit user action only; visible while running.
    func runDeepScan(dataDirectory: URL) {
        guard !isDeepScanning else { return }
        isDeepScanning = true
        let dbURL = dataDirectory.appendingPathComponent("nostr.db")
        let registry = children

        Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                await MainActor.run { self.isDeepScanning = false }
                return
            }
            // Two children so a timeout in one group still lands the other's rows.
            var counts = await MainActor.run { self.stats }
            let countsTimedOut = !Self.applyDeepCounts(dbPath: dbURL.path, into: &counts, registry: registry)
            let contentTimedOut = !Self.applyDeepContent(dbPath: dbURL.path, into: &counts, registry: registry)
            counts.deepTimedOut = countsTimedOut || contentTimedOut
            if !counts.deepTimedOut { counts.lastDeepRefresh = Date() }

            let final = counts
            await MainActor.run {
                // Keep whatever fresher light stats landed while we scanned.
                var merged = self.stats
                merged.eventCount = final.eventCount
                merged.tagCount = final.tagCount
                merged.hiddenCount = final.hiddenCount
                merged.delegatedCount = final.delegatedCount
                merged.distinctAuthors = final.distinctAuthors
                merged.distinctKinds = final.distinctKinds
                merged.contentBytes = final.contentBytes
                merged.avgEventBytes = final.avgEventBytes
                merged.maxEventBytes = final.maxEventBytes
                merged.firstSeen = final.firstSeen
                merged.lastSeen = final.lastSeen
                merged.topKinds = final.topKinds
                merged.topAuthors = final.topAuthors
                merged.deepTimedOut = final.deepTimedOut
                merged.lastDeepRefresh = final.lastDeepRefresh
                self.stats = merged
                self.isDeepScanning = false
            }
        }
    }

    /// Auto-refresh while a tab showing database stats is visible. Light tier only.
    func startAutoRefresh(dataDirectory: URL, interval: TimeInterval = 15) {
        stopAutoRefresh()
        refreshLight(dataDirectory: dataDirectory)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLight(dataDirectory: dataDirectory)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        children.killAll()
    }

    // MARK: - Queries

    /// O(1) or index-backed only: pragmas, rowid approximations, indexed
    /// min/max, and the expires_at partial range. Nothing here scales with
    /// table size.
    nonisolated private static func applyLightStats(dbPath: String, into result: inout Stats, registry: ChildRegistry) {
        let sql = """
        SELECT 'page_count', * FROM pragma_page_count();
        SELECT 'page_size', * FROM pragma_page_size();
        SELECT 'freelist', * FROM pragma_freelist_count();
        SELECT 'journal', * FROM pragma_journal_mode();
        SELECT 'schema_version', * FROM pragma_user_version();
        SELECT 'events_approx', coalesce(max(id), 0) FROM event;
        SELECT 'tags_approx', coalesce(max(id), 0) FROM tag;
        SELECT 'oldest', min(created_at) FROM event;
        SELECT 'newest', max(created_at) FROM event;
        SELECT 'expiring', count(*) FROM event WHERE expires_at IS NOT NULL;
        """

        switch query(dbPath: dbPath, sql: sql, timeout: lightTimeout, registry: registry) {
        case .rows(let output):
            result.lightTimedOut = false
            for row in rows(from: output) {
                guard let tag = row.first else { continue }
                switch tag {
                case "page_count":      result.pageCount = row.int(1)
                case "page_size":       result.pageSize = row.int(1)
                case "freelist":        result.freelistCount = row.int(1)
                case "journal":         result.journalMode = row.string(1)?.uppercased()
                case "schema_version":  result.schemaVersion = row.int(1)
                case "events_approx":   result.eventCountApprox = row.int(1)
                case "tags_approx":     result.tagCountApprox = row.int(1)
                case "oldest":          result.oldestCreatedAt = row.date(1)
                case "newest":          result.newestCreatedAt = row.date(1)
                case "expiring":        result.expiringCount = row.int(1)
                default: break
                }
            }
        case .timedOut:
            result.lightTimedOut = true
        case .failed:
            break
        }
    }

    /// Indexed created_at range counts and buckets. Costs scale with recent
    /// volume, not table size, but run as a separate child so a slow window
    /// can't starve the O(1) tier.
    nonisolated private static func applyActivityStats(dbPath: String, into result: inout Stats, registry: ChildRegistry) {
        let sql = """
        SELECT 'hour', count(*) FROM event WHERE created_at > strftime('%s','now') - 3600;
        SELECT 'day', count(*) FROM event WHERE created_at > strftime('%s','now') - 86400;
        SELECT 'week', count(*) FROM event WHERE created_at > strftime('%s','now') - 604800;
        SELECT 'hourly',
               cast((strftime('%s','now') - created_at) / 3600 AS INTEGER),
               count(*)
          FROM event
         WHERE created_at > strftime('%s','now') - 86400
         GROUP BY 2 ORDER BY 2;
        SELECT 'daily',
               cast((strftime('%s','now') - created_at) / 86400 AS INTEGER),
               count(*)
          FROM event
         WHERE created_at > strftime('%s','now') - 1209600
         GROUP BY 2 ORDER BY 2;
        """

        switch query(dbPath: dbPath, sql: sql, timeout: lightTimeout, registry: registry) {
        case .rows(let output):
            result.activityTimedOut = false
            // Buckets are keyed by "ages ago", so index 0 is the most recent.
            var hourly = [Int](repeating: 0, count: 24)
            var daily = [Int](repeating: 0, count: 14)

            for row in rows(from: output) {
                guard let tag = row.first else { continue }
                switch tag {
                case "hour": result.eventsLastHour = row.int(1)
                case "day":  result.eventsLast24h = row.int(1)
                case "week": result.eventsLast7d = row.int(1)
                case "hourly":
                    if let age = row.int(1), let c = row.int(2), age >= 0, age < 24 { hourly[age] = c }
                case "daily":
                    if let age = row.int(1), let c = row.int(2), age >= 0, age < 14 { daily[age] = c }
                default: break
                }
            }
            // Reverse so the charts read oldest -> newest, left to right.
            result.hourlyActivity = hourly.reversed().enumerated().map { index, count in
                Bucket(id: index, label: "\(24 - index)h ago", count: count)
            }
            result.dailyActivity = daily.reversed().enumerated().map { index, count in
                Bucket(id: index, label: "\(14 - index)d ago", count: count)
            }
        case .timedOut:
            result.activityTimedOut = true
        case .failed:
            break
        }
    }

    /// Exact counts and kind distribution. Returns false on timeout.
    nonisolated private static func applyDeepCounts(dbPath: String, into result: inout Stats, registry: ChildRegistry) -> Bool {
        let sql = """
        SELECT 'events', count(*) FROM event;
        SELECT 'tags', count(*) FROM tag;
        SELECT 'hidden', count(*) FROM event WHERE hidden = 1;
        SELECT 'delegated', count(*) FROM event WHERE delegated_by IS NOT NULL;
        SELECT 'kinds', count(DISTINCT kind) FROM event;
        SELECT 'kind', kind, count(*) FROM event GROUP BY kind ORDER BY 3 DESC LIMIT 8;
        """

        switch query(dbPath: dbPath, sql: sql, timeout: deepTimeout, registry: registry) {
        case .rows(let output):
            var kinds: [KindCount] = []
            for row in rows(from: output) {
                guard let tag = row.first else { continue }
                switch tag {
                case "events":    result.eventCount = row.int(1)
                case "tags":      result.tagCount = row.int(1)
                case "hidden":    result.hiddenCount = row.int(1)
                case "delegated": result.delegatedCount = row.int(1)
                case "kinds":     result.distinctKinds = row.int(1)
                case "kind":
                    if let k = row.int(1), let c = row.int(2) {
                        kinds.append(KindCount(kind: k, count: c))
                    }
                default: break
                }
            }
            result.topKinds = kinds
            return true
        case .timedOut:
            return false
        case .failed:
            return true
        }
    }

    /// Content sizes, author distribution and first_seen span. Returns false on timeout.
    nonisolated private static func applyDeepContent(dbPath: String, into result: inout Stats, registry: ChildRegistry) -> Bool {
        let sql = """
        SELECT 'authors', count(DISTINCT author) FROM event;
        SELECT 'content_bytes', coalesce(sum(length(content)), 0) FROM event;
        SELECT 'avg_bytes', coalesce(cast(avg(length(content)) AS INTEGER), 0) FROM event;
        SELECT 'max_bytes', coalesce(max(length(content)), 0) FROM event;
        SELECT 'first_seen', min(first_seen) FROM event;
        SELECT 'last_seen', max(first_seen) FROM event;
        SELECT 'author', substr(lower(hex(author)), 1, 16), count(*) FROM event
            GROUP BY author ORDER BY 3 DESC LIMIT 6;
        """

        switch query(dbPath: dbPath, sql: sql, timeout: deepTimeout, registry: registry) {
        case .rows(let output):
            var authors: [AuthorCount] = []
            for row in rows(from: output) {
                guard let tag = row.first else { continue }
                switch tag {
                case "authors":       result.distinctAuthors = row.int(1)
                case "content_bytes": result.contentBytes = row.int64(1)
                case "avg_bytes":     result.avgEventBytes = row.int(1)
                case "max_bytes":     result.maxEventBytes = row.int(1)
                case "first_seen":    result.firstSeen = row.date(1)
                case "last_seen":     result.lastSeen = row.date(1)
                case "author":
                    if let pk = row.string(1), let c = row.int(2) {
                        authors.append(AuthorCount(pubkey: pk, count: c))
                    }
                default: break
                }
            }
            result.topAuthors = authors
            return true
        case .timedOut:
            return false
        case .failed:
            return true
        }
    }

    // MARK: - Parsing helpers

    /// One result row, already split on the `|` separator.
    private struct Row {
        let fields: [String]
        var first: String? { fields.first }
        func string(_ i: Int) -> String? {
            guard i < fields.count, !fields[i].isEmpty else { return nil }
            return fields[i]
        }
        func int(_ i: Int) -> Int? { string(i).flatMap(Int.init) }
        func int64(_ i: Int) -> Int64? { string(i).flatMap(Int64.init) }
        func date(_ i: Int) -> Date? {
            guard let seconds = int64(i), seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
    }

    nonisolated private static func rows(from output: String) -> [Row] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "|")
            return fields.isEmpty ? nil : Row(fields: fields)
        }
    }

    nonisolated private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    // MARK: - Bounded shell-out

    enum QueryOutcome {
        case rows(String)
        case timedOut
        case failed
    }

    /// Tracks live sqlite3 children so teardown can SIGKILL them.
    final class ChildRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []

        func register(_ process: Process) {
            lock.lock(); processes.append(process); lock.unlock()
        }

        func unregister(_ process: Process) {
            lock.lock(); processes.removeAll { $0 === process }; lock.unlock()
        }

        func killAll() {
            lock.lock(); let live = processes; processes.removeAll(); lock.unlock()
            for process in live where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs sqlite3 read-only with a hard deadline. On expiry the child is
    /// SIGKILLed and `.timedOut` is returned — no caller can wedge on this.
    nonisolated static func query(dbPath: String, sql: String,
                                  timeout: TimeInterval, registry: ChildRegistry) -> QueryOutcome {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-readonly", "-noheader", "-separator", "|", dbPath, sql]

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }

        do {
            try task.run()
        } catch {
            return .failed
        }
        registry.register(task)
        defer { registry.unregister(task) }

        // Drain concurrently so a full pipe can't deadlock the child.
        let box = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(task.processIdentifier, SIGKILL)
            // Reap so the child doesn't linger as a zombie.
            _ = exited.wait(timeout: .now() + 2)
            return .timedOut
        }

        guard task.terminationStatus == 0 else { return .failed }
        _ = drained.wait(timeout: .now() + 2)
        guard let output = String(data: box.data, encoding: .utf8) else { return .failed }
        return .rows(output)
    }
}
