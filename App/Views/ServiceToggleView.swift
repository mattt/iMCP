import MacControlCenterUI
import SwiftUI

struct ServiceConfig {
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let binding: Binding<Bool>

    var isActivated: Bool {
        get async {
            await service.isActivated
        }
    }
}

struct ServiceToggleView: View {
    let config: ServiceConfig
    @State private var isServiceActivated = false

    var body: some View {
        MenuCircleToggle(
            config.name,
            isOn: config.binding,
            style: .init(
                image: Image(systemName: config.iconName),
                color: config.color
            ),
            onClick: { enabled in
                if enabled && !isServiceActivated {
                    Task {
                        do {
                            try await config.service.activate()
                        } catch {
                            config.binding.wrappedValue = false
                        }
                    }
                }
            }
        )
        .task {
            isServiceActivated = await config.isActivated
        }
    }
}
