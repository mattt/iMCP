import AppKit
import SwiftUI

struct ServiceToggleView: View {
    let config: ServiceConfig
    @State private var isServiceActivated = false
    @State private var isHovering = false

    // MARK: Environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    // MARK: Private State
    private let buttonSize: CGFloat = 26
    private let imagePadding: CGFloat = 5

    var body: some View {
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
            HStack {
                Circle()
                    .fill(buttonBackgroundColor)
                    .overlay(
                        Image(systemName: config.iconName)
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(buttonForegroundColor)
                            .padding(imagePadding)
                    )
                    .frame(width: buttonSize, height: buttonSize)
                    .animation(.snappy, value: config.binding.wrappedValue || isEnabled)

                Text(config.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(isEnabled ? Color.primary : .primary.opacity(0.5))

                // Display-only: clicks pass through so the whole row stays one control.
                Toggle("", isOn: config.binding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .allowsHitTesting(false)
                    .opacity(isEnabled ? 1.0 : 0.4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(height: buttonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(ServiceToggleRowStyle())
        .disabled(!isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering && isEnabled ? Color.primary.opacity(0.07) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering && isEnabled
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                isHovering = false
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .pointerStyle(isEnabled ? .link : .default)
        .help("\(config.binding.wrappedValue ? "Disable" : "Enable") \(config.name)")
        .accessibilityLabel(config.name)
        .accessibilityValue(config.binding.wrappedValue ? "Enabled" : "Disabled")
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

// Press feedback for the whole row: a slight scale-down while the mouse is held.
private struct ServiceToggleRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
