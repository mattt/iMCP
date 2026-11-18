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
                    "Automatic tries the local network first, then each other route the Mac has offered. A route is unavailable until the Mac offers an address for it."
                )
            }

            if connection.credentials != nil {
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
                    Text("The Mac fills these in when it connects. Change them only if the Mac's address changed.")
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
            if connection.credentials != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
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
