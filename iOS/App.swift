import BackgroundTasks
import OSLog
import SwiftUI
import UIKit

@main
struct MobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = PhoneConnection.shared
    @StateObject private var approvals = PhoneApprovals.shared
    @StateObject private var activity = PhoneActivityStore.shared

    var body: some Scene {
        WindowGroup {
            StatusView(connection: connection, approvals: approvals, activity: activity)
                .onOpenURL { url in
                    // A pairing link opened from the Mac, for example through AirDrop.
                    guard let code = MobilePairingCode(url: url) else { return }
                    Task { try? await connection.pair(code) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                connection.start()
                Task { await PhoneBackend.shared.syncAll() }
            case .background:
                MobileAppDelegate.scheduleRefresh()
                // Stay connected for iOS's short grace period, so the Mac can still reach
                // an approval that arrives as the person leaves the app.
                Task {
                    await BackgroundWork.run("Stay reachable for approvals") {
                        try? await Task.sleep(for: .seconds(25))
                    }
                    if UIApplication.shared.applicationState != .active { connection.stop() }
                }
            default: break
            }
        }
    }
}

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    private static let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "app")
    static var refreshIdentifier: String { (Bundle.main.bundleIdentifier ?? "imcp.ios") + ".sync" }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PhoneApprovals.shared.configureNotifications()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            Self.handleRefresh(task)
        }
        // HealthKit relaunches the app for background delivery;
        // its observer queries must be registered before launch finishes.
        Task { await PhoneBackend.shared.startBackgroundDelivery() }
        return true
    }

    /// Asks iOS to wake the app later to collect changes and send them to the Mac.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("Couldn't schedule a background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handleRefresh(_ task: BGTask) {
        scheduleRefresh()
        let work = Task {
            await PhoneBackend.shared.syncAll()
            let flushed = await PhoneConnection.shared.flush()
            task.setTaskCompleted(success: flushed)
        }
        task.expirationHandler = { work.cancel() }
    }
}

// MARK: - Views

struct StatusView: View {
    @ObservedObject var connection: PhoneConnection
    @ObservedObject var approvals: PhoneApprovals
    @ObservedObject var activity: PhoneActivityStore
    @State private var showingPairing = false
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                ApprovalsSection(approvals: approvals)
                Section {
                    LabeledContent("Mac", value: connection.credentials?.macName ?? "Not paired")
                    LabeledContent("Status", value: statusText)
                    if let active = connection.activeTransport {
                        LabeledContent("Via", value: active.shortLabel)
                    }
                    NavigationLink {
                        TransportSettingsView(connection: connection)
                    } label: {
                        LabeledContent("Connection Mode", value: connection.transportMode.shortLabel)
                    }
                    if connection.queuedBatches > 0 {
                        LabeledContent("Waiting to send", value: "\(connection.queuedBatches) batches")
                    }
                    if connection.credentials == nil {
                        Button("Pair with a Mac") { showingPairing = true }
                    } else {
                        Button("Unpair", role: .destructive) { confirmingUnpair = true }
                    }
                } footer: {
                    Text(
                        "iMCP sends data only to the Mac you pair, encrypted with your device key over Local Network, Tailscale, or Cloudflare Tunnel. Nothing goes through iCloud."
                    )
                }

                ActivitySection(activity: activity)

