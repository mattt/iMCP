import Foundation
import SwiftUI

/// Stores synced Mac tool-call activity events on the iPhone or iPad.
///
/// Persisted in Application Support (never in the App Group container,
/// avoiding shared-container file locks while iOS suspends the app).
@MainActor
final class PhoneActivityStore: ObservableObject {
    static let shared = PhoneActivityStore()
    nonisolated static let maxEvents = 500

    private struct Snapshot: Codable {
        var events: [MobileActivityEvent]
        var highestAckedSequence: Int64
        var clearedThroughSequence: Int64
    }

    @Published private(set) var events: [MobileActivityEvent] = []

    private let url: URL?
    private let maxEvents: Int
    private var highestAckedSequence: Int64 = 0
    private var clearedThroughSequence: Int64 = 0

    init(
        url: URL? = try? MobileAppGroup.supportDirectory().appendingPathComponent("activity.json"),
        maxEvents: Int = PhoneActivityStore.maxEvents
    ) {
        self.url = url
        self.maxEvents = max(1, maxEvents)
        load()
    }

    func sync(_ request: MobileActivitySyncRequest) -> MobileActivitySyncResponse {
        let maxIncoming = request.events.map(\.sequence).max() ?? 0
        // If the Mac sequence restarted (e.g. Mac cache/activity reset), allow new sequence range.
        if maxIncoming > 0, maxIncoming < clearedThroughSequence,
            request.events.contains(where: { $0.sequence == 1 })
        {
            clearedThroughSequence = 0
            highestAckedSequence = 0
        }

        let eligible = request.events.filter { $0.sequence > clearedThroughSequence }
        if !eligible.isEmpty {
            var byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for event in eligible {
                byID[event.id] = event
            }
            let sorted = byID.values.sorted {
                if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
                return $0.timestamp > $1.timestamp
            }
            events = Array(sorted.prefix(maxEvents))
        }

        highestAckedSequence = max(highestAckedSequence, maxIncoming)
        save()
        return MobileActivitySyncResponse(ackedSequence: highestAckedSequence)
    }

    func clear() {
        clearedThroughSequence = max(clearedThroughSequence, highestAckedSequence)
        events = []
        save()
    }

    func reset() {
        events = []
        highestAckedSequence = 0
        clearedThroughSequence = 0
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func load() {
        guard let url, FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let snapshot = try? MobileCoding.decoder.decode(Snapshot.self, from: data)
        else { return }
        events = Array(snapshot.events.prefix(maxEvents))
        highestAckedSequence = snapshot.highestAckedSequence
        clearedThroughSequence = snapshot.clearedThroughSequence
    }

    private func save() {
        guard let url else { return }
        let snapshot = Snapshot(
            events: events,
            highestAckedSequence: highestAckedSequence,
            clearedThroughSequence: clearedThroughSequence
        )
        guard let data = try? MobileCoding.encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Views

enum ActivityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case writes = "Writes"
    case reads = "Reads"
    case deniedOrFailed = "Denied/Failed"

    var id: String { rawValue }

    func matches(_ event: MobileActivityEvent) -> Bool {
        switch self {
        case .all: return true
        case .writes: return event.isWrite
        case .reads: return !event.isWrite
        case .deniedOrFailed: return event.outcome != .succeeded
        }
    }
}

struct ActivitySection: View {
    @ObservedObject var activity: PhoneActivityStore

    var body: some View {
        Section {
            NavigationLink {
                ActivityView(activity: activity)
            } label: {
                LabeledContent("Activity History") {
                    Text(activity.events.isEmpty ? "None" : "\(activity.events.count)")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(activity.events.prefix(3)) { event in
                ActivityRow(event: event)
            }
        } header: {
            Text("Activity")
        } footer: {
            Text("Records every tool call processed by iMCP on your Mac.")
        }
    }
}

struct ActivityView: View {
    @ObservedObject var activity: PhoneActivityStore
    @State private var filter: ActivityFilter = .all
    @State private var searchText = ""
    @State private var confirmingClear = false

    private var filteredEvents: [MobileActivityEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return activity.events.filter { event in
            guard filter.matches(event) else { return false }
            guard !query.isEmpty else { return true }
            return event.clientName.localizedCaseInsensitiveContains(query)
                || event.serviceName.localizedCaseInsensitiveContains(query)
                || event.toolName.localizedCaseInsensitiveContains(query)
                || (event.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ActivityFilter.allCases) { option in
                            Button {
                                filter = option
                            } label: {
                                Text(option.rawValue)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        filter == option
                                            ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(Color(.secondarySystemFill)),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(filter == option ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }

            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    activity.events.isEmpty ? "No Activity Yet" : "No Matching Events",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        activity.events.isEmpty
                            ? "Tool calls run on your paired Mac appear here."
                            : "Try another filter or search term."
                    )
                )
            } else {
                ForEach(filteredEvents) { event in
                    ActivityRow(event: event)
                }
            }
        }
        .navigationTitle("Activity")
        .searchable(text: $searchText, prompt: "Client, service, or tool")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", role: .destructive) { confirmingClear = true }
                    .disabled(activity.events.isEmpty)
            }
        }
        .confirmationDialog("Clear activity history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { activity.clear() }
        } message: {
            Text("Removes synced tool-call history from this device.")
        }
    }
}

struct ActivityRow: View {
    let event: MobileActivityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(event.toolName)
                    .font(.headline.monospaced())
                    .lineLimit(1)
                Spacer()
                badge(
                    event.isWrite ? "Write" : "Read",
                    color: event.isWrite ? .orange : .blue
                )
                badge(outcomeLabel, color: outcomeColor)
            }

            HStack {
                Text("\(event.clientName) · \(event.serviceName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(event.durationMs) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(event.outcome == .succeeded ? .secondary : outcomeColor)
                    .lineLimit(3)
            }

            Text(event.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var outcomeLabel: String {
        switch event.outcome {
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .denied: return "Denied"
        }
    }

    private var outcomeColor: Color {
        switch event.outcome {
        case .succeeded: return .green
        case .failed: return .red
        case .denied: return .orange
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
