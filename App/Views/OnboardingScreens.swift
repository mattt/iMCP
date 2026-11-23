// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

// Adapted from Ping Warden's onboarding (OnboardingView.swift screens).

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Copy

enum OnboardingCopy {
    struct Benefit {
        let symbol: String
        let title: String
        let detail: String
    }

    static let welcomeTitle = "Let your AI apps use your Mac"
    static let welcomeLine = "iMCP gives Claude and other AI apps access to the parts of your Mac that you choose."
    static let welcomeBenefits = [
        Benefit(
            symbol: "lock.shield",
            title: "Your data stays on this Mac",
            detail: "iMCP runs here and shares only what an app you approve asks for."
        ),
        Benefit(
            symbol: "switch.2",
            title: "You choose each service",
            detail: "You pick the services AI apps can use, and macOS asks permission as each one turns on."
        ),
        Benefit(
            symbol: "app.connected.to.app.below.fill",
            title: "Works with Claude and other apps",
            detail: "Any app that supports MCP can connect, on this Mac or from the cloud."
        ),
    ]
}

// MARK: - Welcome

/// The Welcome: icon, title, one line, three benefit rows, then the setup button and Not Now.
struct WelcomeScreen: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: OnboardingSpacing.large) {
            welcomeContent
                .padding(.horizontal, OnboardingSpacing.gutter)
                .padding(.top, OnboardingSpacing.medium)
                .frame(maxWidth: .infinity)
            actionArea
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: OnboardingSpacing.large) {
            VStack(spacing: 12) {
                LargeAppIcon()
                Text(OnboardingCopy.welcomeTitle)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingCopy.welcomeLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 20) {
                ForEach(OnboardingCopy.welcomeBenefits, id: \.title) { benefit in
                    WelcomeBenefitRow(benefit: benefit)
                }
            }
            .frame(maxWidth: 400)
        }
    }

    private var actionArea: some View {
        VStack(spacing: 14) {
            Text("macOS asks for permission when a service turns on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            OnboardingGlassGroup(spacing: 12) {
                Button {
                    model.continueTapped()
                } label: {
                    Text("Set Up iMCP")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .onboardingPrimary()
                .accessibilityIdentifier("onboarding.continue")
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 240)

            Button("Not Now") { model.closeTapped() }
                .buttonStyle(.link)
                .font(.callout)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("onboarding.notNow")
        }
        .padding(.horizontal, OnboardingSpacing.gutter)
        .padding(.top, OnboardingSpacing.small)
        .padding(.bottom, OnboardingSpacing.large)
    }
}

// MARK: - Services

