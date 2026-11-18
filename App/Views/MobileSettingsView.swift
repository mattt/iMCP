import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Paired iPhones and iPads, the routes they use to reach this Mac, and what they share.
struct MobileSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var devices: [MobileDevice] = []
    @State private var connected: MobileDevice?
    @State private var connectedTransport: MobileTransportMode?
    @State private var code: MobilePairingCode?
    @State private var expires: Date?
    @State private var error: String?
    @State private var removing: MobileDevice?
    @AppStorage(RemoteApprovals.defaultsKey) private var approveOnIPhone = true
    @AppStorage(MobileService.transportModeKey) private var transportModeRaw = MobileTransportMode.automatic.rawValue
    @State private var routes: [MobileConfigurationBuilder.Entry] = []
    @AppStorage(MobileService.activityHistoryKey) private var activityHistoryEnabled = true

    private var transportMode: Binding<MobileTransportMode> {
        Binding(
            get: { MobileTransportMode(rawValue: transportModeRaw) ?? .automatic },
            set: { transportModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                if devices.isEmpty {
                    EmptyRow(symbol: "iphone", text: "No devices paired")
                }
                ForEach(devices) { device in
                    deviceRow(device)
                }
                Button("Pair a New Device…") { Task { await beginPairing() } }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Devices")
            }

            Section {
                ForEach(routes) { entry in
                    Toggle(isOn: routeBinding(entry.kind)) {
                        RowLabel(title: entry.kind.settingsName, subtitle: routeNote(entry)) {
                            SettingsIcon(symbol: entry.kind.settingsSymbol, color: .blue)
                        }
                    }
                    .contextMenu {
                        Button("Move Up") { moveRoute(entry.kind, by: -1) }
                        Button("Move Down") { moveRoute(entry.kind, by: 1) }
                    }
                }
                .onMove { source, destination in
                    var order = routes.map(\.kind)
                    order.move(fromOffsets: source, toOffset: destination)
                    saveRouteOrder(order)
                }
            } header: {
                Text("Routes")
            } footer: {
                Text("AI apps and your phone try these in order.")
            }

            Section {
                Picker(selection: transportMode) {
                    ForEach(MobileTransportMode.allCases, id: \.self) { mode in
                        Text(mode.shortLabel).tag(mode)
                    }
                } label: {
                    RowLabel(title: "Connect via") {
                        SettingsIcon(symbol: "point.3.connected.trianglepath.dotted", color: .indigo)
                    }
                }
                .pickerStyle(.menu)

                Toggle(
                    isOn: Binding(
                        get: { approveOnIPhone && !devices.isEmpty },
                        set: { approveOnIPhone = $0 }
                    )
                ) {
                    RowLabel(title: "Approve on iPhone") {
                        SettingsIcon(symbol: "checkmark.message.fill", color: .green)
                    }
                }
                .disabled(devices.isEmpty)
                .onChange(of: approveOnIPhone) {
                    Task { await MobileService.shared.servicesChanged() }
                }

                Toggle(isOn: $activityHistoryEnabled) {
                    RowLabel(title: "Activity history on iPhone") {
                        SettingsIcon(symbol: "clock.arrow.circlepath", color: .orange)
                    }
                }
            }
            .onChange(of: activityHistoryEnabled) { _, _ in applyTransportSettings() }
            .onChange(of: transportModeRaw) { _, _ in applyTransportSettings() }

        }
        .formStyle(.grouped)
        .navigationTitle("iPhone & iPad")
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(
            isPresented: Binding(
                get: { code != nil },
                set: { isShown in
                    if !isShown { cancelPairing() }
                }
            )
        ) {
            if let code, let expires {
                pairingSheet(code, expires: expires)
            }
        }
        .alert(
            "Unpair \(removing?.name ?? "this device")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Unpair", role: .destructive) {
                guard let device = removing else { return }
                removing = nil
                Task {
                    await MobileService.shared.unpair(device.id)
                    await refresh()
                }
            }
        } message: {
            Text("It can't connect again until you pair it again.")
        }
    }

    // MARK: Rows

    private func deviceRow(_ device: MobileDevice) -> some View {
        let isConnected = connected?.id == device.id
        return LabeledContent {
            Menu {
                Button("Refresh Configuration") { applyTransportSettings() }
                Button("Unpair…", role: .destructive) { removing = device }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        } label: {
            HStack(spacing: 10) {
                SettingsIcon(
                    symbol: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone",
                    color: isConnected ? .green : .gray
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    HStack(spacing: 6) {
                        StatusBadge(text: isConnected ? "Connected" : "Away", kind: isConnected ? .good : .neutral)
                        if isConnected, let connectedTransport {
                            Text("via \(connectedTransport.shortLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// The one line under a route, or nil when the route needs no explanation.
    private func routeNote(_ entry: MobileConfigurationBuilder.Entry) -> String? {
        guard entry.enabled else { return nil }
        if entry.address == nil { return "No address yet" }
        return entry.isOffered ? nil : "Not offered in local-only mode"
    }

    private func pairingSheet(_ code: MobilePairingCode, expires: Date) -> some View {
        VStack(spacing: 16) {
            if let image = Self.qrImage(code.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .accessibilityLabel("Pairing code")
            }
            VStack(spacing: 4) {
                Text("Scan in iMCP on your iPhone or iPad")
                    .font(.headline)
                Text("Works once, until \(expires.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy Link") { copyToSettingsPasteboard(code.url.absoluteString) }
                Button("Cancel", role: .cancel) { cancelPairing() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private func cancelPairing() {
        Task {
            await MobileService.shared.cancelPairing()
            code = nil
            expires = nil
        }
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
        routes = MobileConfigurationBuilder.entries(await service.currentState)
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
        Task {
            await MobileService.shared.applyTransportSettings()
            await refresh()
        }
    }

    private func routeBinding(_ kind: MobileRouteKind) -> Binding<Bool> {
        Binding(
            get: { routes.first { $0.kind == kind }?.enabled ?? true },
            set: { enabled in
                MobileService.setRoute(kind, enabled: enabled)
                if let index = routes.firstIndex(where: { $0.kind == kind }) { routes[index].enabled = enabled }
                applyTransportSettings()
            }
        )
    }

    private func moveRoute(_ kind: MobileRouteKind, by offset: Int) {
        var order = routes.map(\.kind)
        guard let index = order.firstIndex(of: kind), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        saveRouteOrder(order)
    }

    private func saveRouteOrder(_ order: [MobileRouteKind]) {
        MobileService.setRouteOrder(order)
        routes = order.compactMap { kind in routes.first { $0.kind == kind } }
        applyTransportSettings()
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
