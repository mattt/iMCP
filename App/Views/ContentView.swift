import AppKit
import MacControlCenterUI
import MenuBarExtraAccess
import SwiftUI

struct ContentView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    @Binding var isMenuPresented: Bool

    private let aboutWindowController: AboutWindowController

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    private var serviceBindings: [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: serviceConfigs.map {
                ($0.id, $0.binding)
            })
    }

    init(
        serverManager: ServerController,
        isEnabled: Binding<Bool>,
        isMenuPresented: Binding<Bool>
    ) {
        self.serverController = serverManager
        self._isEnabled = isEnabled
        self._isMenuPresented = isMenuPresented
        self.aboutWindowController = AboutWindowController()
    }

    var body: some View {
        MacControlCenterMenu(isPresented: $isMenuPresented) {
            HStack {
                Text("Enable MCP Server")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .onChange(of: isEnabled, initial: true) {
                Task {
                    await serverController.setEnabled(isEnabled)
                }
            }

            if isEnabled {
                Group {
                    MenuSection("Services")

                    ForEach(serviceConfigs) { config in
                        ServiceToggleView(config: config)
                    }
                }
                .onChange(of: serviceConfigs.map { $0.binding.wrappedValue }, initial: true) {
                    Task {
                        await serverController.updateServiceBindings(serviceBindings)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.3), value: isEnabled)
            }

            Divider()

            MenuCommand("Configure Claude Desktop") {
                ClaudeDesktop.showConfigurationPanel()
            }

            MenuCommand("Copy server command to clipboard") {
                let command = Bundle.main.bundleURL
                    .appendingPathComponent("Contents/MacOS/imcp-server")
                    .path

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
            }

            Divider()

            MenuCommand("About iMCP") {
                aboutWindowController.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            MenuCommand("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
