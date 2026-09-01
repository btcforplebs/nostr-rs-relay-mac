import SwiftUI

/// The relay operations dashboard.
///
/// Data comes from four independent sources so a failure in one doesn't blank
/// the page: the relay's Prometheus endpoint (traffic, latency, connections),
/// the OS (process cost, live TCP peers), the SQLite file (storage), and the
/// app's own process supervision (uptime, log severity).
struct DashboardView: View {
    @EnvironmentObject var relayService: RelayService
    @EnvironmentObject var configService: ConfigurationService
    @EnvironmentObject var eventService: EventViewerService

    @StateObject private var metrics = MetricsService()
    @StateObject private var system = SystemStatsService()
    @StateObject private var database = DatabaseStatsService()

    /// Drives uptime and other wall-clock readouts between polls.
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroSection
                liveTrafficSection
                connectionsSection
                commandsSection
                performanceSection
                databaseSection
                storageSection
                relayInfoSection
                healthSection
            }
            .padding(14)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { startCollectors() }
        .onDisappear { stopCollectors() }
        .onReceive(ticker) { tick = $0 }
        .onChange(of: relayService.isServerReady) { _ in startCollectors() }
        .onChange(of: relayService.processID) { _ in startCollectors() }
    }

    // MARK: - Collector lifecycle

    /// Polling is tied to the relay actually being up: a stopped relay has no
    /// metrics endpoint and no process to measure, so we idle instead of
    /// hammering a dead port.
    private func startCollectors() {
        let dataDirectory = configService.getDataDirectory()
        database.startAutoRefresh(dataDirectory: dataDirectory, interval: 15)

        guard relayService.isRunning else {
            metrics.stopPolling()
            metrics.reset()
            system.stopPolling()
            system.reset()
            return
        }

        metrics.startPolling(port: configService.config.port, interval: 2)
        system.startPolling(
            pid: relayService.processID,
            port: configService.config.port,
            dataDirectory: dataDirectory,
            interval: 5
        )
    }

    private func stopCollectors() {
        metrics.stopPolling()
        system.stopPolling()
        database.stopAutoRefresh()
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(statusTone.color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(relayService.statusMessage)
                        .font(.headline)
                    Text(relayService.isRunning
                         ? "Up \(Fmt.duration(relayService.uptime))"
                         : "Relay is not running")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    if relayService.isServerReady {
                        StatusPill(text: "Ready", tone: .good, systemImage: "checkmark.circle.fill")
                    }
                    if metrics.snapshot.isReachable {
                        StatusPill(text: "Metrics", tone: .good, systemImage: "chart.bar.fill")
                    } else if relayService.isRunning {
                        StatusPill(text: "No metrics", tone: .warning, systemImage: "exclamationmark.triangle.fill")
                    }
                    if eventService.isConnected {
                        StatusPill(text: "Live feed", tone: .good, systemImage: "dot.radiowaves.left.and.right")
                    }
                    if system.peers.hasExternalPeers {
                        StatusPill(text: "External peers", tone: .accent, systemImage: "globe")
                    }
                }
            }

            Divider()

            MetricGrid(minWidth: 118) {
                StatTile(label: "Address", value: hostAndPort, caption: configService.config.bindAddress,
                         systemImage: "network", help: configService.config.url)
                StatTile(label: "Uptime", value: Fmt.duration(relayService.uptime),
                         caption: relayService.startedAt.map { "since \(Fmt.date($0))" } ?? "—",
                         systemImage: "clock")
                StatTile(label: "Process", value: relayService.processID.map { "PID \($0)" } ?? "—",
                         caption: "\(relayService.startCount) start\(relayService.startCount == 1 ? "" : "s") this session",
                         systemImage: "cpu")
                StatTile(label: "Live Conns", value: Fmt.count(metrics.snapshot.activeConnections),
                         caption: "\(system.peers.uniquePeers) unique IP\(system.peers.uniquePeers == 1 ? "" : "s")",
                         tone: metrics.snapshot.activeConnections > 0 ? .good : .neutral,
                         systemImage: "personalhotspot")
                StatTile(label: "Events Stored", value: Fmt.count(database.stats.eventCount),
                         caption: Fmt.bytes(database.stats.totalBytes),
                         systemImage: "tray.full")
                StatTile(label: "Inbound", value: Fmt.rate(metrics.snapshot.cmdEventRate, unit: " ev/s"),
                         caption: "\(Fmt.count(metrics.snapshot.cmdEvent)) total",
                         systemImage: "arrow.down.circle")
            }

            HStack(spacing: 10) {
                Button(action: toggleRelay) {
                    HStack {
                        Image(systemName: relayService.isRunning ? "stop.fill" : "play.fill")
                        Text(relayService.isRunning ? "Stop Relay" : "Start Relay")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(relayService.isRunning ? .red : .green)
                .controlSize(.large)

                Button {
                    if let url = URL(string: "http://localhost:\(configService.config.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari").frame(height: 22)
                }
                .controlSize(.large)
                .disabled(!relayService.isRunning)
                .help("Open the relay landing page")

                Button {
                    if let url = URL(string: "http://localhost:\(configService.config.port)/metrics") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "chart.xyaxis.line").frame(height: 22)
                }
                .controlSize(.large)
                .disabled(!relayService.isRunning)
                .help("Open the raw Prometheus metrics")
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }

    private var statusTone: Tone {
        if !relayService.isRunning { return .critical }
        return relayService.isServerReady ? .good : .warning
    }

    private var hostAndPort: String {
        "\(configService.config.bindAddress):\(configService.config.port)"
    }

    private func toggleRelay() {
        if relayService.isRunning {
            relayService.stop()
            metrics.reset()
            system.reset()
        } else {
            relayService.start(configService: configService)
        }
    }

    // MARK: - Live traffic

    private var liveTrafficSection: some View {
        SectionCard(title: "Live Traffic", systemImage: "waveform.path.ecg",
                    subtitle: metrics.history.count > 1 ? "last \(metrics.history.count * 2)s" : nil) {
            VStack(alignment: .leading, spacing: 12) {
                MetricGrid(minWidth: 124) {
                    StatTile(label: "Events In", value: Fmt.rate(metrics.snapshot.cmdEventRate, unit: " /s"),
                             caption: "EVENT commands", tone: .accent, systemImage: "arrow.down")
                    StatTile(label: "Events Out", value: Fmt.rate(metrics.snapshot.sentEventsRate, unit: " /s"),
                             caption: "delivered to clients", tone: .accent, systemImage: "arrow.up")
                    StatTile(label: "Queries In", value: Fmt.rate(metrics.snapshot.cmdReqRate, unit: " /s"),
                             caption: "REQ commands", systemImage: "magnifyingglass")
                    StatTile(label: "New Conns", value: Fmt.rate(metrics.snapshot.connectionsPerMin, unit: " /min"),
                             caption: "connection rate", systemImage: "arrow.triangle.branch")
                    StatTile(label: "Fanout", value: fanoutRatio,
                             caption: "sent per event in", systemImage: "arrow.branch")
                    StatTile(label: "Amplification", value: Fmt.count(metrics.snapshot.sentEventsTotal),
                             caption: "events sent all-time", systemImage: "paperplane")
                }

                if metrics.history.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        sparkRow(title: "Events in / s",
                                 values: metrics.history.map(\.eventsIn),
                                 current: metrics.snapshot.cmdEventRate)
                        sparkRow(title: "Events out / s",
                                 values: metrics.history.map(\.eventsOut),
                                 current: metrics.snapshot.sentEventsRate)
                        sparkRow(title: "Requests / s",
                                 values: metrics.history.map(\.requests),
                                 current: metrics.snapshot.cmdReqRate)
                        sparkRow(title: "Active connections",
                                 values: metrics.history.map(\.connections),
                                 current: metrics.snapshot.activeConnections,
                                 unit: "")
                    }
                } else if relayService.isRunning {
                    Text("Collecting samples…")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Start the relay to collect live traffic.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func sparkRow(title: String, values: [Double], current: Double, unit: String = "/s") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                Spacer()
                Text(unit.isEmpty ? Fmt.count(current) : Fmt.rate(current, unit: unit))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Text("peak \(Fmt.count(values.max() ?? 0))")
                    .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
            }
            Sparkline(values: values, height: 30)
        }
    }

    private var fanoutRatio: String {
        let inbound = metrics.snapshot.cmdEvent
        guard inbound > 0 else { return "—" }
        return String(format: "%.1f×", metrics.snapshot.sentEventsTotal / inbound)
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        SectionCard(title: "Connections", systemImage: "personalhotspot") {
            VStack(alignment: .leading, spacing: 12) {
                MetricGrid(minWidth: 118) {
                    StatTile(label: "Active", value: Fmt.count(metrics.snapshot.activeConnections),
                             caption: "opened − closed",
                             tone: metrics.snapshot.activeConnections > 0 ? .good : .neutral,
                             systemImage: "bolt.horizontal")
                    StatTile(label: "TCP Established", value: "\(system.peers.establishedCount)",
                             caption: "sockets on :\(configService.config.port)",
                             systemImage: "cable.connector")
                    StatTile(label: "Unique IPs", value: "\(system.peers.uniquePeers)",
                             caption: system.peers.hasExternalPeers ? "incl. external" : "loopback only",
                             systemImage: "globe")
                    StatTile(label: "Listeners", value: "\(system.peers.listenerCount)",
                             caption: system.peers.listenerCount > 0 ? "bound" : "not bound",
                             // Not being bound is only a problem if the relay is meant to be up.
                             tone: listenerTone,
                             systemImage: "antenna.radiowaves.left.and.right")
                    StatTile(label: "Total Accepted", value: Fmt.count(metrics.snapshot.connectionsTotal),
                             caption: "since relay start", systemImage: "sum")
                    StatTile(label: "Disconnects", value: Fmt.count(metrics.snapshot.disconnectsTotal),
                             caption: "all reasons", systemImage: "xmark.circle")
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top Peers")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        BarList(
                            items: system.peers.topPeers.map {
                                BarList.Item(id: $0.ip, label: $0.ip, value: Double($0.count),
                                             detail: "\($0.count) socket\($0.count == 1 ? "" : "s")")
                            },
                            emptyText: "No connected clients"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Disconnect Reasons")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        BarList(
                            items: metrics.snapshot.disconnectsByReason
                                .sorted { $0.value > $1.value }
                                .map { BarList.Item(id: $0.key, label: $0.key.capitalized, value: $0.value) },
                            emptyText: "No disconnects recorded"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var listenerTone: Tone {
        guard relayService.isRunning else { return .neutral }
        return system.peers.listenerCount > 0 ? .good : .warning
    }

    // MARK: - Commands

    private var commandsSection: some View {
        SectionCard(title: "Client Protocol", systemImage: "arrow.left.arrow.right") {
            MetricGrid(minWidth: 118) {
                StatTile(label: "EVENT", value: Fmt.count(metrics.snapshot.cmdEvent),
                         caption: Fmt.rate(metrics.snapshot.cmdEventRate), systemImage: "square.and.pencil")
                StatTile(label: "REQ", value: Fmt.count(metrics.snapshot.cmdReq),
                         caption: Fmt.rate(metrics.snapshot.cmdReqRate), systemImage: "magnifyingglass")
                StatTile(label: "CLOSE", value: Fmt.count(metrics.snapshot.cmdClose),
                         caption: Fmt.rate(metrics.snapshot.cmdCloseRate), systemImage: "xmark.square")
                StatTile(label: "AUTH", value: Fmt.count(metrics.snapshot.cmdAuth),
                         caption: Fmt.rate(metrics.snapshot.cmdAuthRate), systemImage: "key")
                StatTile(label: "Sent — Stored", value: Fmt.count(metrics.snapshot.sentEventsDB),
                         caption: "from database", systemImage: "internaldrive")
                StatTile(label: "Sent — Realtime", value: Fmt.count(metrics.snapshot.sentEventsRealtime),
                         caption: "live broadcast", systemImage: "dot.radiowaves.right")
                StatTile(label: "Query Aborts", value: Fmt.count(metrics.snapshot.queryAbortsTotal),
                         caption: abortSummary,
                         tone: metrics.snapshot.queryAbortsTotal > 0 ? .warning : .neutral,
                         systemImage: "exclamationmark.octagon")
                StatTile(label: "Open Subs", value: openSubscriptions,
                         caption: "REQ − CLOSE", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private var abortSummary: String {
        let aborts = metrics.snapshot.queryAborts.sorted { $0.value > $1.value }
        guard let top = aborts.first else { return "none" }
        return "top: \(top.key)"
    }

    /// REQ minus CLOSE approximates subscriptions still open across all clients.
    private var openSubscriptions: String {
        Fmt.count(max(0, metrics.snapshot.cmdReq - metrics.snapshot.cmdClose))
    }

    // MARK: - Performance

    private var performanceSection: some View {
        SectionCard(title: "Performance", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                MetricGrid(minWidth: 118) {
                    StatTile(label: "Subscription p50", value: Fmt.latency(metrics.snapshot.subscriptionLatency.p50),
                             caption: "mean \(Fmt.latency(metrics.snapshot.subscriptionLatency.mean))",
                             systemImage: "timer")
                    StatTile(label: "Subscription p95", value: Fmt.latency(metrics.snapshot.subscriptionLatency.p95),
                             caption: "p99 \(Fmt.latency(metrics.snapshot.subscriptionLatency.p99))",
                             tone: latencyTone(metrics.snapshot.subscriptionLatency.p95, warn: 0.5, bad: 2),
                             systemImage: "timer")
                    StatTile(label: "SQL Filter p50", value: Fmt.latency(metrics.snapshot.filterLatency.p50),
                             caption: "p95 \(Fmt.latency(metrics.snapshot.filterLatency.p95))",
                             systemImage: "cylinder.split.1x2")
                    StatTile(label: "Event Write p50", value: Fmt.latency(metrics.snapshot.writeLatency.p50),
                             caption: "p95 \(Fmt.latency(metrics.snapshot.writeLatency.p95))",
                             tone: latencyTone(metrics.snapshot.writeLatency.p95, warn: 0.25, bad: 1),
                             systemImage: "square.and.arrow.down")
                    StatTile(label: "Queries Served", value: Fmt.count(metrics.snapshot.subscriptionLatency.count),
                             caption: "subscriptions completed", systemImage: "checkmark.seal")
                    StatTile(label: "Writes", value: Fmt.count(metrics.snapshot.writeLatency.count),
                             caption: "events persisted", systemImage: "square.and.arrow.down.on.square")
                    StatTile(label: "DB Pool", value: Fmt.count(metrics.snapshot.dbPoolConnections),
                             caption: "connections in use", systemImage: "point.3.connected.trianglepath.dotted")
                    StatTile(label: "CPU", value: system.process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                             caption: "\(system.host.activeProcessorCount) cores available",
                             tone: cpuTone, systemImage: "cpu")
                    StatTile(label: "Memory", value: Fmt.bytes(system.process.residentBytes),
                             caption: "resident set", systemImage: "memorychip")
                    StatTile(label: "Virtual", value: Fmt.bytes(system.process.virtualBytes),
                             caption: "address space", systemImage: "square.stack.3d.up")
                    StatTile(label: "Threads", value: system.process.threadCount.map(String.init) ?? "—",
                             caption: "in relay process", systemImage: "arrow.triangle.branch")
                    StatTile(label: "Thermals", value: system.host.thermalState,
                             caption: "system pressure",
                             tone: system.host.thermalState == "Nominal" ? .good : .warning,
                             systemImage: "thermometer")
                }

                Text("Latency percentiles are interpolated from the relay's Prometheus histograms and cover the whole process lifetime, not the last sample.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func latencyTone(_ seconds: Double, warn: Double, bad: Double) -> Tone {
        guard seconds > 0 else { return .neutral }
        if seconds >= bad { return .critical }
        if seconds >= warn { return .warning }
        return .good
    }

    private var cpuTone: Tone {
        guard let cpu = system.process.cpuPercent else { return .neutral }
        if cpu > 150 { return .critical }
        if cpu > 70 { return .warning }
        return .good
    }

    // MARK: - Database

    private var databaseSection: some View {
        SectionCard(
            title: "Database",
            systemImage: "cylinder.split.1x2",
            subtitle: database.stats.lastLightRefresh.map { "updated \(Fmt.relative($0))" },
            accessory: AnyView(
                Button {
                    database.refresh(dataDirectory: configService.getDataDirectory(), deep: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(database.isRefreshing)
                .help("Run a full refresh, including the deep scan")
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                MetricGrid(minWidth: 118) {
                    StatTile(label: "Events", value: Fmt.count(database.stats.eventCount),
                             caption: "rows in event table", systemImage: "tray.full")
                    StatTile(label: "Tags", value: Fmt.count(database.stats.tagCount),
                             caption: tagsPerEvent, systemImage: "tag")
                    StatTile(label: "Authors", value: Fmt.count(database.stats.distinctAuthors),
                             caption: "distinct pubkeys", systemImage: "person.2")
                    StatTile(label: "Kinds", value: Fmt.count(database.stats.distinctKinds),
                             caption: "distinct event kinds", systemImage: "square.grid.2x2")
                    StatTile(label: "Last Hour", value: Fmt.count(database.stats.eventsLastHour),
                             caption: "newly ingested",
                             tone: (database.stats.eventsLastHour ?? 0) > 0 ? .accent : .neutral,
                             systemImage: "clock.arrow.circlepath")
                    StatTile(label: "Last 24h", value: Fmt.count(database.stats.eventsLast24h),
                             caption: "newly ingested", systemImage: "calendar")
                    StatTile(label: "Last 7 Days", value: Fmt.count(database.stats.eventsLast7d),
                             caption: database.stats.eventsPerDay.map { "\(Fmt.count($0))/day avg" } ?? "—",
                             systemImage: "calendar.badge.clock")
                    StatTile(label: "Newest Event", value: Fmt.relative(database.stats.newestCreatedAt),
                             caption: "authored at", systemImage: "arrow.up.to.line")
                    StatTile(label: "Oldest Event", value: Fmt.relative(database.stats.oldestCreatedAt),
                             caption: "authored at", systemImage: "arrow.down.to.line")
                    StatTile(label: "Last Ingest", value: Fmt.relative(database.stats.lastSeen),
                             caption: "relay first-seen", systemImage: "tray.and.arrow.down")
                    StatTile(label: "Avg Event", value: Fmt.bytes(database.stats.avgEventBytes),
                             caption: "content length", systemImage: "doc.text")
                    StatTile(label: "Largest Event", value: Fmt.bytes(database.stats.maxEventBytes),
                             caption: "content length", systemImage: "doc.badge.plus")
                    StatTile(label: "Expiring", value: Fmt.count(database.stats.expiringCount),
                             caption: "NIP-40 events", systemImage: "hourglass")
                    StatTile(label: "Hidden", value: Fmt.count(database.stats.hiddenCount),
                             caption: "excluded from queries", systemImage: "eye.slash")
                    StatTile(label: "Delegated", value: Fmt.count(database.stats.delegatedCount),
                             caption: "NIP-26 events", systemImage: "arrow.turn.up.right")
                    StatTile(label: "Content Bytes", value: Fmt.bytes(database.stats.contentBytes),
                             caption: "sum of event content", systemImage: "doc.on.doc")
                }

                if !database.stats.hourlyActivity.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Ingest — last 24 hours")
                                .font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            Spacer()
                            Text("peak \(Fmt.count(database.stats.hourlyActivity.map(\.count).max()))/hr")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        MiniBarChart(values: database.stats.hourlyActivity.map(\.count))
                        HStack {
                            Text("24h ago").font(.system(size: 8)).foregroundColor(.secondary)
                            Spacer()
                            Text("now").font(.system(size: 8)).foregroundColor(.secondary)
                        }
                    }
                }

                if !database.stats.dailyActivity.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Ingest — last 14 days")
                                .font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            Spacer()
                            Text("peak \(Fmt.count(database.stats.dailyActivity.map(\.count).max()))/day")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        MiniBarChart(values: database.stats.dailyActivity.map(\.count))
                    }
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top Kinds")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        BarList(
                            items: database.stats.topKinds.map {
                                BarList.Item(id: "\($0.kind)",
                                             label: "\($0.kind) · \(Fmt.kindName($0.kind))",
                                             value: Double($0.count),
                                             detail: Fmt.count($0.count))
                            },
                            emptyText: "No events stored yet"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top Authors")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        BarList(
                            items: database.stats.topAuthors.map {
                                BarList.Item(id: $0.pubkey,
                                             label: "\($0.pubkey.prefix(12))…",
                                             value: Double($0.count),
                                             detail: Fmt.count($0.count))
                            },
                            emptyText: "No events stored yet"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var tagsPerEvent: String {
        guard let tags = database.stats.tagCount,
              let events = database.stats.eventCount, events > 0 else { return "—" }
        return String(format: "%.1f per event", Double(tags) / Double(events))
    }

    // MARK: - Storage

    private var storageSection: some View {
        SectionCard(title: "Storage", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 12) {
                MetricGrid(minWidth: 118) {
                    StatTile(label: "Database", value: Fmt.bytes(database.stats.databaseBytes),
                             caption: "nostr.db", systemImage: "cylinder")
                    StatTile(label: "WAL", value: Fmt.bytes(database.stats.walBytes),
                             caption: "write-ahead log",
                             tone: database.stats.walBytes > 64 * 1024 * 1024 ? .warning : .neutral,
                             systemImage: "doc.badge.clock")
                    StatTile(label: "Shared Memory", value: Fmt.bytes(database.stats.shmBytes),
                             caption: "-shm index", systemImage: "memorychip")
                    StatTile(label: "Total On Disk", value: Fmt.bytes(database.stats.totalBytes),
                             caption: "db + wal + shm", systemImage: "externaldrive")
                    StatTile(label: "Bytes / Event", value: Fmt.bytes(database.stats.bytesPerEvent),
                             caption: "incl. tags & indexes", systemImage: "scalemass")
                    StatTile(label: "Pages", value: Fmt.count(database.stats.pageCount),
                             caption: database.stats.pageSize.map { "\(Fmt.bytes($0)) each" } ?? "—",
                             systemImage: "square.stack")
                    StatTile(label: "Free Pages", value: Fmt.count(database.stats.freelistCount),
                             caption: database.stats.fragmentationPercent.map { "\(Fmt.percent($0)) reclaimable" } ?? "—",
                             tone: (database.stats.fragmentationPercent ?? 0) > 25 ? .warning : .neutral,
                             systemImage: "trash")
                    StatTile(label: "Journal Mode", value: database.stats.journalMode ?? "—",
                             caption: "sqlite journal",
                             tone: database.stats.journalMode == "WAL" ? .good : .neutral,
                             systemImage: "book.closed")
                    StatTile(label: "Schema Version", value: database.stats.schemaVersion.map(String.init) ?? "—",
                             caption: "migration level", systemImage: "number")
                    StatTile(label: "Disk Free", value: Fmt.bytes(system.host.diskFreeBytes),
                             caption: diskCaption,
                             tone: diskTone, systemImage: "externaldrive.badge.minus")
                    StatTile(label: "Projected 30d", value: projectedGrowth,
                             caption: "at current ingest rate", systemImage: "chart.line.uptrend.xyaxis")
                    StatTile(label: "Machine RAM", value: Fmt.bytes(system.host.physicalMemoryBytes),
                             caption: "\(system.host.activeProcessorCount) active cores",
                             systemImage: "server.rack")
                }

                DetailRow(label: "Data directory",
                          value: configService.getDataDirectory().path,
                          monospaced: true)
                DetailRow(label: "Config file",
                          value: configService.getConfigPath(),
                          monospaced: true)
            }
        }
    }

    private var diskCaption: String {
        guard let free = system.host.diskFreeBytes, let total = system.host.diskTotalBytes, total > 0 else {
            return "on data volume"
        }
        return "\(Fmt.percent(Double(free) / Double(total) * 100, decimals: 0)) of \(Fmt.bytes(total))"
    }

    private var diskTone: Tone {
        guard let free = system.host.diskFreeBytes, let total = system.host.diskTotalBytes, total > 0 else {
            return .neutral
        }
        let ratio = Double(free) / Double(total)
        if ratio < 0.05 { return .critical }
        if ratio < 0.15 { return .warning }
        return .good
    }

    /// Extrapolates 30 days of storage from the observed weekly ingest and the
    /// current average cost per event.
    private var projectedGrowth: String {
        guard let perDay = database.stats.eventsPerDay, perDay > 0,
              let bytesPerEvent = database.stats.bytesPerEvent, bytesPerEvent > 0 else { return "—" }
        return "+\(Fmt.bytes(Int64(perDay * 30) * bytesPerEvent))"
    }

    // MARK: - Relay identity

    private var relayInfoSection: some View {
        SectionCard(title: "Relay Identity", systemImage: "info.circle",
                    subtitle: system.relayInfo == nil ? "NIP-11 unavailable" : "NIP-11") {
            VStack(alignment: .leading, spacing: 10) {
                MetricGrid(minWidth: 118) {
                    StatTile(label: "Name", value: system.relayInfo?.name ?? configService.config.name,
                             caption: "advertised", systemImage: "tag")
                    StatTile(label: "Software", value: shortSoftware,
                             caption: system.relayInfo?.version ?? "—", systemImage: "shippingbox")
                    StatTile(label: "Supported NIPs", value: "\(system.relayInfo?.supported_nips?.count ?? 0)",
                             caption: "protocol extensions", systemImage: "checklist")
                    StatTile(label: "Max Message", value: Fmt.bytes(system.relayInfo?.limitation?.max_message_length ?? configService.config.maxWSMessageBytes),
                             caption: "per websocket frame", systemImage: "arrow.left.and.right")
                    StatTile(label: "Max Event", value: Fmt.bytes(configService.config.maxEventSize),
                             caption: "per event", systemImage: "doc")
                    StatTile(label: "Max Subs", value: system.relayInfo?.limitation?.max_subscriptions.map(String.init) ?? "—",
                             caption: "per connection", systemImage: "list.bullet")
                    StatTile(label: "Max Filters", value: system.relayInfo?.limitation?.max_filters.map(String.init) ?? "—",
                             caption: "per subscription", systemImage: "line.3.horizontal.decrease")
                    StatTile(label: "Max Limit", value: system.relayInfo?.limitation?.max_limit.map(String.init) ?? "—",
                             caption: "events per query", systemImage: "number.square")
                    StatTile(label: "Auth Required", value: boolLabel(system.relayInfo?.limitation?.auth_required),
                             caption: "NIP-42", systemImage: "lock")
                    StatTile(label: "Payment Required", value: boolLabel(system.relayInfo?.limitation?.payment_required),
                             caption: "paid relay", systemImage: "creditcard")
                    StatTile(label: "Min PoW", value: system.relayInfo?.limitation?.min_pow_difficulty.map(String.init) ?? "0",
                             caption: "NIP-13 difficulty", systemImage: "hammer")
                    StatTile(label: "Verbose Logs", value: configService.config.appSpecific.verboseLogging ? "On" : "Off",
                             caption: "relay log level", systemImage: "text.alignleft")
                }

                if let nips = system.relayInfo?.supported_nips, !nips.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NIPs")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                        Text(nips.sorted().map(String.init).joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let description = system.relayInfo?.description, !description.isEmpty {
                    DetailRow(label: "Description", value: description)
                }
                DetailRow(label: "Public URL", value: configService.config.url, monospaced: true)
                if let contact = system.relayInfo?.contact, !contact.isEmpty {
                    DetailRow(label: "Contact", value: contact, monospaced: true)
                }
                if let pubkey = system.relayInfo?.pubkey, !pubkey.isEmpty {
                    DetailRow(label: "Admin pubkey", value: pubkey, monospaced: true)
                }
            }
        }
    }

    private var shortSoftware: String {
        guard let software = system.relayInfo?.software else { return "—" }
        return software.split(separator: "/").last.map(String.init) ?? software
    }

    private func boolLabel(_ value: Bool?) -> String {
        guard let value = value else { return "—" }
        return value ? "Yes" : "No"
    }

    // MARK: - Health

    private var metricsCaption: String {
        if !relayService.isRunning { return "relay stopped" }
        return metrics.snapshot.isReachable ? "endpoint healthy" : "unreachable"
    }

    private var healthSection: some View {
        SectionCard(title: "Health", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 10) {
                MetricGrid(minWidth: 118) {
                    StatTile(label: "Errors", value: "\(relayService.errorCount)",
                             caption: "this app session",
                             tone: relayService.errorCount > 0 ? .critical : .good,
                             systemImage: "exclamationmark.octagon")
                    StatTile(label: "Warnings", value: "\(relayService.warningCount)",
                             caption: "this app session",
                             tone: relayService.warningCount > 0 ? .warning : .good,
                             systemImage: "exclamationmark.triangle")
                    StatTile(label: "Restarts", value: "\(max(0, relayService.startCount - 1))",
                             caption: "after first start",
                             tone: relayService.startCount > 2 ? .warning : .neutral,
                             systemImage: "arrow.clockwise")
                    StatTile(label: "Last Exit Code", value: relayService.lastExitCode.map(String.init) ?? "—",
                             caption: "previous process",
                             tone: (relayService.lastExitCode ?? 0) != 0 ? .warning : .neutral,
                             systemImage: "power")
                    StatTile(label: "Log Buffer", value: "\(relayService.logs.count)",
                             caption: "lines retained", systemImage: "text.alignleft")
                    StatTile(label: "Metrics Scrape", value: metrics.snapshot.lastScrape.map { Fmt.relative($0) } ?? "—",
                             caption: metricsCaption,
                             // Unreachable is only notable while the relay is supposed to be up.
                             tone: !relayService.isRunning ? .neutral : (metrics.snapshot.isReachable ? .good : .warning),
                             systemImage: "chart.bar")
                    StatTile(label: "Deep DB Scan", value: database.stats.lastDeepRefresh.map { Fmt.relative($0) } ?? "—",
                             caption: "full-table stats", systemImage: "magnifyingglass.circle")
                    StatTile(label: "System Uptime", value: Fmt.duration(system.host.systemUptime),
                             caption: "host machine", systemImage: "desktopcomputer")
                }

                if let lastError = relayService.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Tone.critical.color)
                        Text(lastError)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tone.critical.color.opacity(0.08))
                    .cornerRadius(6)
                }

                if let metricsError = metrics.snapshot.lastError, !metrics.snapshot.isReachable, relayService.isRunning {
                    Text("Metrics endpoint: \(metricsError)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
