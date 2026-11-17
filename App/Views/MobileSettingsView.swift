import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairing, sync status, transport configuration, and cached data for iMCP on iPhone and iPad.
struct MobileSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var devices: [MobileDevice] = []
    @State private var connected: MobileDevice?
    @State private var connectedTransport: MobileTransportMode?
    @State private var syncedAt: [MobileDomain: Date] = [:]
    @State private var code: MobilePairingCode?
    @State private var expires: Date?
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var removing: MobileDevice?
    @AppStorage(RemoteApprovals.defaultsKey) private var approveOnIPhone = true
    @AppStorage(MobileService.transportModeKey) private var transportModeRaw = MobileTransportMode.automatic.rawValue
    @AppStorage(MobileService.tailscaleVPNEnabledKey) private var tailscaleVPNEnabled = true
    @AppStorage(MobileService.tailscaleHostOverrideKey) private var tailscaleHostOverride = ""
    @AppStorage(MobileService.remotePortKey) private var remotePort = Int(MobileLink.defaultRemotePort)
    @AppStorage(MobileService.cloudflareEnabledKey) private var cloudflareEnabled = false
    @AppStorage(MobileService.cloudflareURLKey) private var cloudflareURL = ""
    @AppStorage(MobileService.cloudflareLocalPortKey) private var cloudflareLocalPort = Int(
        MobileLink.defaultWebSocketPort
    )
    @State private var isAdvancedExpanded = false

    private var transportMode: Binding<MobileTransportMode> {
        Binding(
            get: { MobileTransportMode(rawValue: transportModeRaw) ?? .automatic },
            set: { transportModeRaw = $0.rawValue }
        )
    }

    private var connectionSummary: String {
        guard connected != nil else { return "Not connected" }
        if let connectedTransport {
            return "Connected via \(connectedTransport.shortLabel)"
        }
        return "Connected"
    }

    private var activeTailnetHost: String? {
        if case .running(let endpoint) = serverController.remoteAccessState {
            return endpoint.dnsName ?? endpoint.ipv4Address
        }
        return nil
    }

    private var activeFunnelURL: String? {
        if case .running(let endpoint) = serverController.remoteAccessState {
            return endpoint.mobileWebSocketURL
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if devices.isEmpty {
                    Text("No iPhone or iPad is paired.")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(connected?.id == device.id ? connectionSummary : "Not connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove…") { removing = device }
                    }
                }
                if let code, let expires {
                    pairingCode(code, expires: expires)
                } else {
                    Button("Pair iPhone or iPad…") { Task { await beginPairing() } }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Paired Devices")
            } footer: {
                Text(
                    "Build and install iMCP for iOS with Scripts/install-ios.sh from the iMCP repository. Connections are end-to-end encrypted with your device key, and nothing goes through iCloud."
                )
            }

            Section {
                Picker("Connection Route", selection: transportMode) {
                    ForEach(MobileTransportMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                DisclosureGroup("Developer & Advanced", isExpanded: $isAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Allow Tailscale VPN", isOn: $tailscaleVPNEnabled)
                        if tailscaleVPNEnabled {
                            LabeledContent("Tailscale Host Override") {
                                TextField(
                                    "Tailscale Host",
                                    text: $tailscaleHostOverride,
                                    prompt: Text(activeTailnetHost ?? "Auto from Remote Access")
                                )
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 220)
                            }
                            LabeledContent("Tailscale Mobile Port") {
                                TextField("Port", value: $remotePort, format: .number.grouping(.never))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                            }
                        }

                        if let funnelURL = activeFunnelURL {
                            LabeledContent("Tailscale Funnel Mobile URL") {
                                HStack {
                                    Text(funnelURL)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Button("Copy") { copyToPasteboard(funnelURL) }
                                }
                            }
                        }

                        Toggle("Custom Cloudflare Mobile Override", isOn: $cloudflareEnabled)
                        if cloudflareEnabled {
                            LabeledContent("Cloudflare Mobile URL") {
                                TextField("wss://example.com/mobile", text: $cloudflareURL)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 240)
                            }
                            LabeledContent("Local WebSocket Port") {
                                TextField("Port", value: $cloudflareLocalPort, format: .number.grouping(.never))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } header: {
                Text("Connection Route")
            } footer: {
                Text(
                    "In Automatic mode, your iPhone or iPad connects over Local Wi-Fi first, then falls back to Tailscale VPN, Tailscale Funnel, or Cloudflare Tunnel."
                )
            }
            .onChange(of: transportModeRaw) { _, _ in applyTransportSettings() }
            .onChange(of: tailscaleVPNEnabled) { _, _ in applyTransportSettings() }
            .onChange(of: remotePort) { _, _ in applyTransportSettings() }
            .onChange(of: cloudflareEnabled) { _, _ in applyTransportSettings() }
            .onChange(of: cloudflareLocalPort) { _, _ in applyTransportSettings() }

            Section {
                Toggle(
                    "Approve on iPhone",
                    isOn: Binding(
                        get: { approveOnIPhone && !devices.isEmpty },
                        set: { approveOnIPhone = $0 }
                    )
                )
                .disabled(devices.isEmpty)
            } footer: {
                Text(
                    "Connection requests, public access requests, and message, email, and call confirmations also show on your paired iPhone, and the first answer from either device wins. A request that nobody answers is denied."
                )
            }

            Section {
                ForEach(MobileDomain.allCases, id: \.self) { domain in
                    LabeledContent(domain.label, value: syncText(domain))
                }
                Button("Delete Cached Data…", role: .destructive) { confirmingDelete = true }
            } header: {
                Text("Data on This Mac")
            } footer: {
                Text(
                    "iMCP keeps a copy of what the iPhone or iPad sends, so tools can answer when it's locked or away, and answers say when the data last synced. The contents of each record are encrypted, but record types, identifiers, and dates aren't, so that queries can filter on them. Removing the last paired device deletes the copy."
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("iPhone & iPad")
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Delete the cached iPhone and iPad data?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await MobileService.shared.deleteCache()
                    } catch {
                        self.error = error.localizedDescription
                    }
                    await refresh()
                }
            }
        } message: {
            Text(
                "iMCP deletes its copy of Health and Alarms data. If a device stays paired, it sends its data again the next time it connects."
            )
        }
        .alert(
            "Remove \(removing?.name ?? "this device")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                guard let device = removing else { return }
                removing = nil
                Task {
                    await MobileService.shared.unpair(device.id)
                    await refresh()
                }
            }
        } message: {
            Text(
                devices.count > 1
                    ? "The device can't connect again until you pair it again. The cached data stays, because other paired devices use it."
                    : "The device can't connect again until you pair it again. iMCP also deletes its cached data from this Mac."
            )
        }
    }

    @ViewBuilder
    private func pairingCode(_ code: MobilePairingCode, expires: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                if let image = Self.qrImage(code.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .accessibilityLabel("Pairing code")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan this code in iMCP on your iPhone or iPad.")
                    Text("The code works once, until \(expires.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.url.absoluteString, forType: .string)
                        }
                        Button("Cancel") {
                            Task {
                                await MobileService.shared.cancelPairing()
                                self.code = nil
                                self.expires = nil
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func beginPairing() async {
        do {
            code = try await MobileService.shared.beginPairing()
            expires = Date().addingTimeInterval(MobileService.pairingLifetime)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        let service = MobileService.shared
        let before = devices
        devices = await service.devices
        connected = await service.connectedDevice
        connectedTransport = await service.connectedTransport
        for domain in MobileDomain.allCases {
            syncedAt[domain] = await service.syncedAt(domain)
        }
        let pairing = await service.isPairing
        if code != nil, !pairing {
            // The code was used or expired.
            if devices.count > before.count { error = nil }
            code = nil
            expires = nil
        }
        if code == nil, let message = await service.pairingError { error = message }
    }

    private func applyTransportSettings() {
        serverController.refreshRemoteMobileConfiguration()
        Task { await MobileService.shared.applyTransportSettings() }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func syncText(_ domain: MobileDomain) -> String {
        guard let date = syncedAt[domain] else { return "Never synced" }
        let stale = MobileEnvelope.isStale(domain, syncedAt: date, now: Date())
        return "Synced \(date.formatted(.relative(presentation: .named)))\(stale ? " (stale)" : "")"
    }

    private static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

extension MobileDomain {
    var label: String {
        switch self {
        case .health: return "Health"
        case .alarms: return "Alarms"
        }
    }
}
