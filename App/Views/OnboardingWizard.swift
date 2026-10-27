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

    /// The installed app's icon, or nil when the app is missing.
    var appIcon: NSImage? {
        installedURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Whether a name that a connected client reported belongs to this app.
    ///
    /// Clients report their own names: ChatGPT reports a Codex name,
    /// so this accepts either spelling for it.
    func matches(reportedName name: String) -> Bool {
        let name = name.lowercased()
        switch self {
        case .claudeDesktop: return name.contains("claude")
        case .chatGPT: return name.contains("chatgpt") || name.contains("codex")
        case .other: return false
        }
    }
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
    @State private var isLocationAuthorized = false

    private enum LocationPhase: Equatable {
        case idle
        case working
        case denied
    }

    private static let stepTitles = ["Welcome", "Connect an app", "Turn on Location", "Try it", "What's possible"]

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
                    case 0: WelcomeView()
                    case 1: connectStep
                    case 2: locationStep
                    case 3: tryItStep
                    default: whatsPossibleStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
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
                .disabled(!canContinue)
                .help(canContinue ? "" : (continueHint ?? ""))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 580)
        .task {
            if !isEnabled { isEnabled = true }
            await refreshLocationAuthorization()
        }
        .task(id: step) {
            await refreshLocationAuthorization()
        }
    }

    /// Whether Continue may leave this screen. Each step states its own requirement.
    private var canContinue: Bool {
        switch step {
        case 1: serverController.hasConnected
        case 2: isLocationAuthorized
        case 3: serverController.hasConnected && isLocationAuthorized
        default: true
        }
    }

    private var continueHint: String? {
        guard !canContinue else { return nil }
        switch step {
        case 1: return "Connect an app to continue."
        case 2: return "Turn on Location to continue."
        case 3: return "Connect an app and turn on Location to continue."
        default: return nil
        }
    }

    private func refreshLocationAuthorization() async {
        guard let locationConfig else { return }
        isLocationAuthorized = await locationConfig.isActivated
    }

    /// Whether the wizard has seen a connection from `client`.
    private func isConnected(_ client: WizardClient) -> Bool {
        let names = serverController.connectedClientNames
        switch client {
        case .claudeDesktop, .chatGPT:
            return names.contains { client.matches(reportedName: $0) }
        case .other:
            return names.contains { name in
                !WizardClient.claudeDesktop.matches(reportedName: name)
                    && !WizardClient.chatGPT.matches(reportedName: name)
            }
        }
    }

    // MARK: - Connect an app

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the app that you want to use with iMCP. You can connect another app later.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                ClientCard(
                    client: .claudeDesktop,
                    isConnected: isConnected(.claudeDesktop)
                ) {
                    selectedClient = .claudeDesktop
                    ClaudeDesktop.showConfigurationPanel()
                }
                ClientCard(
                    client: .chatGPT,
                    isConnected: isConnected(.chatGPT)
                ) {
                    selectedClient = .chatGPT
                    ChatGPT.showConfigurationPanel()
                }
            }

            Text(
                "Quit and reopen the app after setup so that it starts iMCP."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Other").fontWeight(.medium)
                        Spacer()
                        if isConnected(.other) {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    Text(
                        "Add a local STDIO server in your client, and paste the server command as its command."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Copy Server Command") {
                        selectedClient = .other
                        ServerCommand.copy()
                    }
                    Text(ServerCommand.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

    // MARK: - Location

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
                    isLocationAuthorized = false
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
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            Text("You can choose Finish Later to leave this step for now, and turn Location on later in the menu.")
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
                    isLocationAuthorized = true
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

    // MARK: - Try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(
                    "This is what the test looks like in \(selectedClient.name == "Other" ? "your app" : selectedClient.name):"
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Prompt") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(Self.samplePrompt, forType: .string)
                    _ = NSSound.play(.pop)
                }
                .controlSize(.small)
            }

            FakeConversation(lookupEnabled: isLocationAuthorized)
        }
    }

    static let samplePrompt = "Where am I right now, and what's the weather there?"

    // MARK: - What's possible

    private var whatsPossibleStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "One service gives an app one kind of fact. "
                    + "Several services together let it reason across your day, because it can combine those facts in one answer."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ExampleRow(
                    prompt: "What’s on my calendar tomorrow, and when do I need to leave?",
                    detail:
                        "Calendar gives the events, Location and Maps give the travel time, and Weather gives the conditions."
                )
                ExampleRow(
                    prompt: "Find Maya's number and open an email draft about Friday.",
                    detail:
                        "Contacts finds the person, Calendar checks Friday, and Mail opens the draft for you to send."
                )
                ExampleRow(
                    prompt: "Summarize what I missed this morning.",
                    detail:
                        "Mail, Messages, Reminders, and Notes each hold part of the morning, and the app joins them."
                )
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            Text(
                "Turn on more services in the iMCP menu, or open Settings to choose which tools each service offers. "
                    + "Turn a service off there at any time, and the app loses that access at once."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        }
    }
}

/// The welcome screen's hero, kept in one small view so that it is easy to swap later.
///
/// Today it shows the README hero for the current appearance,
/// from the HeroLight and HeroDark assets that `Scripts/generate-hero.py` made.
/// A future animated version only has to replace this view.
private struct WelcomeHeroView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(colorScheme == .dark ? "HeroDark" : "HeroLight")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("iMCP, with its service icons around the name")
    }
}

