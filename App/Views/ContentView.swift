import AppKit
import MacControlCenterUI
import MenuBarExtraAccess
import SwiftUI

struct ContentView: View {
    @ObservedObject var serverManager: ServerManager
    @Binding var isEnabled: Bool
    @Binding var isMenuPresented: Bool

    private let aboutWindowController: AboutWindowController
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("messagesEnabled") private var messagesEnabled = false
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("utilitiesEnabled") private var utilitiesEnabled = true
    @AppStorage("weatherEnabled") private var weatherEnabled = false

    init(
        serverManager: ServerManager, isEnabled: Binding<Bool>, isMenuPresented: Binding<Bool>
    ) {
        self.serverManager = serverManager
        self._isEnabled = isEnabled
        self._isMenuPresented = isMenuPresented
        self.aboutWindowController = AboutWindowController()
    }

    private var serviceConfigs: [ServiceConfig] {
        [
            ServiceConfig(
                name: "Calendar",
                iconName: "calendar",
                color: .red,
                service: CalendarService.shared,
                binding: $calendarEnabled
            ),
            ServiceConfig(
                name: "Contacts",
                iconName: "person.crop.square.filled.and.at.rectangle.fill",
                color: .brown,
                service: ContactsService.shared,
                binding: $contactsEnabled
            ),
            ServiceConfig(
                name: "Location",
                iconName: "location.fill",
                color: .blue,
                service: LocationService.shared,
                binding: $locationEnabled
            ),
            ServiceConfig(
                name: "Messages",
                iconName: "message.fill",
                color: .green,
                service: MessageService.shared,
                binding: $messagesEnabled
            ),
            ServiceConfig(
                name: "Reminders",
                iconName: "list.bullet",
                color: .orange,
                service: RemindersService.shared,
                binding: $remindersEnabled
            ),
            ServiceConfig(
                name: "Weather",
                iconName: "cloud.sun.fill",
                color: .cyan,
                service: WeatherService.shared,
                binding: $weatherEnabled
            ),
        ]
    }

    private var serviceBindings: [String: Binding<Bool>] {
        [
            "CalendarService": $calendarEnabled,
            "ContactsService": $contactsEnabled,
            "LocationService": $locationEnabled,
            "MessageService": $messagesEnabled,
            "RemindersService": $remindersEnabled,
            "UtilitiesService": $utilitiesEnabled,
            "WeatherService": $weatherEnabled
        ]
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
                    await serverManager.setEnabled(isEnabled)
                }
            }

            if isEnabled {
                Group {
                    MenuSection("Services")

                    ForEach(serviceConfigs, id: \.name) { config in
                        ServiceToggleView(config: config)
                    }
                }
                .onChange(of: [
                    calendarEnabled, contactsEnabled, locationEnabled, messagesEnabled,
                    remindersEnabled, utilitiesEnabled, weatherEnabled
                ]) {
                    Task {
                        await serverManager.updateServiceBindings(serviceBindings)
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
        .task {
            // Initial update of service bindings
            await serverManager.updateServiceBindings(serviceBindings)
        }
    }
}
