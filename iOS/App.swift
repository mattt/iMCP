import BackgroundTasks
import OSLog
import SwiftUI
import UIKit

@main
struct MobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = PhoneConnection.shared

    var body: some Scene {
        WindowGroup {
            StatusView(connection: connection)
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
                connection.stop()
                MobileAppDelegate.scheduleRefresh()
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
    @State private var showingPairing = false
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Mac", value: connection.credentials?.macName ?? "Not paired")
                    LabeledContent("Status", value: statusText)
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
                        "iMCP sends data only to the Mac you pair, over your local network with encryption. Nothing goes to iCloud or another server."
                    )
                }

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
            .task { await connection.refreshQueue() }
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
            Toggle(domain.title, isOn: toggle)
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
                        "In iMCP on your Mac, open Settings > iPhone & iPad and click Pair, then scan the code. Both devices must be on the same network."
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
