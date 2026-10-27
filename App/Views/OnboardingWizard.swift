import AppKit
import SwiftUI

/// The server command that STDIO clients start.
enum ServerCommand {
    static var path: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/imcp-server").path
    }

    static func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        _ = NSSound.play(.pop)
    }
}

/// An app that the wizard can connect, and how the system finds it.
///
/// Claude Desktop's bundle identifier is `com.anthropic.claudefordesktop`.
/// I verified it in the installed Claude app's Info.plist and in public sources.
/// The current ChatGPT app (version 26.1021 on this Mac) uses `com.openai.codex`,
/// and the earlier ChatGPT app used `com.openai.chat`.
/// I verified the first in the installed ChatGPT app's Info.plist and the second in public sources.
/// The wizard accepts either ChatGPT identifier.
enum WizardClient: String, CaseIterable, Identifiable {
    case claudeDesktop
    case chatGPT
    case other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .chatGPT: "ChatGPT Desktop"
        case .other: "Other"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .claudeDesktop: ["com.anthropic.claudefordesktop"]
        case .chatGPT: ["com.openai.codex", "com.openai.chat"]
        case .other: []
        }
    }

    /// The installed app, or nil. Every client except Other must be installed.
    var installedURL: URL? {
        bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    var isInstalled: Bool { self == .other || installedURL != nil }
}