                ForEach(MobileDomain.allCases, id: \.self) { domain in
                    ServiceSection(domain: domain)
                }
            }
            .navigationTitle("iMCP")
            .refreshable {
                await PhoneBackend.shared.syncAll()
                await connection.refreshQueue()
            }
            .sheet(isPresented: $showingPairing) {
                PairingView(connection: connection) { showingPairing = false }
            }
            .confirmationDialog(
                "Unpair from \(connection.credentials?.macName ?? "this Mac")?",
                isPresented: $confirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { Task { await connection.unpair() } }
            } message: {
                Text(
                    "This device stops sending data and asks the Mac to forget it. If no other device is paired, the Mac also deletes its copy of the data. If the Mac can't be reached, remove this device in iMCP Settings on the Mac."
                )
            }
            .task {
                await connection.refreshQueue()
                approvals.requestNotificationPermission()
                // Expired requests leave the screen on their own.
                while !Task.isCancelled {
                    approvals.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private var statusText: String {
        switch connection.phase {
        case .unpaired: return "Not paired"
        case .searching: return "Looking for the Mac"
        case .connected: return "Connected"
        case .failed(let message): return message
        }
    }
}

extension MobileDomain {
    /// The SF Symbol that stands for the service.
    var symbolName: String {
        switch self {
        case .health: return "heart.fill"
        case .alarms: return "alarm.fill"
        }
    }

    /// The color of the tile behind the symbol.
    var tint: Color {
        switch self {
        case .health: return .pink
        case .alarms: return .orange
        }
    }
}

/// A service's symbol on a rounded tile, like the icons in Settings.
struct ServiceIcon: View {
    let domain: MobileDomain

    var body: some View {
        Image(systemName: domain.symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(domain.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A service's switch, what it shares, and its permissions.
struct ServiceSection: View {
    let domain: MobileDomain
    @State private var enabled: Bool
    @State private var confirming = false
    @State private var error: String?
    @State private var details: [String: Value] = [:]

    init(domain: MobileDomain) {
        self.domain = domain
        _enabled = State(initialValue: PhoneSettings.isEnabled(domain))
    }

    var body: some View {
        Section {
            Toggle(isOn: toggle) {
                Label {
                    Text(domain.title)
                } icon: {
                    ServiceIcon(domain: domain)
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if enabled, let date = PhoneSettings.lastSync(domain) {
                LabeledContent("Last collected", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let note = details["note"]?.stringValue {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if domain == .health, enabled {
                NavigationLink("Health Data Access") { HealthAccessView() }
            }
            if domain == .alarms, enabled {
                NavigationLink("Alarms and Timers") { AlarmListView() }
            }
        } footer: {
            Text(domain.disclosure)
        }
        .alert("Share \(domain.title) with your Mac?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { Task { await setEnabled(true) } }
        } message: {
            Text(domain.disclosure)
        }
        .task { await refresh() }
    }

    private var toggle: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { value in
                if value {
                    confirming = true
                } else {
                    Task { await setEnabled(false) }
                }
            }
        )
    }

    private func setEnabled(_ value: Bool) async {
        do {
            try await PhoneBackend.shared.setEnabled(domain, value)
            enabled = value
            error = nil
        } catch {
            enabled = PhoneSettings.isEnabled(domain)
            self.error = error.localizedDescription
        }
        await refresh()
    }

    private func refresh() async {
        if case .object(let object) = await PhoneBackend.shared.services[domain]?.status() {
            details = object
        }
    }
}

struct PairingView: View {
    @ObservedObject var connection: PhoneConnection
    let done: () -> Void
    @State private var link = ""
    @State private var error: String?
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if PairingScanner.isAvailable {
                        PairingScanner { text in submit(text) }
                            .frame(height: 320)
                            .listRowInsets(EdgeInsets())
                    }
                } footer: {
                    Text(
                        "In iMCP on your Mac, open Settings > iPhone & iPad and click Pair, then scan the code or paste the pairing link."
                    )
                }
                Section("Or Paste the Pairing Link") {
                    TextField("imcp://pair?…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Pair") { submit(link) }
                        .disabled(link.isEmpty || pairing)
                }
                if pairing {
                    ProgressView("Pairing…")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Pair with a Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            }
        }
    }

    private func submit(_ text: String) {
        guard !pairing else { return }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let code = MobilePairingCode(url: url)
        else {
            error = "That isn't an iMCP pairing code."
            return
        }
        pairing = true
        Task {
            do {
                try await connection.pair(code)
                done()
            } catch {
                self.error = error.localizedDescription
            }
            pairing = false
        }
    }
}

struct TransportSettingsView: View {
    @ObservedObject var connection: PhoneConnection
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMode: MobileTransportMode
    @State private var tailnetHost: String
    @State private var tailnetPort: String
    @State private var funnelURL: String
    @State private var cloudflareURL: String
    @State private var error: String?

    init(connection: PhoneConnection) {
        self.connection = connection
        _selectedMode = State(initialValue: connection.transportMode)
        _tailnetHost = State(initialValue: connection.credentials?.tailnetHost ?? "")
        _tailnetPort = State(
            initialValue: connection.credentials?.tailnetPort.map(String.init)
                ?? String(MobileLink.defaultRemotePort)
        )
        _funnelURL = State(initialValue: connection.credentials?.funnelURL ?? "")
        _cloudflareURL = State(initialValue: connection.credentials?.cloudflareURL ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("Transport Mode", selection: $selectedMode) {
                    ForEach(MobileTransportMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Connection Mode")
            } footer: {
                Text(
                    "Automatic tries Local Network first, then Tailscale VPN, Tailscale Funnel, and Cloudflare Tunnel."
                )
            }

            if connection.credentials != nil {
                Section("Tailscale VPN") {
                    TextField("Mac Tailscale Host or IP", text: $tailnetHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port (\(MobileLink.defaultRemotePort))", text: $tailnetPort)
                        .keyboardType(.numberPad)
                }

                Section("Tailscale Funnel") {
                    TextField("wss://mac.tailnet.ts.net/mobile", text: $funnelURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("Cloudflare Tunnel") {
                    TextField("wss://imcp.example.com/mobile", text: $cloudflareURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            } else {
                Section {
                    Text("Pair with a Mac to customize remote endpoints.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Connection & Transports")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .onChange(of: selectedMode) { _, mode in
            connection.setTransportMode(mode)
        }
    }

    private func save() {
        connection.setTransportMode(selectedMode)
        if connection.credentials != nil {
            let trimmedPort = tailnetPort.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedPort = trimmedPort.isEmpty ? nil : UInt16(trimmedPort)
            if !trimmedPort.isEmpty, parsedPort == nil || parsedPort == 0 {
                error = "Enter a valid port from 1 to 65535."
                return
            }
            do {
                try connection.updateEndpoints(
                    tailnetHost: tailnetHost,
                    tailnetPort: parsedPort,
                    funnelURL: funnelURL,
                    cloudflareURL: cloudflareURL
                )
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        dismiss()
    }
}