struct ServicesScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var serverController: ServerController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let configs = serverController.computedServiceConfigs
        let half = (configs.count + 1) / 2

        VStack(spacing: OnboardingSpacing.large) {
            ScreenTitle(
                title: "Choose what AI apps can reach",
                subtitle: "Turn on the services you want AI apps to use."
            )

            OnboardingGlassGroup(spacing: 12) {
                Button {
                    model.turnOnRecommended()
                } label: {
                    Text(model.recommendedAreOn ? "Recommended Services Are On" : "Turn On Recommended")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .onboardingPrimary(isDefault: false)
                .disabled(model.recommendedAreOn)
                .accessibilityIdentifier("onboarding.turnOnRecommended")
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 240)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    column(configs)
                } else {
                    HStack(alignment: .top, spacing: OnboardingSpacing.large) {
                        column(Array(configs[..<half]))
                        column(Array(configs[half...]))
                    }
                }
            }
            .padding(.horizontal, OnboardingSpacing.medium)
            .frame(maxWidth: .infinity)

            Caption("macOS asks for permission when each service turns on. Home stays off until you turn it on.")
        }
    }

    private func column(_ configs: [ServiceConfig]) -> some View {
        VStack(spacing: 10) {
            ForEach(configs) { config in
                HStack(spacing: 8) {
                    ServiceIcon(config: config, isOn: config.binding.wrappedValue, size: 22)
                    Text(config.name)
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Toggle(
                        config.name,
                        isOn: Binding(
                            get: { config.binding.wrappedValue },
                            set: { model.setService(config, enabled: $0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("onboarding.service.\(config.id)")
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Connect apps

struct ConnectAppsScreen: View {
    @ObservedObject var model: OnboardingModel

    private static let logoSize: CGFloat = 32

    /// The agents that connect over a public address, with how each adds a connector.
    private static let cloudAgents: [(id: String, name: String, logo: String, steps: (String) -> String)] = [
        (
            "claudeWeb", "Claude Web", "ConnectorClaude",
            { _ in "At claude.ai, open Settings, then Connectors, add a custom connector and paste the URL." }
        ),
        (
            "claudeDuet", "Claude Duet", "ConnectorClaudeDuet",
            { _ in "Add a custom MCP connector, paste the URL, then approve once in iMCP." }
        ),
        (
            "muse", "Muse", "ConnectorMuse",
            { _ in "Add an MCP server with the URL. It signs in with OAuth 2.1." }
        ),
        (
            "gemini", "Gemini", "ConnectorGemini",
            { _ in "Add a custom MCP connector, paste the URL, then approve once in iMCP." }
        ),
    ]

    var body: some View {
        // Read again after a setup panel closes.
        let _ = model.appsRevision
        let publicURL = model.serverController.activePublicURLs.first?.url

        VStack(spacing: OnboardingSpacing.large) {
            ScreenTitle(
                title: "Connect your AI agent",
                subtitle:
                    "Add iMCP to Claude on this Mac, or copy your connector URL for Claude Web, Claude Duet, Muse and Gemini."
            )

            VStack(spacing: 0) {
                appRow(
                    logo: "ConnectorClaude",
                    name: "Claude Desktop",
                    detail: nil,
                    isSetUp: ClaudeDesktop.isConfigured,
                    id: "claudeDesktop",
                    buttonTitle: ClaudeDesktop.isConfigured ? "Set Up Again…" : "Set Up…",
                    action: model.setUpClaudeDesktop
                )
                Divider().padding(.horizontal, OnboardingSpacing.medium)
                appRow(
                    logo: "ConnectorClaudeCode",
                    name: "Claude Code",
                    detail: nil,
                    isSetUp: ClaudeCode.isConfigured,
                    id: "claudeCode",
                    buttonTitle: ClaudeCode.isConfigured ? "Set Up Again…" : "Set Up…",
                    action: model.setUpClaudeCode
                )
                ForEach(Self.cloudAgents, id: \.id) { agent in
                    Divider().padding(.horizontal, OnboardingSpacing.medium)
                    appRow(
                        logo: agent.logo,
                        name: agent.name,
                        detail: publicURL.map(agent.steps)
                            ?? "Needs a public address. Choose one in the previous step.",
                        isSetUp: nil,
                        id: agent.id,
                        buttonTitle: "Copy URL",
                        action: { if let publicURL { copyForOnboarding(publicURL) } },
                        isEnabled: publicURL != nil
                    )
                }
            }
            .frame(maxWidth: OnboardingSpacing.column)

            Caption("The first time an app connects, iMCP asks once: Allow Once or Always Allow.")
        }
    }

    /// `isSetUp` is nil for an agent that connects from its own side, so there is nothing to check here.
    private func appRow(
        symbol: String? = nil,
        logo: String? = nil,
        name: String,
        detail: String?,
        isSetUp: Bool?,
        id: String,
        buttonTitle: String,
        action: @escaping () -> Void,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: OnboardingSpacing.medium) {
            Group {
                if let logo {
                    Image(logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: Self.logoSize, height: Self.logoSize)
                        // The App Store artwork is a full square. Apple's app icon shape has a corner
                        // radius of 22.37 percent of its width, with continuous corners.
                        .clipShape(RoundedRectangle(cornerRadius: Self.logoSize * 0.2237, style: .continuous))
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OnboardingSpacing.tight) {
                Text(name).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if isSetUp == true {
                    Label("Set up", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Text("Not set up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle, action: action)
                .onboardingSecondary()
                .disabled(!isEnabled)
                .accessibilityIdentifier("onboarding.setUp.\(id)")
        }
        .padding(OnboardingSpacing.medium)
    }
}

// MARK: - Remote access

struct RemoteAccessScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var serverController: ServerController
    @ObservedObject var cloudflare: CloudflareTunnelController
    /// False picks the way to reach this Mac; true sets up the one that was picked.
    var isSetup = false
    @StateObject private var tailscaleAccess = TailscaleAccessController()
    var body: some View {
        if isSetup { setupBody } else { chooseBody }
    }

    private var chooseBody: some View {
        VStack(spacing: OnboardingSpacing.large) {
            ScreenTitle(
                title: "How should AI apps reach your Mac?",
                subtitle: "Local only is the safest and needs nothing. Pick another way only if you need it."
            )

            VStack(spacing: 0) {
                choiceRow(
                    .local,
                    title: "Local only",
                    detail: "AI apps and your iPhone reach this Mac only on your own network. Nothing is exposed."
                )
                Divider().padding(.horizontal, OnboardingSpacing.medium)
                choiceRow(
                    .tailscale,
                    title: "Tailscale",
                    detail: "Private access from your own devices anywhere. Needs a free Tailscale account."
                )
                Divider().padding(.horizontal, OnboardingSpacing.medium)
                choiceRow(
                    .funnel,
                    title: "Tailscale public address",
                    detail: "A public https address for cloud AI apps such as Claude Web, through Tailscale."
                )
                Divider().padding(.horizontal, OnboardingSpacing.medium)
                choiceRow(
                    .cloudflare,
                    title: "Cloudflare Tunnel",
                    detail:
                        "A public https address on your own domain. Needs a domain that is already on your Cloudflare account."
                )
            }
            .frame(maxWidth: OnboardingSpacing.column)

            Caption("You can change this any time in Settings. Skipping keeps Local only.")
        }
    }

    /// The second screen: what the picked way needs, and the action that sets it up.
    private var setupBody: some View {
        VStack(spacing: OnboardingSpacing.large) {
            switch model.remoteSelection {
            case .local:
                ScreenTitle(title: "Nothing to set up", subtitle: "Local only needs nothing.")
            case .tailscale:
                ScreenTitle(
                    title: "Sign in to Tailscale",
                    subtitle: "iMCP joins your Tailscale network and checks what it needs."
                )
                tailscaleChecklist
            case .funnel:
                ScreenTitle(
                    title: "Turn on your public address",
                    subtitle: "iMCP checks what Tailscale needs. You approve once on Tailscale's page if it asks."
                )
                tailscaleChecklist
                tailscaleAutoEnable
            case .cloudflare:
                ScreenTitle(
                    title: "Set up Cloudflare Tunnel",
                    subtitle: "You need a domain that is already on your Cloudflare account."
                )
                cloudflareChecklist
            }
            Caption("You can change this any time in Settings. Skipping keeps Local only.")
        }
    }

    // MARK: Rows

    private func choiceRow(_ choice: RemoteChoice, title: String, detail: String) -> some View {
        let isSelected = model.remoteSelection == choice
        return Button {
            model.choose(choice)
        } label: {
            HStack(alignment: .top, spacing: OnboardingSpacing.medium) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OnboardingSpacing.tight) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(OnboardingSpacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("onboarding.remote.\(choice.rawValue)")
    }

    // MARK: Checklists

    private var tailscaleChecklist: some View {
        TailscaleChecklistView(
            inputs: model.tailscaleInputs,
            openTailscalePage: model.openTailscalePage,
            getSignInLink: { serverController.restartRemoteAccessNode() }
        )
        .frame(maxWidth: OnboardingSpacing.column, alignment: .leading)
    }

    /// The quiet link under the public address checklist, once this Mac is on the tailnet
    /// and Tailscale has not said that public addresses are allowed.
    @ViewBuilder
    private var tailscaleAutoEnable: some View {
        if case .running(let endpoint) = serverController.remoteAccessState, endpoint.funnelCapabilityGranted != true {
            TailscaleAutoEnable(access: tailscaleAccess, target: endpoint.ipv4Address)
                .frame(maxWidth: OnboardingSpacing.column, alignment: .leading)
                .onChange(of: tailscaleAccess.phase) {
                    if tailscaleAccess.phase == .done { serverController.refreshRemoteAccess() }
                }
        }
    }

    private var cloudflareChecklist: some View {
        CloudflareChecklistView(cloudflare: cloudflare)
            .frame(maxWidth: OnboardingSpacing.column, alignment: .leading)
    }
}

// MARK: - iPhone and iPad

struct IPhoneScreen: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: OnboardingSpacing.large) {
            ScreenTitle(
                title: "Pair your iPhone or iPad",
                subtitle:
                    "The iMCP app shares Health and Alarms, shows every tool call, and lets you approve requests from your phone."
            )

            VStack(spacing: OnboardingSpacing.medium) {
                if let code = model.pairingCode, let expires = model.pairingExpires {
                    if let qr = Self.qrImage(code.url.absoluteString) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 180)
                            .accessibilityLabel("Pairing code")
                    }
                    Text(
                        "Scan this in the iMCP app. It expires at \(expires.formatted(date: .omitted, time: .shortened))."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    Button("Copy Pairing Link") { copyForOnboarding(code.url.absoluteString) }
                        .onboardingSecondary()
                } else {
                    ForEach(model.pairedDevices) { device in
                        Label(
                            device.name + (model.connectedDevice?.id == device.id ? ", connected" : ", paired"),
                            systemImage: "iphone"
                        )
                        .font(.headline)
                    }
                    Button(model.pairedDevices.isEmpty ? "Show Pairing Code" : "Pair Another Device") {
                        model.beginPairing()
                    }
                    .onboardingSecondary()
                    .accessibilityIdentifier("onboarding.pair")
                }
                if let error = model.pairingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(OnboardingSpacing.medium)
            .frame(maxWidth: OnboardingSpacing.column)

            Caption("This step moves on by itself when a device pairs. Skip it if you do not use an iPhone.")
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

// MARK: - Done

struct DoneScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var serverController: ServerController

    var body: some View {
        let progress = model.progress
        VStack(spacing: OnboardingSpacing.large) {
            DrawnStatusMark(kind: .success)
            ScreenTitle(
                title: "iMCP is ready",
                subtitle: "Your AI apps can use what you turned on. iMCP lives in the menu bar.",
                large: true
            )

            VStack(alignment: .leading, spacing: OnboardingSpacing.small) {
                summaryRow(
                    "\(model.servicesOn.count) \(model.servicesOn.count == 1 ? "service is" : "services are") on",
                    isDone: !model.servicesOn.isEmpty
                )
                summaryRow(
                    progress.hasConnectedApp ? "Claude is set up on this Mac" : "No AI app is set up yet",
                    isDone: progress.hasConnectedApp
                )
                summaryRow(
                    "Remote access: \(model.currentRemoteChoice.summaryName)",
                    isDone: progress.hasRemoteAccess
                )
                summaryRow(
                    progress.hasPairedDevice ? "iPhone or iPad paired" : "No iPhone or iPad paired",
                    isDone: progress.hasPairedDevice
                )
            }
            .padding(OnboardingSpacing.medium)
            .frame(maxWidth: OnboardingSpacing.column, alignment: .leading)

            Caption(
                "Settings has the approval mode, which decides when iMCP asks before an action runs. Right now: \(serverController.approvalMode.title)."
            )

            Button("Go Through Setup Again") { model.reset(mode: .firstRun) }
                .buttonStyle(.link)
                .font(.callout)
                .accessibilityIdentifier("onboarding.restart")
        }
    }

    private func summaryRow(_ text: String, isDone: Bool) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
    }
}

extension RemoteChoice {
    var summaryName: String {
        switch self {
        case .local: "Local only"
        case .tailscale: "Tailscale"
        case .funnel: "Tailscale public address"
        case .cloudflare: "Cloudflare Tunnel"
        }
    }
}

func copyForOnboarding(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    _ = NSSound.play(.pop)
}
