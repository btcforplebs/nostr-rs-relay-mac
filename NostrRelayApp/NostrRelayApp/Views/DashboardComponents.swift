import SwiftUI

// MARK: - Formatting

/// One place for every number the dashboard prints, so units and precision stay
/// consistent across dozens of tiles.
enum Fmt {

    static func bytes(_ value: Int64?) -> String {
        guard let value = value else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    static func bytes(_ value: Int?) -> String { bytes(value.map(Int64.init)) }

    /// Compact counts: 1234 -> 1.2K, 4500000 -> 4.5M.
    static func count(_ value: Int?) -> String {
        guard let value = value else { return "—" }
        return count(Double(value))
    }

    static func count(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        let abs = Swift.abs(value)
        switch abs {
        case 0..<1_000:
            return String(format: "%.0f", value)
        case 1_000..<1_000_000:
            return String(format: "%.1fK", value / 1_000)
        case 1_000_000..<1_000_000_000:
            return String(format: "%.1fM", value / 1_000_000)
        default:
            return String(format: "%.1fB", value / 1_000_000_000)
        }
    }

    /// Per-second rates keep one decimal below 10 so slow relays don't read "0".
    static func rate(_ value: Double?, unit: String = "/s") -> String {
        guard let value = value else { return "—" }
        if value == 0 { return "0\(unit)" }
        if value < 10 { return String(format: "%.2f%@", value, unit) }
        return "\(count(value))\(unit)"
    }

    /// Seconds -> ms/µs, picking the unit that keeps the number readable.
    static func latency(_ seconds: Double?) -> String {
        guard let seconds = seconds, seconds > 0 else { return "—" }
        if seconds < 0.001 { return String(format: "%.0fµs", seconds * 1_000_000) }
        if seconds < 1 { return String(format: "%.1fms", seconds * 1_000) }
        return String(format: "%.2fs", seconds)
    }

    /// Compact uptime: 3d 4h, 2h 11m, 45s.
    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval = interval, interval >= 0 else { return "—" }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func date(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relative(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func percent(_ value: Double?, decimals: Int = 1) -> String {
        guard let value = value else { return "—" }
        return String(format: "%.\(decimals)f%%", value)
    }

    /// Human names for the event kinds a relay actually sees most.
    static func kindName(_ kind: Int) -> String {
        switch kind {
        case 0: return "Metadata"
        case 1: return "Note"
        case 2: return "Relay Rec."
        case 3: return "Contacts"
        case 4: return "DM"
        case 5: return "Deletion"
        case 6: return "Repost"
        case 7: return "Reaction"
        case 8: return "Badge Award"
        case 40...44: return "Chat"
        case 1984: return "Report"
        case 9734: return "Zap Req."
        case 9735: return "Zap"
        case 10002: return "Relay List"
        case 30023: return "Long-form"
        case 10000...19999: return "Replaceable"
        case 20000...29999: return "Ephemeral"
        case 30000...39999: return "Param. Repl."
        default: return "Kind \(kind)"
        }
    }
}

// MARK: - Tone

/// Reserved status colors. Every use is paired with a text label so state is
/// never communicated by color alone.
enum Tone {
    case neutral, good, warning, critical, accent

    var color: Color {
        switch self {
        case .neutral: return .primary
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .accent: return .havenPurpleLight
        }
    }
}

// MARK: - Layout primitives

/// A titled card. Sections carry an optional trailing accessory (refresh state,
/// a badge) and collapse their chrome into the standard control background.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String
    var subtitle: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let accessory = accessory {
                    accessory
                }
            }

            content()
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

/// The dashboard's tile grid. Adaptive columns keep tiles legible from a narrow
/// window up to a full-screen one without hardcoding a column count.
struct MetricGrid<Content: View>: View {
    var minWidth: CGFloat = 128
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10)],
            alignment: .leading,
            spacing: 10,
            content: content
        )
    }
}

/// A single data point: label on top, value as the hero, optional caption below.
struct StatTile: View {
    let label: String
    let value: String
    var caption: String? = nil
    var tone: Tone = .neutral
    var systemImage: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(tone == .neutral ? .primary : tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let caption = caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .help(help ?? label)
    }
}

/// State badge — icon plus word, so it survives grayscale and colorblind viewing.
struct StatusPill: View {
    let text: String
    let tone: Tone
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage = systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            } else {
                Circle().frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Charts

/// Single-series sparkline for a rate over time. No axes or legend: the tile
/// label names the series and the accompanying value gives the current reading.
struct Sparkline: View {
    let values: [Double]
    var tone: Tone = .accent
    var height: CGFloat = 36

    /// Maps a sample to its position in the plot area. Kept off the ViewBuilder
    /// closure, which cannot contain declarations.
    private func point(index: Int, value: Double, in size: CGSize) -> CGPoint {
        let maximum = max(values.max() ?? 0, 0.0001)
        let stepX = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return CGPoint(
            x: CGFloat(index) * stepX,
            y: size.height - CGFloat(value / maximum) * size.height
        )
    }

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                // Area first, so the 2px stroke sits cleanly on top of it.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    for (index, value) in values.enumerated() {
                        path.addLine(to: point(index: index, value: value, in: geo.size))
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [tone.color.opacity(0.28), tone.color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    for (index, value) in values.enumerated() {
                        let pt = point(index: index, value: value, in: geo.size)
                        index == 0 ? path.move(to: pt) : path.addLine(to: pt)
                    }
                }
                .stroke(tone.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                // Recessive baseline stands in for "not enough samples yet".
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            }
        }
        .frame(height: height)
    }
}

/// Column chart for a bucketed series (events per hour, per day). Bars carry
/// 4px rounded tops anchored to the baseline with a 2px gap between them.
struct MiniBarChart: View {
    let values: [Int]
    var tone: Tone = .accent
    var height: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let maximum = max(values.max() ?? 0, 1)
            let count = max(values.count, 1)
            let slot = geo.size.width / CGFloat(count)
            let barWidth = max(slot - 2, 1)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(value == 0 ? Color.secondary.opacity(0.15) : tone.color.opacity(0.75))
                        .frame(
                            width: barWidth,
                            height: max(CGFloat(value) / CGFloat(maximum) * geo.size.height, 2)
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .frame(height: height)
    }
}

/// Ranked magnitude list — one hue, length encodes the value, value printed
/// directly so the bar never has to be measured against an axis.
struct BarList: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        let value: Double
        var detail: String? = nil
    }

    let items: [Item]
    var tone: Tone = .accent
    var emptyText: String = "No data yet"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                let maximum = max(items.map(\.value).max() ?? 1, 1)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.label)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.detail ?? Fmt.count(item.value))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tone.color.opacity(0.7))
                                .frame(width: max(geo.size.width * CGFloat(item.value / maximum), 2))
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}

/// Label/value line for identity data that isn't a metric (paths, versions).
struct DetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var selectable: Bool = true

    private var valueText: Text {
        Text(value).font(.system(size: 11, design: monospaced ? .monospaced : .default))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Group {
                if selectable {
                    valueText.textSelection(.enabled)
                } else {
                    valueText.textSelection(.disabled)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }
}
