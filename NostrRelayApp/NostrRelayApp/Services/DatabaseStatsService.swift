import Foundation

/// Reads on-disk size, storage internals and event statistics from the relay's
/// SQLite database.
///
/// Queries run read-only against the live database via the system sqlite3 CLI,
/// so they never block or lock the relay's writer. Work is split into two tiers:
/// `light` stats are index-backed and refresh often; `deep` stats need full
/// table scans (DISTINCT authors, content sizes) and refresh rarely, so a large
/// database never turns the dashboard into a disk hog.
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

        // Content
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

        // Time span
        var oldestCreatedAt: Date? = nil
        var newestCreatedAt: Date? = nil
        var firstSeen: Date? = nil
        var lastSeen: Date? = nil

        // Ingest volume, by when the relay first saw the event
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
        var databaseExists: Bool = false

        /// Mean events per day over the observed 7-day window.
        var eventsPerDay: Double? {
            guard let week = eventsLast7d else { return nil }
            return Double(week) / 7.0
        }

        /// Average on-disk cost of one event, including tags and indexes.
        var bytesPerEvent: Int64? {
            guard let count = eventCount, count > 0 else { return nil }
            return databaseBytes / Int64(count)
        }
    }

    @Published private(set) var stats = Stats()
    @Published private(set) var isRefreshing = false

    private var refreshTimer: Timer?
    private var deepRefreshCounter = 0
    /// Run the expensive scan every Nth light refresh.
    private let deepRefreshEvery = 10

    // MARK: - Refresh

    func refresh(dataDirectory: URL, deep: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let dbURL = dataDirectory.appendingPathComponent("nostr.db")
        let previous = stats

        Task.detached(priority: .utility) {
            var result = previous
            let fm = FileManager.default

            result.databaseBytes = Self.fileSize(dbURL.path)
            result.walBytes = Self.fileSize(dbURL.path + "-wal")
            result.shmBytes = Self.fileSize(dbURL.path + "-shm")
            result.databaseExists = fm.fileExists(atPath: dbURL.path)

            if result.databaseExists {
                Self.applyLightStats(dbPath: dbURL.path, into: &result)
                result.lastLightRefresh = Date()

                if deep {
                    Self.applyDeepStats(dbPath: dbURL.path, into: &result)
                    result.lastDeepRefresh = Date()
                }
            }

            let final = result
            await MainActor.run {
                self.stats = final
                self.isRefreshing = false
            }
        }
    }

    /// Auto-refresh while a tab showing database stats is visible.
    func startAutoRefresh(dataDirectory: URL, interval: TimeInterval = 15) {
        stopAutoRefresh()
        deepRefreshCounter = 0
        refresh(dataDirectory: dataDirectory, deep: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.deepRefreshCounter += 1
                let deep = self.deepRefreshCounter % self.deepRefreshEvery == 0
                self.refresh(dataDirectory: dataDirectory, deep: deep)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Queries

    /// Index-backed stats plus storage internals. Cheap enough to run often.
    nonisolated private static func applyLightStats(dbPath: String, into result: inout Stats) {
        let sql = """
        SELECT 'page_count', * FROM pragma_page_count();
        SELECT 'page_size', * FROM pragma_page_size();
        SELECT 'freelist', * FROM pragma_freelist_count();
        SELECT 'journal', * FROM pragma_journal_mode();
        SELECT 'schema_version', * FROM pragma_user_version();
        SELECT 'events', count(*) FROM event;
        SELECT 'tags', count(*) FROM tag;
        SELECT 'hidden', count(*) FROM event WHERE hidden = 1;
        SELECT 'expiring', count(*) FROM event WHERE expires_at IS NOT NULL;
        SELECT 'delegated', count(*) FROM event WHERE delegated_by IS NOT NULL;
        SELECT 'oldest', min(created_at) FROM event;
        SELECT 'newest', max(created_at) FROM event;
        SELECT 'first_seen', min(first_seen) FROM event;
        SELECT 'last_seen', max(first_seen) FROM event;
        SELECT 'hour', count(*) FROM event WHERE first_seen > strftime('%s','now') - 3600;
        SELECT 'day', count(*) FROM event WHERE first_seen > strftime('%s','now') - 86400;
        SELECT 'week', count(*) FROM event WHERE first_seen > strftime('%s','now') - 604800;
        SELECT 'kind', kind, count(*) FROM event GROUP BY kind ORDER BY 3 DESC LIMIT 8;
        """

        guard let output = query(dbPath: dbPath, sql: sql) else { return }

        var kinds: [KindCount] = []
        for row in rows(from: output) {
            guard let tag = row.first else { continue }
            switch tag {
            case "page_count":      result.pageCount = row.int(1)
            case "page_size":       result.pageSize = row.int(1)
            case "freelist":        result.freelistCount = row.int(1)
            case "journal":         result.journalMode = row.string(1)?.uppercased()
            case "schema_version":  result.schemaVersion = row.int(1)
            case "events":          result.eventCount = row.int(1)
            case "tags":            result.tagCount = row.int(1)
            case "hidden":          result.hiddenCount = row.int(1)
            case "expiring":        result.expiringCount = row.int(1)
            case "delegated":       result.delegatedCount = row.int(1)
            case "oldest":          result.oldestCreatedAt = row.date(1)
            case "newest":          result.newestCreatedAt = row.date(1)
            case "first_seen":      result.firstSeen = row.date(1)
            case "last_seen":       result.lastSeen = row.date(1)
            case "hour":            result.eventsLastHour = row.int(1)
            case "day":             result.eventsLast24h = row.int(1)
            case "week":            result.eventsLast7d = row.int(1)
            case "kind":
                if let k = row.int(1), let c = row.int(2) {
                    kinds.append(KindCount(kind: k, count: c))
                }
            default: break
            }
        }
        result.topKinds = kinds
    }

    /// Full-scan stats. Expensive on a large relay, so these run on a slow cadence.
    nonisolated private static func applyDeepStats(dbPath: String, into result: inout Stats) {
        let sql = """
        SELECT 'authors', count(DISTINCT author) FROM event;
        SELECT 'kinds', count(DISTINCT kind) FROM event;
        SELECT 'content_bytes', coalesce(sum(length(content)), 0) FROM event;
        SELECT 'avg_bytes', coalesce(cast(avg(length(content)) AS INTEGER), 0) FROM event;
        SELECT 'max_bytes', coalesce(max(length(content)), 0) FROM event;
        SELECT 'author', substr(lower(hex(author)), 1, 16), count(*) FROM event
            GROUP BY author ORDER BY 3 DESC LIMIT 6;
        SELECT 'hourly',
               cast((strftime('%s','now') - first_seen) / 3600 AS INTEGER),
               count(*)
          FROM event
         WHERE first_seen > strftime('%s','now') - 86400
         GROUP BY 2 ORDER BY 2;
        SELECT 'daily',
               cast((strftime('%s','now') - first_seen) / 86400 AS INTEGER),
               count(*)
          FROM event
         WHERE first_seen > strftime('%s','now') - 1209600
         GROUP BY 2 ORDER BY 2;
        """

        guard let output = query(dbPath: dbPath, sql: sql) else { return }

        var authors: [AuthorCount] = []
        // Buckets are keyed by "ages ago", so index 0 is the most recent.
        var hourly = [Int](repeating: 0, count: 24)
        var daily = [Int](repeating: 0, count: 14)

        for row in rows(from: output) {
            guard let tag = row.first else { continue }
            switch tag {
            case "authors":       result.distinctAuthors = row.int(1)
            case "kinds":         result.distinctKinds = row.int(1)
            case "content_bytes": result.contentBytes = row.int64(1)
            case "avg_bytes":     result.avgEventBytes = row.int(1)
            case "max_bytes":     result.maxEventBytes = row.int(1)
            case "author":
                if let pk = row.string(1), let c = row.int(2) {
                    authors.append(AuthorCount(pubkey: pk, count: c))
                }
            case "hourly":
                if let age = row.int(1), let c = row.int(2), age >= 0, age < 24 { hourly[age] = c }
            case "daily":
                if let age = row.int(1), let c = row.int(2), age >= 0, age < 14 { daily[age] = c }
            default: break
            }
        }

        result.topAuthors = authors
        // Reverse so the charts read oldest -> newest, left to right.
        result.hourlyActivity = hourly.reversed().enumerated().map { index, count in
            Bucket(id: index, label: "\(24 - index)h ago", count: count)
        }
        result.dailyActivity = daily.reversed().enumerated().map { index, count in
            Bucket(id: index, label: "\(14 - index)d ago", count: count)
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

    nonisolated private static func query(dbPath: String, sql: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-readonly", "-noheader", "-separator", "|", dbPath, sql]

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
