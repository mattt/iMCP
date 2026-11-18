import SwiftUI

/// Asks the owner to let an app use iMCP through public access.
///
/// It shows what the owner needs to judge the request:
/// the app's name, the address that the approval goes back to, and the services that the app gets.
/// The app chooses its name freely, so the address is the part to check.
struct OAuthApprovalView: View {
    let request: OAuthApprovalRequest
    let enabledServiceNames: [String]
    /// The parameter is whether the app may only read.
    let onApprove: (Bool) -> Void
    let onDeny: () -> Void

    @State private var readOnly = true
    @State private var canAllow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(.menuIconOn)
                .resizable()
                .foregroundColor(.accentColor)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            Text("App Access Request")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("Allow \"\(request.clientName)\" to use iMCP over the internet?")
                VStack(spacing: 2) {
                    Text(request.verificationCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(request.confirmationPrompt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                LabeledContent("Client ID", value: request.clientID)
                    .font(.callout)
                LabeledContent("Returns to", value: request.redirectURI)
                    .font(.callout)
                if request.redirectsToThisMac {
                    Text(
                        "This address is on this Mac, so any app on it can receive the approval. Only allow an app that you started."
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if request.usesMetadataDocument {
                    Text("This app identifies itself with a web address, which iMCP didn't register.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if enabledServiceNames.isEmpty {
                    Text("No services are on in iMCP, so the app can't use any tools yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("The app can use: \(enabledServiceNames.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Access lasts until you revoke it in Settings, under Connected Apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Read only: no tools that change anything", isOn: $readOnly)

            HStack(spacing: 12) {
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                // "Allow" has no keyboard shortcut, so that Return doesn't approve access,
                // and it stays off for a moment after the window appears.
                Button("Allow") { onApprove(readOnly) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAllow)
            }
        }
        .task {
            guard (try? await Task.sleep(for: ConnectionApprovalView.allowDelay)) != nil else { return }
            canAllow = true
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}
