import AppKit
import SwiftUI

// Small pieces that every Settings tab shares, so the tabs look alike:
// a leading icon, a short title with one line beneath, and a status badge.

/// A symbol in a small tinted rounded square, as in System Settings.
struct SettingsIcon: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An AI app's logo in Apple's app icon shape, or its symbol when it has no artwork.
struct ClientLogo: View {
    let client: KnownClient
    var size: CGFloat = 32

    var body: some View {
        if let asset = client.logoAsset {
            // The App Store artwork is a full square. Apple's app icon shape has a corner
            // radius of 22.37 percent of its width, with continuous corners.
            Image(asset)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
                .accessibilityHidden(true)
        } else {
            SettingsIcon(symbol: client.symbol, color: .gray, size: size)
        }
    }
}

/// The logo of the client that a name belongs to, or `fallback` for any other client.
struct ClientIdentityIcon<Fallback: View>: View {
    let name: String
    var size: CGFloat = 32
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        if let client = KnownClient.match(name: name) {
            ClientLogo(client: client, size: size)
        } else {
            fallback()
        }
    }
}

/// A short status in a capsule.
struct StatusBadge: View {
    enum Kind {
        case good, attention, neutral, bad

        var color: Color {
            switch self {
            case .good: .green
            case .attention: .orange
            case .neutral: .secondary
            case .bad: .red
            }
        }
    }

    let text: String
    var kind: Kind = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(kind.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(kind.color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// A row that opens to show more beneath it. The arrow sits at the trailing edge, so the row's icon lines up
/// with every other row; a `DisclosureGroup` puts its arrow at the leading edge and pushes the icon right.
struct ExpandableRow<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
            }
            if isExpanded {
                content()
            }
        }
    }
}

/// The label of a row: an icon, a title, and at most one short line beneath.
struct RowLabel<Icon: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 10) {
            icon()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // An address or a path keeps both ends. A sentence keeps its start.
                        .truncationMode(subtitle.contains("/") ? .middle : .tail)
                }
            }
        }
    }
}

/// A single centered symbol and one line, for a list with nothing in it.
struct EmptyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Copies text and plays the system's copy sound.
func copyToSettingsPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    _ = NSSound.play(.pop)
}
