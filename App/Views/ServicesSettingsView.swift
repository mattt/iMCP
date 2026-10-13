import SwiftUI

struct ServicesSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var homeHelperPath: String?
    @State private var homeHelperError: String?

    var body: some View {
        Form {
            ForEach(serverController.computedServiceConfigs) { config in
                Section {
                    if config.service is HomeService { homeHelperRow() }
                    ForEach(config.service.tools, id: \.name) { tool in
                        toolRow(tool)
                    }
                    .disabled(!config.binding.wrappedValue)
                } header: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(config.color)
                            .overlay(
                                Image(systemName: config.iconName)
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundColor(.white)
                                    .padding(4)
                            )
                            .frame(width: 20, height: 20)

                        Text(config.name)

                        Spacer()

                        Toggle(config.name, isOn: serviceBinding(config))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .id("\(config.id)-\(config.binding.wrappedValue)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func homeHelperRow() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Helper")
                Spacer()
                Text(homeHelperPath ?? "Not installed")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") {
                    do {
                        guard let url = try HomeService.shared.chooseHelper() else { return }
                        homeHelperPath = url.path
                        homeHelperError = nil
                        // Tool calls go to the running helper until Home reconnects.
                        Task {
                            do {
                                try await HomeService.shared.useChosenHelper()
                            } catch {
                                homeHelperError = error.localizedDescription
                            }
                        }
                    } catch {
                        homeHelperError = error.localizedDescription
                    }
                }
            }
            if let homeHelperError {
                Text(homeHelperError).font(.caption).foregroundStyle(.red)
            } else if homeHelperPath == nil {
                Text("Build it with Scripts/install-helper.sh from the iMCP repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { homeHelperPath = HomeService.shared.helperLocation()?.path }
    }

    @ViewBuilder
    private func toolRow(_ tool: Tool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.annotations.title ?? tool.name)

                    if tool.annotations.readOnlyHint == true {
                        Text("Read-only")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle(tool.annotations.title ?? tool.name, isOn: toolBinding(tool.name))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .id("\(tool.name)-\(serverController.isToolEnabled(tool.name))")
        }
    }

    // Delegate to ServerController so toggling activates the service (permission
    // prompt, revert on failure) and pushes updated bindings to connected clients.
    private func serviceBinding(_ config: ServiceConfig) -> Binding<Bool> {
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
}
