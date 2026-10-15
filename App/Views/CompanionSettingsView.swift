import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairing, sync status, and cached data for iMCP Companion on the iPhone.
struct CompanionSettingsView: View {
    @State private var devices: [CompanionDevice] = []
    @State private var connected: CompanionDevice?
    @State private var syncedAt: [CompanionDomain: Date] = [:]
    @State private var code: CompanionPairingCode?
    @State private var expires: Date?
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var removing: CompanionDevice?

    var body: some View {
        Form {
            Section {
                if devices.isEmpty {
                    Text("No iPhone is paired.")
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
                    Button("Pair iPhone…") { Task { await beginPairing() } }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("iPhone")
            } footer: {
                Text(
                    "Build and install iMCP Companion with Scripts/install-companion.sh from the iMCP repository. The iPhone connects to this Mac over your local network with encryption, and nothing goes through iCloud or another server."
                )
            }

            Section {
                ForEach(CompanionDomain.allCases, id: \.self) { domain in
                    LabeledContent(domain.label, value: syncText(domain))
                }
                Button("Delete Cached Data…", role: .destructive) { confirmingDelete = true }
            } header: {
                Text("Data on This Mac")
            } footer: {
                Text(
                    "iMCP keeps an encrypted copy of what the iPhone sends, so tools can answer when the iPhone is locked or away. Answers say when the data last synced."
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
        .alert("Delete the cached iPhone data?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await CompanionService.shared.deleteCache()
                    } catch {
                        self.error = error.localizedDescription
                    }
                    await refresh()
                }
            }
        } message: {
            Text(
                "iMCP deletes its copy of Health, Finance, and Alarms data. If the iPhone stays paired, it sends its data again the next time it connects."
            )
        }
        .alert(
            "Remove \(removing?.name ?? "this iPhone")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                guard let device = removing else { return }
                removing = nil
                Task {
                    await CompanionService.shared.unpair(device.id)
                    await refresh()
                }
            }
        } message: {
            Text("The iPhone can't connect again until you pair it again. Cached data stays until you delete it.")
        }
    }

    @ViewBuilder
    private func pairingCode(_ code: CompanionPairingCode, expires: Date) -> some View {
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
                    Text("Scan this code in iMCP Companion on your iPhone.")
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
                                await CompanionService.shared.cancelPairing()
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
            code = try await CompanionService.shared.beginPairing()
            expires = Date().addingTimeInterval(CompanionService.pairingLifetime)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        let service = CompanionService.shared
        let before = devices
        devices = await service.devices
        connected = await service.connectedDevice
        for domain in CompanionDomain.allCases {
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

    private func syncText(_ domain: CompanionDomain) -> String {
        guard let date = syncedAt[domain] else { return "Never synced" }
        let stale = CompanionEnvelope.isStale(domain, syncedAt: date, now: Date())
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

extension CompanionDomain {
    var label: String {
        switch self {
        case .health: return "Health"
        case .finance: return "Finance"
        case .alarms: return "Alarms"
        }
    }
}
