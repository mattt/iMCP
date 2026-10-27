import SwiftUI
import AppKit

struct ServiceToggleView: View {
    let config: ServiceConfig
    @State private var isServiceActivated = false
    /// Why the last turn-on request failed. Its presence puts a warning icon on the row.
    @State private var activationError: String?
    @State private var isWarningExpanded = false

    // MARK: Environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    // MARK: Private State
    private let buttonSize: CGFloat = 26
    private let imagePadding: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: {
                    activationError = nil
                    isWarningExpanded = false
                    config.binding.wrappedValue.toggle()
                    if config.binding.wrappedValue && !isServiceActivated {
                        Task {
                            do {
                                if config.service is HomeService {
                                    if try await !HomeService.shared.activateAskingUser() {
                                        config.binding.wrappedValue = false
                                        activationError =
                                            "Home needs iMCP Helper. Build it with Scripts/install-helper.sh, "
                                            + "then turn Home on again"
                                    }
                                    return
                                }
                                try await config.service.activate()
                            } catch {
                                config.binding.wrappedValue = false
                                activationError = error.localizedDescription
                            }
                        }
                    }
                }) {
                    Circle()
                        .fill(buttonBackgroundColor)
                        .overlay(
                            Image(systemName: config.iconName)
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(buttonForegroundColor)
                                .padding(imagePadding)
                        )
                        .animation(.snappy, value: config.binding.wrappedValue || isEnabled)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!isEnabled)
                .frame(width: buttonSize, height: buttonSize)
                .accessibilityLabel(config.name)
                .accessibilityValue(config.binding.wrappedValue ? "Enabled" : "Disabled")
                .accessibilityAddTraits(.isButton)
                .help("\(config.name) tools: \(toolSummary)")

                Text(config.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(isEnabled ? Color.primary : .primary.opacity(0.5))

                if activationError != nil {
                    Button {
                        isWarningExpanded.toggle()
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(config.name) needs attention")
                    .accessibilityValue(isWarningExpanded ? "Details shown" : "Details hidden")
                    .help(isWarningExpanded ? "Hide details" : "Show details")
                }
            }
            .frame(height: buttonSize)

            if let activationError, isWarningExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(warningText(error: activationError))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let paneURL = Self.privacyPaneURL(for: config.name) {
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(paneURL)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, buttonSize + 8)
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .task {
            isServiceActivated = await config.isActivated
        }
    }

    /// The full sentence for the disclosure, with the error and the next step as separate sentences.
    private func warningText(error: String) -> String {
        let reason = error.hasSuffix(".") ? String(error.dropLast()) : error
        if Self.privacyPaneURL(for: config.name) != nil {
            return "\(config.name) is off. \(reason). "
                + "Open System Settings > Privacy & Security, turn on iMCP for \(config.name), "
                + "then click the \(config.name) icon again."
        }
        return "\(config.name) is off. \(reason). "
            + "Click the \(config.name) icon again to try again."
    }

    /// The Privacy & Security pane for a service, where the system has one.
    ///
    /// Folder-based services (Messages, Mail, Notes, and similar) have no pane:
    /// turning the service on again opens their folder picker instead.
    static func privacyPaneURL(for serviceName: String) -> URL? {
        let anchor: String?
        switch serviceName {
        case "Calendar": anchor = "Privacy_Calendars"
        case "Capture": anchor = "Privacy_Camera"
        case "Contacts": anchor = "Privacy_Contacts"
        case "Home": anchor = "Privacy_HomeKit"
        case "Location", "Maps": anchor = "Privacy_LocationServices"
        case "Music": anchor = "Privacy_Media"
        case "Reminders": anchor = "Privacy_Reminders"
        default: anchor = nil
        }
        guard let anchor else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private var buttonBackgroundColor: Color {
        if config.binding.wrappedValue {
            return config.color.opacity(isEnabled ? 1.0 : 0.4)
        } else {
            return Color(NSColor.controlColor)
                .opacity(isEnabled ? (colorScheme == .dark ? 0.8 : 0.2) : 0.1)
        }
    }

    private var buttonForegroundColor: Color {
        if config.binding.wrappedValue {
            return .white.opacity(isEnabled ? 1.0 : 0.6)
        } else {
            return .primary.opacity(isEnabled ? 0.7 : 0.4)
        }
    }

    private var toolSummary: String {
        config.service.tools
            .map { $0.annotations.title ?? $0.name }
            .joined(separator: ", ")
    }
}
