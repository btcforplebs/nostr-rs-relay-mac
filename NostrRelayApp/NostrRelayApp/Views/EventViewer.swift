import SwiftUI

struct EventViewer: View {
    @EnvironmentObject var service: EventViewerService
    @EnvironmentObject var configService: ConfigurationService
    @StateObject private var statsService = DatabaseStatsService()
    @State private var kindFilterString = ""

    var body: some View {
        List(service.events) { event in
            EventRow(event: event)
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top) {
            DatabaseStatsBar(statsService: statsService, dataDirectory: configService.getDataDirectory())
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle()
                    .fill(service.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                Text(service.isConnected ? "Connected" : (service.isActive ? "Reconnecting…" : "Disconnected"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: toggleConnection) {
                    Text(service.isActive ? "Disconnect" : "Connect")
                }
            }
            .padding()
            .background(.regularMaterial)
            .overlay(Divider(), alignment: .top)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                TextField("Filter Kinds (e.g. 1)", text: $kindFilterString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { applyFilter() }
            }
            
            ToolbarItem(placement: .automatic) {
                if !kindFilterString.isEmpty {
                    Button(action: {
                        kindFilterString = ""
                        applyFilter()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            

        }
        .onAppear {
            statsService.startAutoRefresh(dataDirectory: configService.getDataDirectory())
        }
        .onDisappear {
            statsService.stopAutoRefresh()
        }
    }
    
    private func toggleConnection() {
        if service.isActive {
            service.disconnect()
        } else {
            service.connect(port: configService.config.port, config: configService.config)
        }
    }
    
    private func applyFilter() {
        let cleanString = kindFilterString.removingCharacters(where: { !$0.isNumber && $0 != "," })
        let kinds = cleanString.components(separatedBy: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        
        if kinds.isEmpty && !kindFilterString.isEmpty {
            return
        }
        
        service.updateFilter(kinds: kinds.isEmpty ? nil : kinds)
        service.clear()
    }
}

extension String {
    func removingCharacters(where predicate: (Character) throws -> Bool) -> String {
        return (try? filter { try !predicate($0) }) ?? self
    }
}

// MARK: - Database Stats

struct DatabaseStatsBar: View {
    @ObservedObject var statsService: DatabaseStatsService
    let dataDirectory: URL

    var body: some View {
        HStack(spacing: 20) {
            StatBadge(
                title: "Database",
                value: format(bytes: statsService.stats.databaseBytes),
                icon: "internaldrive"
            )
            StatBadge(
                title: "WAL",
                value: format(bytes: statsService.stats.walBytes),
                icon: "doc.badge.clock"
            )
            StatBadge(
                title: "Events",
                value: statsService.stats.eventCount.map { $0.formatted() } ?? "—",
                icon: "tray.full"
            )

            if !statsService.stats.topKinds.isEmpty {
                Divider().frame(height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Kinds")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(statsService.stats.topKinds.map { "\($0.kind) (\($0.count.formatted()))" }.joined(separator: "  "))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: {
                statsService.refresh(dataDirectory: dataDirectory)
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(statsService.isRefreshing)
            .help("Refresh database stats")

            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([dataDirectory.appendingPathComponent("nostr.db")])
            }) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Reveal database in Finder")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct StatBadge: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit().bold())
            }
        }
    }
}

// MARK: - Redesigned UI Components

struct EventRow: View {
    let event: NostrEvent
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left: Avatar / Icon
            PubkeyAvatar(pubkey: event.pubkey)
                .frame(width: 40, height: 40)
            
            // Right: Content
            VStack(alignment: .leading, spacing: 6) {
                // Header: Pubkey + Time
                HStack {
                    Text(shortPubKey)
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(event.createdAtDate.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Content Body
                if event.kind == 1 {
                    // Text Note
                    Text(event.content)
                        .font(.system(.body, design: .default))
                        .lineLimit(10)
                        .textSelection(.enabled)
                } 
                else if event.kind == 0 {
                    // Metadata
                    Label("Updated Profile", systemImage: "person.circle")
                        .font(.callout)
                        .foregroundColor(.blue)
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                }
                else {
                    // Generic / Tech view for other kinds
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Kind \(event.kind)", systemImage: "tag")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        
                        Text(event.content)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Copy Event ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.id, forType: .string)
            }
            Button("Copy Raw JSON") {
                // Determine how to re-serialize if needed, or just copy content
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.content, forType: .string)
            }
        }
    }
    
    var shortPubKey: String {
        let p = event.pubkey
        return "\(p.prefix(6))...\(p.suffix(6))"
    }
}

struct PubkeyAvatar: View {
    let pubkey: String
    
    var body: some View {
        ZStack {
            Circle()
                .fill(colorForPubkey())
            
            Text(String(pubkey.prefix(2)).uppercased())
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(.white)
        }
        .shadow(radius: 1)
    }
    
    private func colorForPubkey() -> Color {
        // Simple distinct color determinism
        let hash = pubkey.hash
        let colors: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .mint]
        let index = abs(hash) % colors.count
        return colors[index]
    }
}
