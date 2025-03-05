import AppKit
import SwiftUI

class AboutWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "About iMCP"
        window.contentView = NSHostingView(rootView: AboutView())
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 32) {
                // Left column - Icon
                Image(.menuIcon)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .padding()

                // Right column - App info and links
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iMCP")
                            .font(.system(size: 24, weight: .medium))

                        if let shortVersionString = Bundle.main.shortVersionString {
                            Text("Version \(shortVersionString)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 20)

                    Button("Report an Issue...") {
                        NSWorkspace.shared.open(
                            URL(string: "https://github.com/loopwork-ai/iMCP/issues/new")!)
                    }
                }
            }

            if let copyright = Bundle.main.copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(width: 400)
        .padding()
    }
}
