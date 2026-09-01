import SwiftUI

struct LogsView: View {
    @EnvironmentObject var relayService: RelayService
    @State private var autoScroll = true

    var body: some View {
        ScrollViewReader { proxy in
            List(relayService.logs) { log in
                HStack(alignment: .top) {
                    Text(log.date, style: .time)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .leading)
                    
                    Text(log.message)
                        .font(.caption.monospaced())
                        .foregroundColor(colorFor(type: log.type))
                        .textSelection(.enabled)

                    if log.count > 1 {
                        Text("×\(log.count)")
                            .font(.caption2.monospaced().bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.message, forType: .string)
                    }
                    Button("Copy All Info") {
                        let fullLog = "[\(log.date.formatted())] \(log.message)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fullLog, forType: .string)
                    }
                }
                .id(log.id)
            }
            .listStyle(.plain)
            .onChange(of: relayService.logs.count) { _ in
                if autoScroll, let last = relayService.logs.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $autoScroll) {
                    Label("Auto-scroll", systemImage: "arrow.down.to.line")
                }
                .help("Follow new log lines")
            }

            ToolbarItem(placement: .automatic) {
                Button(action: {
                    let allLogs = relayService.logs.map { "[\($0.date.formatted())] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allLogs, forType: .string)
                }) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button(action: {
                    relayService.logs.removeAll()
                }) {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear log buffer")
            }
        }
    }
    
    func colorFor(type: RelayService.LogMessage.LogType) -> Color {
        switch type {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        }
    }
}