/// The first screen: what iMCP is, before any setup choice.
private struct WelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WelcomeHeroView()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Welcome to iMCP")
                .font(.title.weight(.semibold))

            Text(
                "iMCP connects your Mac's data to an AI app. "
                    + "The app can then use the services that you turn on, such as Calendar, Contacts, and Location, "
                    + "to answer questions with your own information."
            )
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "This setup connects an app, turns on one service as an example, and tests the result. "
                    + "iMCP does not collect or store your data, and you can turn every service off again at any time."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        }
    }
}

/// One app on the connect screen, with its icon, its connect button, or its connected checkmark.
private struct ClientCard: View {
    let client: WizardClient
    let isConnected: Bool
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let icon = client.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
            }

            Text(client.name)
                .fontWeight(.medium)
                .foregroundStyle(client.isInstalled ? .primary : .secondary)

            // A fixed-height slot, filled or empty, so both cards line up in every state.
            Group {
                if !client.isInstalled {
                    Text("Not installed on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(height: 28)

            Spacer(minLength: 0)

            // The connected checkmark and the connect button share this bottom slot.
            Group {
                if isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                } else {
                    Button(client == .claudeDesktop ? "Connect Claude Desktop…" : "Connect ChatGPT…") {
                        onConnect()
                    }
                    .disabled(!client.isInstalled)
                }
            }
            .frame(height: 24)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        // One height for every state, so the two cards always match.
        .frame(height: 190)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(client.name)
        .accessibilityValue(
            isConnected ? "Connected" : (client.isInstalled ? "Not connected" : "Not installed")
        )
    }
}

/// One combined example: the prompt as a user bubble, as in Try it, and what answers it.
private struct ExampleRow: View {
    let prompt: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer(minLength: 80)
                Text(prompt)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The dots and the "Step n of 5" label at the top of the wizard.
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

/// What the fake reply says, from a real lookup or from the Portland fallback.
private struct SampleResult {
    let place: String
    let city: String
    let weather: String

    static let portland = SampleResult(place: "Portland, Oregon", city: "Portland", weather: "54°F and cloudy")
}

/// A short fake chat that shows the test, with iMCP's tool use visible in the reply.
///
/// The parts appear in sequence: the user message, each tool call working, each result, then the answer.
/// The whole sequence takes about two seconds, it never blocks Continue,
/// and with Reduce Motion on, every part is visible at once with its result.
///
/// When Location is authorized, the place and weather come from iMCP's own
/// Location and Weather services, with a four-second limit.
/// The wizard only shows the result and stores nothing.
/// Any failure, or a slow answer, falls back to the Portland text.
private struct FakeConversation: View {
    let lookupEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Stages 1 to 6: user message, first tool working, its result, second tool working, its result, answer.
    @State private var shownParts = 0
    @State private var sample = SampleResult.portland

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shownParts >= 1 {
                HStack {
                    Spacer(minLength: 60)
                    Text(OnboardingWizardView.samplePrompt)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 8) {
                if shownParts >= 2 {
                    ToolUseRow(
                        tool: "location_current",
                        result: shownParts >= 3 ? "Current location: \(sample.place)" : nil
                    )
                    .transition(.opacity)
                }
                if shownParts >= 4 {
                    ToolUseRow(
                        tool: "weather_current",
                        result: shownParts >= 5 ? "Weather there: \(sample.weather)" : nil
                    )
                    .transition(.opacity)
                }
                if shownParts >= 6 {
                    Text(
                        "You are in \(sample.city). It is \(sample.weather) there right now, "
                            + "so a light jacket should be enough if you go out."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(
                "Your app shows its own tool names. What matters is that it answers from your Mac, without asking for your address."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeIn(duration: 0.25), value: shownParts)
        .task {
            if reduceMotion {
                if lookupEnabled { sample = await Self.lookup() }
                shownParts = 6
                return
            }
            shownParts = 1
            try? await Task.sleep(for: .milliseconds(300))
            shownParts = 2
            if lookupEnabled { sample = await Self.lookup() }
            shownParts = 3
            try? await Task.sleep(for: .milliseconds(300))
            shownParts = 4
            try? await Task.sleep(for: .milliseconds(400))
            shownParts = 5
            try? await Task.sleep(for: .milliseconds(300))
            shownParts = 6
        }
    }

    /// The current place and weather from iMCP's services, or Portland after four seconds or on any error.
    private static func lookup() async -> SampleResult {
        await withTaskGroup(of: SampleResult?.self) { group in
            group.addTask {
                do {
                    let place = try await LocationService.shared.currentPlace()
                    let conditions = try await WeatherService.shared.currentConditions(at: place.coordinate)
                    let temperature = conditions.temperature.formatted(
                        .measurement(width: .abbreviated, usage: .weather)
                    )
                    let condition = conditions.condition
                    let lowered = condition.prefix(1).lowercased() + condition.dropFirst()
                    return SampleResult(
                        place: place.displayName,
                        city: place.city,
                        weather: "\(temperature) and \(lowered)"
                    )
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return .portland
        }
    }
}

/// One visible tool call in the fake reply, working first and then showing its result.
private struct ToolUseRow: View {
    let tool: String
    /// The result text, or nil while the call is still working.
    let result: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(tool).font(.caption.monospaced()).fontWeight(.medium)
            if let result {
                Text(result).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.map { "Tool \(tool): \($0)" } ?? "Tool \(tool), working")
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
