import SwiftUI
import AppKit

struct ServiceToggleView: View {
    let config: ServiceConfig
    @State private var isServiceActivated = false
    
    // MARK: Environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    
    // MARK: Private State
    private let buttonSize: CGFloat = 26
    private let imagePadding: CGFloat = 5

    var body: some View {
        HStack {
            Button(action: {
                config.binding.wrappedValue.toggle()
                if config.binding.wrappedValue && !isServiceActivated {
                    Task {
                        do {
                            try await config.service.activate()
                        } catch {
                            config.binding.wrappedValue = false
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
            
            Text(config.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(isEnabled ? Color.primary : .primary.opacity(0.5))
        }
        .frame(height: buttonSize)
        .padding(.horizontal, 14)
        .task {
            isServiceActivated = await config.isActivated
        }
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
}
