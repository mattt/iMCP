import SwiftUI

/// Which routes the phone may use to reach the Mac, and the addresses it knows for them.
struct TransportSettingsView: View {
    @ObservedObject var connection: PhoneConnection
    @Environment(\.dismiss) private var dismiss

    @State private var tailnetHost: String
    @State private var tailnetPort: String
    @State private var funnelURL: String
    @State private var cloudflareURL: String
    @State private var error: String?
    @State private var isRefreshing = false
    @State private var refreshMessage: String?

    init(connection: PhoneConnection) {
        self.connection = connection
        let credentials = connection.credentials
        _tailnetHost = State(initialValue: credentials?.tailnetHost ?? "")
        _tailnetPort = State(initialValue: credentials?.tailnetPort.map(String.init) ?? "")
        _funnelURL = State(initialValue: credentials?.funnelURL ?? "")
        _cloudflareURL = State(initialValue: credentials?.cloudflareURL ?? "")
    }

    var body: some View {
        Form {
            configurationSection

            Section {
                ForEach(MobileTransportMode.allCases, id: \.self) { mode in
                    let reason = connection.credentials?.unavailableReason(for: mode)
                    Button {
                        connection.setTransportMode(mode)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.label)
                                if let reason {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if connection.transportMode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(reason != nil)
                    .accessibilityAddTraits(connection.transportMode == mode ? .isSelected : [])
                }
            } header: {
                Text("Connection Mode")
            } footer: {
                Text(
                    connection.credentials?.configuration == nil
                        ? "Automatic tries the local network first, then each other route the Mac has offered. A route is unavailable until the Mac offers an address for it."
                        : "Automatic follows the Mac: it tries the routes in the order the Mac lists them above. Choose another mode to use one route only."
                )
            }

            if connection.credentials != nil, connection.credentials?.configuration == nil {
                Section {
                    TextField("Host or IP", text: $tailnetHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $tailnetPort)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Tailscale VPN")
                } footer: {
                    Text(
                        "This Mac hasn't sent a configuration, so these addresses are from pairing. Change them only if the Mac's address changed."
                    )
                }

                Section("Tailscale Funnel") {
                    TextField("wss://mac.example.ts.net/mobile", text: $funnelURL)
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
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Connection Mode")
        .toolbar {
            if connection.credentials != nil, connection.credentials?.configuration == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        if let configuration = connection.credentials?.configuration {
            Section {
                LabeledContent("Configured by", value: "\(configuration.macName) (revision \(configuration.revision))")
                ForEach(Array(configuration.routes.enumerated()), id: \.element.id) { index, route in
                    LabeledContent("\(index + 1). \(route.label)", value: status(of: route))
                }
                Button {
                    Task { await refreshConfiguration() }
                } label: {
                    HStack {
                        Text("Refresh Configuration")
                        if isRefreshing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRefreshing)
                if let refreshMessage {
                    Text(refreshMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Routes From Your Mac")
            } footer: {
                Text(
                    "Your Mac decides which routes to offer and in what order. Change them in iMCP on the Mac, in the iPhone & iPad settings. This phone updates when it connects."
                )
            }
        } else if connection.credentials != nil {
            Section {
                Button {
                    Task { await refreshConfiguration() }
                } label: {
                    Text("Refresh Configuration")
                }
                .disabled(isRefreshing)
                if let refreshMessage {
                    Text(refreshMessage).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("This phone hasn't received a configuration from the Mac yet. It uses the addresses from pairing.")
            }
        }
    }

    private func status(of route: MobileRoute) -> String {
        if connection.phase == .connected, connection.activeTransport == route.kind.mode { return "Connected" }
        let mode = connection.transportMode
        if mode != .automatic, mode != route.kind.mode { return "Not used in this mode" }
        return "Ready"
    }

    private func refreshConfiguration() async {
        isRefreshing = true
        refreshMessage = nil
        refreshMessage = await connection.refreshConfiguration()
        isRefreshing = false
    }

    private func save() {
        let trimmedPort = tailnetPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = trimmedPort.isEmpty ? nil : UInt16(trimmedPort)
        if !trimmedPort.isEmpty, port == nil || port == 0 {
            error = "Enter a port from 1 to 65535."
            return
        }
        do {
            try connection.updateEndpoints(
                tailnetHost: tailnetHost,
                tailnetPort: port,
                funnelURL: funnelURL,
                cloudflareURL: cloudflareURL
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
