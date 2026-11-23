// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

// Adapted from Ping Warden's onboarding (OnboardingModel.swift).

import AppKit
import SwiftUI

/// Drives the setup window: the current step, what is already done, and the live
/// state of the optional steps. The step order and Back logic are `OnboardingNavigator`.
@MainActor
final class OnboardingModel: ObservableObject {
    struct Actions {
        var close: () -> Void = {}
        var openSettings: () -> Void = {}
    }

    let serverController: ServerController
    let isEnabled: Binding<Bool>
    var actions = Actions()

    @Published private(set) var navigator: OnboardingNavigator
    @Published private(set) var pairedDevices: [MobileDevice] = []
    @Published private(set) var connectedDevice: MobileDevice?
    @Published private(set) var pairingCode: MobilePairingCode?
    @Published private(set) var pairingExpires: Date?
    @Published private(set) var pairingError: String?
    /// Re-read after Claude Desktop or Claude Code is set up.
    @Published private(set) var appsRevision = 0
    /// The remote access row that is selected. Cloudflare can be selected before it is set up.
    @Published var remoteSelection: RemoteChoice

    /// The person opened a Tailscale page, and iMCP is re-checking until the permission shows up.
    @Published private(set) var isWaitingForTailscale = false
    private var tailscaleTask: Task<Void, Never>?

    private var pairedAtStart: Set<String> = []
    private var pollTask: Task<Void, Never>?

    var mode: OnboardingMode { navigator.mode }
    var step: OnboardingStep { navigator.step }

    init(mode: OnboardingMode, serverController: ServerController, isEnabled: Binding<Bool>) {
        self.serverController = serverController
        self.isEnabled = isEnabled
        self.navigator = OnboardingNavigator(mode: mode, progress: OnboardingProgress())
        self.remoteSelection = .local
        reset(mode: mode)
    }

    /// Starts over in `mode`, reading what is already set up.
    func reset(mode: OnboardingMode) {
        remoteSelection = currentRemoteChoice
        navigator = OnboardingNavigator(mode: mode, progress: progress, remoteChoice: currentRemoteChoice)
        Task { await refreshDevices() }
        updatePolling()
    }

    // MARK: What is set up

    var servicesOn: [ServiceConfig] {
        serverController.computedServiceConfigs.filter { $0.binding.wrappedValue }
    }

    var progress: OnboardingProgress {
        OnboardingProgress(
            hasServices: serverController.computedServiceConfigs.contains {
                $0.name != "Maps" && $0.name != "Utilities" && $0.binding.wrappedValue
            },
            hasConnectedApp: ClaudeDesktop.isConfigured || ClaudeCode.isConfigured
                || !serverController.oauthConnections.grants.isEmpty,
            hasRemoteAccess: currentRemoteChoice != .local,
            hasPairedDevice: !pairedDevices.isEmpty
        )
    }

    var currentRemoteChoice: RemoteChoice {
        RemoteChoice.current(
            .init(
                tailscale: serverController.isRemoteAccessEnabled,
                funnel: serverController.isRemoteAccessFunnelEnabled,
                cloudflare: serverController.cloudflareTunnel.isEnabled
            )
        )
    }

