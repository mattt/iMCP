#if DEBUG
    import AppKit
    import Sparkle
    import SwiftUI

    /// Renders each Settings tab to a PNG at several window sizes, in light and dark, then exits.
    ///
    /// Run the app with `--snapshot-settings=<existing directory>`. Add `--settings-tab=<tab>` for one tab
    /// (a `SettingsPane` raw value, or `service-<id>` for one service's options) and `--settings-size=<width>x<height>`
    /// for one size. Without them it renders every tab at the default, minimum and a large size.
    /// It draws the real views in this process, so it needs neither Screen Recording nor Accessibility permission.
    @MainActor
    enum SettingsSnapshot {
        static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--snapshot-settings=") }
        }

        static func runIfRequested(serverController: ServerController, updater: SPUUpdater) -> Bool {
            let arguments = ProcessInfo.processInfo.arguments
            guard let argument = arguments.first(where: { $0.hasPrefix("--snapshot-settings=") }) else { return false }
            let directory = URL(fileURLWithPath: String(argument.dropFirst("--snapshot-settings=".count)))

            var tabs: [String] =
                SettingsPane.tabs.map(\.rawValue)
                + [
                    "remoteAccess-tailscale", "remoteAccess-funnel", "remoteAccess-cloudflare", "sidebar",
                    "service-NotesService", "service-CalendarService",
                ]
            if let tab = arguments.first(where: { $0.hasPrefix("--settings-tab=") }) {
                tabs = String(tab.dropFirst("--settings-tab=".count)).split(separator: ",").map(String.init)
            }
            var sizes: [(String, NSSize)] = [
                ("default", SettingsWindowMetrics.defaultSize),
                ("min", SettingsWindowMetrics.minimumSize),
                ("large", NSSize(width: 1100, height: 800)),
            ]
            if arguments.contains("--settings-default-and-min") {
                sizes = Array(sizes.prefix(2))
            }
            if let size = arguments.first(where: { $0.hasPrefix("--settings-size=") }) {
                let parts = String(size.dropFirst("--settings-size=".count)).split(separator: "x").compactMap {
                    Double($0)
                }
                if parts.count == 2 { sizes = [("custom", NSSize(width: parts[0], height: parts[1]))] }
            }

            Task { @MainActor in
                // Let the services and the remote access state settle.
                try? await Task.sleep(for: .seconds(2))
                for isDark in [false, true] {
                    for (sizeName, size) in sizes {
                        for tab in tabs {
                            await render(
                                tab: tab,
                                size: size,
                                sizeName: sizeName,
                                isDark: isDark,
                                serverController: serverController,
                                updater: updater,
                                directory: directory
                            )
                        }
                    }
                }
                exit(0)
            }
            return true
        }

        private static func layerImage(of view: NSView) -> NSBitmapImageRep? {
            let scale = 2
            guard let layer = view.layer,
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(view.bounds.width) * scale,
                    pixelsHigh: Int(view.bounds.height) * scale,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ),
                let context = NSGraphicsContext(bitmapImageRep: rep)
            else { return nil }
            let cg = context.cgContext
            cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            // A flipped view's layer draws with the origin at the top left. The window's frame view does not.
            if view.isFlipped {
                cg.translateBy(x: 0, y: view.bounds.height)
                cg.scaleBy(x: 1, y: -1)
            }
            layer.render(in: cg)
            return rep
        }

        private static func render(
            tab: String,
            size: NSSize,
            sizeName: String,
            isDark: Bool,
            serverController: ServerController,
            updater: SPUUpdater,
            directory: URL
        ) async {
            let window: NSWindow
            if tab == "sidebar" {
                // The sidebar list on its own, for comparison with the full window.
                let root = AnyView(
                    List(selection: .constant(SettingsPane.clients)) {
                        ForEach(SettingsPane.tabs, id: \.self) { tab in
                            Label(tab.title, systemImage: tab.symbol).tag(tab)
                        }
                        Section("Services") {
                            ForEach(serverController.computedServiceConfigs) { config in
                                Label {
                                    Text(config.name)
                                } icon: {
                                    ServiceIcon(config: config, isOn: config.binding.wrappedValue)
                                }
                                .tag(SettingsPane.service(config.id))
                            }
                        }
                    }
                    .listStyle(.sidebar)
                )
                window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = NSHostingView(rootView: root)
            } else {
                // The real Settings window, as the app builds it.
                var pane = tab.hasPrefix("service-") ? String(tab.dropFirst("service-".count)) : tab
                // "remoteAccess-cloudflare" shows that way's checklist.
                UserDefaults.standard.removeObject(forKey: "debugRemoteSelection")
                UserDefaults.standard.removeObject(forKey: "debugChecklistExpanded")
                if pane.hasPrefix("remoteAccess-cloudflare") {
                    // "remoteAccess-cloudflare-connected", "-signedout" or "-missingdomain".
                    UserDefaults.standard.set("cloudflare", forKey: "debugRemoteSelection")
                    let scenario = pane.split(separator: "-").last.map(String.init) ?? "signedout"
                    serverController.cloudflareTunnel.debugShow(scenario)
                    pane = "remoteAccess"
                } else if pane.hasPrefix("remoteAccess-tailscale") {
                    // "remoteAccess-tailscale-connected" or "-signedout".
                    UserDefaults.standard.set("tailscale", forKey: "debugRemoteSelection")
                    serverController.debugShowTailscale(pane.hasSuffix("connected") ? "connected" : "signedout")
                    pane = "remoteAccess"
                } else if pane.hasPrefix("remoteAccess-") {
                    UserDefaults.standard.set(
                        String(pane.dropFirst("remoteAccess-".count)),
                        forKey: "debugRemoteSelection"
                    )
                    pane = "remoteAccess"
                }
                UserDefaults.standard.set(pane, forKey: "settingsPane")
                guard let made = SettingsWindowController.shared.makeWindow(restoresFrame: false) else { return }
                window = made
            }
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            window.setContentSize(size)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            SettingsWindowController.clearInitialFocus(in: window)
            try? await Task.sleep(for: .seconds(2.5))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // The frame view includes the title bar and toolbar. The content view alone leaves them out.
            if let view = window.contentView?.superview ?? window.contentView {
                let name = "\(tab)-\(sizeName)-\(isDark ? "dark" : "light")"
                if let rep = layerImage(of: view) {
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: directory.appending(path: name + ".png"))
                    if tab != "sidebar" {
                        let result = bandCheck(rep, window: window)
                        let line =
                            "\(name): first content \(result.offset) pt below the toolbar, \(result.offset < 60 ? "PASS" : "FAIL")\n"
                        if let handle = try? FileHandle(forWritingTo: directory.appending(path: "band-check.txt")) {
                            handle.seekToEndOfFile()
                            handle.write(Data(line.utf8))
                            try? handle.close()
                        }
                    }
                }
            }
            window.orderOut(nil)
        }

        /// How far below the toolbar the first content starts in the detail pane, in points.
        /// A tall blank band means the layout reserved space it does not use.
        private static func bandCheck(_ rep: NSBitmapImageRep, window: NSWindow) -> (offset: Int, found: Bool) {
            let scale = 2
            let toolbarBottom = Int(window.frame.height - window.contentLayoutRect.height)
            let width = rep.pixelsWide
            let columns = stride(from: Int(Double(width) * 0.5), to: Int(Double(width) * 0.85), by: 6).map { $0 }
            let gutter = width - 6
            for y in (toolbarBottom + 1) * scale ..< rep.pixelsHigh {
                guard let reference = rep.colorAt(x: gutter, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                for x in columns {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let difference =
                        abs(color.redComponent - reference.redComponent)
                        + abs(color.greenComponent - reference.greenComponent)
                        + abs(color.blueComponent - reference.blueComponent)
                    if difference > 0.03 { return (y / scale - toolbarBottom, true) }
                }
            }
            return (9999, false)
        }
    }
#endif
