import SwiftUI

struct ServicesSettingsView: View {
    @ObservedObject var serverController: ServerController

    var body: some View {
        Form {
            ForEach(serverController.computedServiceConfigs) { config in
                Section {
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

    // Route writes through ServerController so views observing it refresh;
    // @AppStorage-backed bindings don't publish through ObservableObject alone.
    private func serviceBinding(_ config: ServiceConfig) -> Binding<Bool> {
        Binding(
            get: { config.binding.wrappedValue },
            set: { newValue in
                serverController.objectWillChange.send()
                config.binding.wrappedValue = newValue
            }
        )
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { serverController.isToolEnabled(name) },
            set: { serverController.setTool(name, enabled: $0) }
        )
    }
}