/// The setup assistant: one step per screen, in its own window, separate from Settings.
///
/// It opens at first launch and from "Set Up iMCP…" in the menu.
/// `onFinish` reports whether the person chose Done (true) or Finish Later (false).
/// Progress comes from `ServerController`: `hasConnected` covers a connection from any client,
/// and the Location step reads the Location service's own state.
struct OnboardingWizardView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    let onFinish: (Bool) -> Void

    @State private var step = 0
    @State private var selectedClient: WizardClient
    @State private var locationPhase = LocationPhase.idle

    private enum LocationPhase: Equatable {
        case idle
        case working
        case denied
    }

    private static let stepTitles = ["Connect an app", "Turn on Location", "Try it", "What's possible"]

    init(serverController: ServerController, isEnabled: Binding<Bool>, onFinish: @escaping (Bool) -> Void) {
        self.serverController = serverController
        self._isEnabled = isEnabled
        self.onFinish = onFinish
        // Start on the first installed app, and on Other when neither app is present.
        let firstInstalled = WizardClient.allCases.first { $0 != .other && $0.isInstalled }
        _selectedClient = State(initialValue: firstInstalled ?? .other)
    }

    private var locationConfig: ServiceConfig? {
        serverController.computedServiceConfigs.first { $0.name == "Location" }
    }

    private var isLocationOn: Bool { locationConfig?.binding.wrappedValue == true }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set Up iMCP")
                    .font(.title2.weight(.semibold))
                StepIndicator(step: step, titles: Self.stepTitles)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                Group {
                    switch step {
                    case 0: connectStep
                    case 1: locationStep
                    case 2: tryItStep
                    default: whatsPossibleStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }

            Divider()

            HStack {
                Button("Finish Later") { onFinish(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == Self.stepTitles.count - 1 ? "Done" : "Continue") {
                    if step == Self.stepTitles.count - 1 {
                        onFinish(true)
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 580)
        .task {
            if !isEnabled { isEnabled = true }
        }
    }

    // MARK: - Step 1: Connect an app

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the app that you want to use with iMCP. You can connect another app later.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(WizardClient.allCases) { client in
                ClientChoiceRow(
                    client: client,
                    isSelected: selectedClient == client,
                    isInstalled: client.isInstalled
                ) {
                    selectedClient = client
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    switch selectedClient {
                    case .claudeDesktop:
                        Text("iMCP can add itself to Claude Desktop's configuration file for you.")
                        Button("Set Up Claude Desktop…") {
                            ClaudeDesktop.showConfigurationPanel()
                        }
                        Text("Then quit and reopen Claude Desktop so that it starts iMCP.")
                            .foregroundStyle(.secondary)
                    case .chatGPT:
                        Text(
                            "In ChatGPT, open Settings, then MCP servers. "
                                + "Add a server named iMCP, choose STDIO, and paste the server command as the command to launch. "
                                + "Leave the other fields empty, then save."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        Button("Copy Server Command") { ServerCommand.copy() }
                        Text("Then click Restart in ChatGPT's MCP servers settings.")
                            .foregroundStyle(.secondary)
                    case .other:
                        Text(
                            "In your MCP client, add a local server that uses the STDIO transport, "
                                + "and paste the server command as its command. "
                                + "For llama.cpp, put the command in its MCP configuration file instead."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        Button("Copy Server Command") { ServerCommand.copy() }
                        Text(ServerCommand.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("When the app connects, iMCP shows a Client Connection Request.")
                    .fontWeight(.medium)
                Text(
                    "Check the app name and the services that it can use, then click Allow. "
                        + "Select \"Always trust this client\" if you do not want to approve it each time."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if serverController.hasConnected {
                    Label("A client has connected to iMCP.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("No client has connected yet.", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 2: Location

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(9)
                    .frame(width: 44, height: 44)
                    .background(Color.blue, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Location").font(.headline)
                    Text("Lets an app answer questions about where you are, and turn addresses into coordinates.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(
                "Turn Location on here as an example. "
                    + "macOS then asks whether iMCP may use your location. Click Allow so that the test in the next step can work. "
                    + "Every service asks in the same way, and iMCP can use only what you allow."
            )
            .fixedSize(horizontal: false, vertical: true)

            if isLocationOn && locationPhase != .denied {
                Label("Location is on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Turn Location Off") {
                    if let locationConfig { serverController.setService(locationConfig, enabled: false) }
                }
            } else {
                Button(locationPhase == .working ? "Waiting for macOS…" : "Turn On Location") {
                    turnOnLocation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(locationPhase == .working)
            }

            if locationPhase == .denied {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Location is off.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fontWeight(.medium)
                        Text(
                            "macOS did not give iMCP your location. "
                                + "Open System Settings > Privacy & Security > Location Services, turn on iMCP, "
                                + "then come back here and try again."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if let paneURL = ServiceToggleView.privacyPaneURL(for: "Location") {
                                Button("Open Location Settings…") {
                                    NSWorkspace.shared.open(paneURL)
                                }
                            }
                            Button("Try Again") { turnOnLocation() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            Text("You can skip this step. The wizard works without Location, and you can turn it on later in the menu.")
                .foregroundStyle(.secondary)
        }
    }

    private func turnOnLocation() {
        guard let config = locationConfig else { return }
        locationPhase = .working
        serverController.setService(config, enabled: true)
        Task {
            // `setService` turns the binding on at once and turns it back off when activation fails.
            // Watch for the service to become active, or for the binding to fall back off.
            for _ in 0 ..< 150 {
                if await config.isActivated {
                    locationPhase = .idle
                    return
                }
                if !config.binding.wrappedValue {
                    locationPhase = .denied
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            locationPhase = .idle
        }
    }

    // MARK: - Step 3: Try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open \(selectedClient.name == "Other" ? "your app" : selectedClient.name) and send this message:")
                .foregroundStyle(.secondary)

            GroupBox {
                HStack(alignment: .top, spacing: 8) {
                    Text("“Use iMCP to tell me where I am. What city am I in, and what is the weather there?”")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Copy Prompt") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(
                            "Use iMCP to tell me where I am. What city am I in, and what is the weather there?",
                            forType: .string
                        )
                        _ = NSSound.play(.pop)
                    }
                    .controlSize(.small)
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What a good result looks like").fontWeight(.medium)
                Text(
                    "The app may ask iMCP to approve its connection first. "
                        + "After you click Allow, the app calls iMCP's location tool and answers with your city. "
                        + "It should not ask you to type your address."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if serverController.hasConnected {
                    Label("A client has connected, so the test can run now.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(
                        "No client has connected yet. Go back to step 1, set up your app, and restart it.",
                        systemImage: "circle.dashed"
                    )
                    .foregroundStyle(.secondary)
                }

                if !isLocationOn {
                    Label(
                        "Location is off. Go back to step 2 to turn it on, or the test cannot find where you are.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Step 4: What's possible

    private var whatsPossibleStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "One service gives an app one kind of fact. "
                    + "Several services together let it reason across your day, because it can combine those facts in one answer."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ExampleRow(
                    prompt: "“What do I have on tomorrow, and when should I leave?”",
                    detail:
                        "Calendar gives the events, Location and Maps give the travel time, and Weather gives the conditions."
                )
                ExampleRow(
                    prompt: "“Find Maya's number and draft a message about Friday.”",
                    detail: "Contacts finds the person, Calendar checks Friday, and Mail or Messages opens the draft."
                )
                ExampleRow(
                    prompt: "“Summarize what I missed this morning.”",
                    detail:
                        "Mail, Messages, Reminders, and Notes each hold part of the morning, and the app joins them."
                )
            }

            Text(
                "Turn on more services in the iMCP menu, or open Settings to choose which tools each service offers. "
                    + "Turn a service off there at any time, and the app loses that access at once."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                "Choose Done to finish. You can open this wizard again from Set Up iMCP… in the menu.",
                systemImage: "menubar.rectangle"
            )
            .foregroundStyle(.secondary)
        }
    }
}

/// One selectable app in step 1, disabled with a note when the app is missing.
private struct ClientChoiceRow: View {
    let client: WizardClient
    let isSelected: Bool
    let isInstalled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name)
                        .foregroundStyle(isInstalled ? .primary : .secondary)
                    if !isInstalled {
                        Text("Not installed on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if client == .other {
                        Text("Any MCP client that can start a local STDIO server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!isInstalled)
        .accessibilityLabel(client.name)
        .accessibilityValue(isInstalled ? (isSelected ? "Selected" : "Not selected") : "Not installed")
    }
}

private struct ExampleRow: View {
    let prompt: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(prompt).fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The dots and the "Step n of 4" label at the top of the wizard.
private struct StepIndicator: View {
    let step: Int
    let titles: [String]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: index == step ? 22 : 10, height: 6)
                        .accessibilityHidden(true)
                }
            }
            Text("Step \(step + 1) of \(titles.count): \(titles[step])")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shows the wizard window, and brings it to the front if it is already open.
///
/// The app has no Dock icon, so this follows the About window's controller pattern
/// rather than a SwiftUI `Window` scene, which the system may not present for an accessory app.
@MainActor
final class OnboardingWizardWindowController: NSWindowController {
    private var hostingView: NSHostingView<OnboardingWizardView>?

    convenience init() {
        self.init(window: nil)
    }

    func show(
        serverController: ServerController,
        isEnabled: Binding<Bool>,
        onComplete: @escaping () -> Void
    ) {
        let rootView = OnboardingWizardView(
            serverController: serverController,
            isEnabled: isEnabled,
            onFinish: { [weak self] completed in
                if completed { onComplete() }
                self?.close()
            }
        )

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            self.hostingView = hostingView

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Set Up iMCP"
            window.contentView = hostingView
            window.isReleasedWhenClosed = false
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
