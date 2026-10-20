import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairing, sync status, and cached data for iMCP on iPhone and iPad.
struct MobileSettingsView: View {
    @State private var devices: [MobileDevice] = []
    @State private var connected: MobileDevice?
    @State private var syncedAt: [MobileDomain: Date] = [:]
    @State private var code: MobilePairingCode?
    @State private var expires: Date?
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var removing: MobileDevice?

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
                            Text(connected?.id == device.id ? "Connected" : "Not connected")
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
                    "Build and install iMCP for iOS with Scripts/install-ios.sh from the iMCP repository. The device connects to this Mac over your local network with encryption, and nothing goes through iCloud or another server."
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
