import ServiceManagement
import SwiftUI

/// The Settings pane for one service:
/// whether the service is on, and which of its tools clients can use.
struct ServiceSettingsView: View {
    @ObservedObject var serverController: ServerController
    let config: ServiceConfig

    var body: some View {
        let isOn = config.binding.wrappedValue

        Form {
            Section {
                HStack(spacing: 12) {
                    ServiceIcon(config: config, isOn: isOn, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name)
                            .font(.headline)
                        Text(config.summary)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // A regular switch for the service and mini switches for its tools
                    // show which setting the others depend on.
                    Toggle(config.name, isOn: serviceBinding)
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                }
            }

            if config.service is HomeService {
                HomeHelperSection(isHomeOn: isOn)
            }

            Section {
                ForEach(config.service.tools, id: \.name) { tool in
                    Toggle(isOn: toolBinding(tool.name)) {
                        HStack(spacing: 6) {
                            if let title = tool.annotations.title {
                                Text(title)
                            } else {
                                // Without a title, show the name that clients call the tool by.
                                Text(tool.name)
                                    .monospaced()
                            }
                            if tool.annotations.readOnlyHint == true {
                                Text("Read-only")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(firstSentence(of: tool.description))
                    }
                    .controlSize(.mini)
                    .help(tool.description)
                    // While the service is off, its tools keep their own settings,
                    // but a disabled switch alone still looks on, so dim the whole row.
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : 0.5)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools")
                    if !isOn {
                        Text("Clients can't use these tools while \(config.name) is off.")
                            .font(.subheadline)
                            .fontWeight(.regular)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Clients can't see or call the tools that you turn off.")
            }
            .animation(.default, value: isOn)
        }
        .formStyle(.grouped)
        .navigationTitle(config.name)
    }

    // Delegate to ServerController so toggling activates the service (permission
    // prompt, revert on failure) and pushes updated bindings to connected clients.
    private var serviceBinding: Binding<Bool> {
        Binding(
            get: { config.binding.wrappedValue },
            set: { serverController.setService(config, enabled: $0) }
        )
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { serverController.isToolEnabled(name) },
            set: { serverController.setTool(name, enabled: $0) }
        )
    }

    /// The sentence that says what a tool does.
    /// The rest of a tool's description tells clients how to call it,
    /// so Settings shows it only in the tool's help tag.
    private func firstSentence(of description: String) -> String {
        var sentence = description
        description.enumerateSubstrings(in: description.startIndex..., options: .bySentences) { substring, _, _, stop in
            if let substring {
                sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            stop = true
        }
        return sentence
    }
}

/// A service's symbol on a circle,
/// in the service's color while the service is on and in gray while it's off,
/// as in the menu.
struct ServiceIcon: View {
    let config: ServiceConfig
    let isOn: Bool
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: config.iconName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(isOn ? config.color : .gray, in: Circle())
            .animation(.default, value: isOn)
            .accessibilityHidden(true)
    }
}

/// Whether iMCP Helper's launch agent is registered, which Home needs.
private struct HomeHelperSection: View {
    var isHomeOn: Bool

    @State private var state = HomeService.shared.state()
    @State private var isWorking = false
    @State private var isConfirmingUnregister = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            LabeledContent {
                switch state {
                case .notBundled:
                    EmptyView()
                case .notRegistered:
                    Button("Register") { register() }
                        .disabled(isWorking)
                case .needsApproval:
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                case .registered:
                    Button("Unregister…") { isConfirmingUnregister = true }
                        .disabled(isWorking)
                }
            } label: {
                Text("iMCP Helper")
                Text(description)
            }
        } footer: {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if state == .notBundled {
                Text("This build of iMCP doesn't include iMCP Helper, which Home needs to reach HomeKit.")
            }
        }
        .confirmationDialog("Unregister iMCP Helper?", isPresented: $isConfirmingUnregister) {
            Button("Unregister", role: .destructive) {
                Task {
                    isWorking = true
                    defer { isWorking = false }
                    do {
                        try await HomeService.shared.unregister()
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    state = HomeService.shared.state()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iMCP Helper stops, and Home tools stop working until you register it again or turn Home on.")
        }
        .task {
            state = HomeService.shared.state()
            errorMessage = await HomeService.shared.lastFailure
        }
    }

    private var description: String {
        switch state {
        case .notBundled: "Not included in this build"
        case .notRegistered: "Not registered"
        case .needsApproval: "Waiting for your approval in Login Items"
        case .registered: "Registered. macOS starts it when iMCP needs HomeKit."
        }
    }

    private func register() {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await HomeService.shared.register()
                errorMessage = nil
                if isHomeOn { try await HomeService.shared.activate() }
            } catch {
                errorMessage = error.localizedDescription
            }
            state = HomeService.shared.state()
        }
    }
}