    /// The recommended services: everything except Home, which asks for more than a
    /// permission and stays off until the person turns it on.
    var recommendedConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs.filter { !($0.service is HomeService) }
    }

    var recommendedAreOn: Bool {
        isEnabled.wrappedValue && recommendedConfigs.allSatisfy { $0.binding.wrappedValue }
    }

    // MARK: Navigation

    func continueTapped() {
        navigator.advance()
        updatePolling()
    }

    func backTapped() {
        if navigator.canGoBack {
            navigator.goBack()
            updatePolling()
        } else {
            actions.close()
        }
    }

    /// Shows `step` directly. Debug screenshots use it.
    func jump(to step: OnboardingStep) {
        navigator.show(step)
        updatePolling()
    }

    func closeTapped() { actions.close() }

    func openSettingsTapped() {
        actions.close()
        actions.openSettings()
    }

    // MARK: Services

    func turnOnRecommended() {
        isEnabled.wrappedValue = true
        for config in recommendedConfigs where !config.binding.wrappedValue {
            serverController.setService(config, enabled: true)
        }
    }

    // MARK: Connect apps

    func setUpClaudeDesktop() {
        ClaudeDesktop.showConfigurationPanel(serverController: serverController)
        appsRevision += 1
    }

    func setUpClaudeCode() {
        ClaudeCode.showConfigurationPanel(serverController: serverController)
        appsRevision += 1
    }

    // MARK: Remote access

    /// Applies a choice with the app's existing remote access state.
    /// Cloudflare only becomes selected here; it needs a login and a hostname first.
    func choose(_ choice: RemoteChoice) {
        remoteSelection = choice
        navigator.setRemoteChoice(choice)
        let target = choice.switches
        if serverController.isRemoteAccessEnabled != target.tailscale {
            serverController.isRemoteAccessEnabled = target.tailscale
        }
        if serverController.isRemoteAccessFunnelEnabled != target.funnel {
            serverController.isRemoteAccessFunnelEnabled = target.funnel
        }
        // Picking another way to reach this Mac ends the tunnel. Picking Cloudflare starts nothing until it is set up.
        if !target.cloudflare, serverController.cloudflareTunnel.isEnabled {
            serverController.cloudflareTunnel.setEnabled(false)
        }
    }

    /// The live state of iMCP's Tailscale node, as the checklist reads it.
    var tailscaleInputs: TailscaleChecklist.Inputs {
        let node: TailscaleChecklist.Node
        var funnelAllowed: Bool?
        var publicAddress = TailscaleChecklist.PublicAddress.off
        switch serverController.remoteAccessState {
        case .needsLogin(let url): node = .needsLogin(url)
        case .starting: node = .starting
        case .needsApproval: node = .needsApproval
        case .failed(let reason): node = .failed(reason)
        case .running(let endpoint):
            node = .running(dnsName: endpoint.dnsName)
            funnelAllowed = endpoint.funnelCapabilityGranted
            switch endpoint.funnel {
            case .off: break
            case .active(let url): publicAddress = URL(string: url).map { .active($0) } ?? .off
            case .failed(let message): publicAddress = .failed(message)
            }
        default: node = .off
        }
        return TailscaleChecklist.Inputs(
            node: node,
            funnelAllowed: funnelAllowed,
            publicAddress: publicAddress,
            wantsPublicAddress: remoteSelection == .funnel,
            isWaitingForApproval: isWaitingForTailscale
        )
    }

    /// Opens a page that Tailscale asked the person to visit, then re-checks every few seconds
    /// and moves on by itself when the permission turns up.
    func openTailscalePage(_ url: URL) {
        NSWorkspace.shared.open(url)
        isWaitingForTailscale = true
        tailscaleTask?.cancel()
        tailscaleTask = Task { [weak self] in
            for _ in 0 ..< 100 {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                if TailscaleChecklist.items(self.tailscaleInputs).allSatisfy(\.isDone) { break }
                self.serverController.refreshRemoteAccess()
            }
            self?.isWaitingForTailscale = false
        }
    }

    /// Turns a service on or off, and turns the server on with the first service.
    func setService(_ config: ServiceConfig, enabled: Bool) {
        if enabled { isEnabled.wrappedValue = true }
        serverController.setService(config, enabled: enabled)
    }

    // MARK: iPhone and iPad

    func beginPairing() {
        Task {
            do {
                pairingCode = try await MobileService.shared.beginPairing()
                pairingExpires = Date().addingTimeInterval(MobileService.pairingLifetime)
                pairingError = nil
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    private func refreshDevices() async {
        let devices = await MobileService.shared.devices
        pairedDevices = devices
        connectedDevice = await MobileService.shared.connectedDevice
    }

    /// While the iPhone step is showing, watch for a phone to pair and move on by itself when one does.
    private func updatePolling() {
        pollTask?.cancel()
        pollTask = nil
        guard step == .iPhone else { return }
        pairedAtStart = Set(pairedDevices.map(\.id))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.refreshDevices()
                if self.step == .iPhone, !Set(self.pairedDevices.map(\.id)).subtracting(self.pairedAtStart).isEmpty {
                    self.navigator.show(.done)
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    func windowWillClose() {
        pollTask?.cancel()
        pollTask = nil
        tailscaleTask?.cancel()
        tailscaleTask = nil
    }
}
