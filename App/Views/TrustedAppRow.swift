import AppKit
import SwiftUI

/// One trusted client in Settings: its icon, name, signer, and last connection.
struct TrustedAppRow: View {
    let client: ClientRecord
    let onRemove: () -> Void

    private var icon: NSImage {
        if let path = client.bundlePath { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil) ?? NSImage()
    }

    /// The signer for an app, or a note for a client that uses a credential.
    private var signer: String {
        if client.isApp {
            if let team = client.teamIdentifier { return "Team ID \(team)" }
            return client.teamName ?? "Apple"
        }
        return "Credential"
    }

    private var lastConnection: String {
        if let date = client.lastConnectedAt {
            return "Last connected \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Not connected since it was trusted"
    }

    var body: some View {
        LabeledContent {
            Button("Remove", action: onRemove)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(client.name)
                    Text("\(signer) · \(lastConnection)")
                }
            }
        }
    }
}
