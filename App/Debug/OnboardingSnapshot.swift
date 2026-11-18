#if DEBUG
    import AppKit
    import Sparkle
    import SwiftUI

    /// Renders each screen of the Setup Assistant to a PNG, then exits.
    ///
    /// Run the app with `--snapshot-onboarding=<existing directory>`. Add `--snapshot-dark` for dark mode
    /// and `--snapshot-large-text` for the largest accessibility text size.
    /// It draws the real windows in this process, so it needs neither
    /// Screen Recording nor Accessibility permission.
    @MainActor
    enum OnboardingSnapshot {
        static func runIfRequested(
            serverController: ServerController,
            isEnabled: Binding<Bool>,
            updater: SPUUpdater
        ) -> Bool {
            let prefix = "--snapshot-onboarding="
            let arguments = ProcessInfo.processInfo.arguments
            guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return false }
            let directory = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)))
            let isDark = arguments.contains("--snapshot-dark")
            let isLarge = arguments.contains("--snapshot-large-text")
            let name = (isDark ? "dark" : "light") + (isLarge ? "-large" : "")
            let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

            Task { @MainActor in
                for (index, step) in OnboardingStep.allCases.enumerated() {
                    let model = OnboardingModel(
                        mode: .firstRun,
                        serverController: serverController,
                        isEnabled: isEnabled
                    )
                    let controller = OnboardingWindowController()
                    controller.show(
                        model,
                        initialStep: step,
                        extra: { view in
                            isLarge ? AnyView(view.environment(\.dynamicTypeSize, .accessibility5)) : view
                        }
                    )
                    guard let window = controller.window else { continue }
                    window.appearance = appearance
                    // A clear window background does not draw into a snapshot.
                    window.backgroundColor = .windowBackgroundColor
                    try? await Task.sleep(for: .seconds(1.5))
                    controller.fit(animate: false)
                    try? await Task.sleep(for: .seconds(0.5))
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    if let content = window.contentView {
                        write(content, to: directory.appending(path: "\(index + 1)-\(step.rawValue)-\(name).png"))
                    }
                    // A second route, for comparison: SwiftUI's own renderer.
                    let renderer = ImageRenderer(
                        content: OnboardingView(model: model)
                            .environment(\.colorScheme, isDark ? .dark : .light)
                            .environment(\.dynamicTypeSize, isLarge ? .accessibility5 : .large)
                            .frame(width: OnboardingView.width)
                            .background(Color(nsColor: .windowBackgroundColor))
                    )
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                    {
                        try? png.write(
                            to: directory.appending(path: "\(index + 1)-\(step.rawValue)-\(name)-render.png")
                        )
                    }
                    window.orderOut(nil)
                }
                exit(0)
            }
            return true
        }

        private static func write(_ view: NSView, to url: URL) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
