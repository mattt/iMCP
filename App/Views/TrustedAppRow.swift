import AppKit
import SwiftUI

/// One trusted client in Settings: its logo or icon, its name, and when it last connected.
struct TrustedAppRow: View {
    let client: ClientRecord
    let onRemove: () -> Void

    private var lastConnection: String {
        if let date = client.lastConnectedAt {
            return "Used \(date.formatted(.relative(presentation: .named)))"
        }
        return "Not used yet"
    }

    var body: some View {
        LabeledContent {
            Button("Remove", action: onRemove)
        } label: {
            RowLabel(title: client.name, subtitle: lastConnection) {
                if let known = KnownClient.match(name: client.name) {
                    ClientLogo(client: known)
                } else if let path = client.bundlePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                } else {
                    SettingsIcon(symbol: "terminal.fill", color: .gray)
                }
            }
        }
    }
}
