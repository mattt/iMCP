// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

// Adapted from Ping Warden's onboarding (Core/OnboardingFlow.swift).

import Foundation

// Decisions for the setup window: which screen comes next, what Back does,
// and which way to reach this Mac is chosen. Kept Foundation-only so every
// transition is unit tested without AppKit.

/// Why the setup window opened.
enum OnboardingMode: Equatable, Sendable {
    /// The automatic first-run introduction, or Set Up iMCP before the
    /// introduction was ever seen.
    case firstRun
    /// Set Up iMCP from the menu or Settings. Resumes at the first incomplete
    /// step rather than replaying the introduction.
    case finishSetup
}

enum OnboardingStep: String, Equatable, Sendable, CaseIterable {
    case welcome
    /// Which services AI apps can reach.
    case services
    /// Optional: how AI apps reach this Mac from outside. Comes before the apps,
    /// because the cloud agents need the public address it sets up.
    /// This screen only picks the way; the next one sets it up.
    case remoteAccess
    /// Optional: sets up the way that was picked. Skipped for Local only, which needs nothing.
    case remoteSetup
    /// Adding iMCP to Claude Desktop and Claude Code, and the connector URL for
    /// Claude Duet, Muse and Gemini.
    case connectApps
    /// Optional: pairing an iPhone or iPad.
    case iPhone
    case done

    /// Steps a person can skip without changing anything.
    var isOptional: Bool { self == .remoteAccess || self == .remoteSetup || self == .iPhone }
}

/// What is already set up, read from the app's live state when the window opens
/// and again as it changes.
struct OnboardingProgress: Equatable, Sendable {
    var hasServices = false
    var hasConnectedApp = false
    var hasRemoteAccess = false
    var hasPairedDevice = false

    func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome, .done: return true
        case .services: return hasServices
        case .connectApps: return hasConnectedApp
        case .remoteAccess, .remoteSetup: return hasRemoteAccess
        case .iPhone: return hasPairedDevice
        }
    }
}

/// Moves between steps. Back retraces the screens actually shown, so a
/// person who skipped a step never lands on it by going back.
struct OnboardingNavigator: Equatable, Sendable {
    /// The guided screens after the Welcome, in order.
    static let guidedSteps: [OnboardingStep] = [.services, .remoteAccess, .remoteSetup, .connectApps, .iPhone, .done]

    let mode: OnboardingMode
    private(set) var step: OnboardingStep
    private(set) var history: [OnboardingStep] = []
    /// The way picked on the remote access screen. Local only needs no setup screen.
    private(set) var remoteChoice: RemoteChoice
    /// Fixed when the window opens, so the page dots do not jump as steps complete.
    private let firstPageStep: OnboardingStep

    /// The dots: every guided step from where the window opened, without the remote setup screen
    /// while the choice is Local only, because that screen is skipped.
    var pageSteps: [OnboardingStep] {
        let start = Self.guidedSteps.firstIndex(of: firstPageStep) ?? 0
        return Self.guidedSteps[start...].filter { $0 != .remoteSetup || remoteChoice != .local }
    }

    init(mode: OnboardingMode, progress: OnboardingProgress, remoteChoice: RemoteChoice = .local) {
        self.mode = mode
        self.remoteChoice = remoteChoice
        let entry = Self.entryStep(mode: mode, progress: progress)
        self.step = entry
        self.firstPageStep = mode == .firstRun ? .services : entry
    }

    mutating func setRemoteChoice(_ choice: RemoteChoice) {
        remoteChoice = choice
    }

    /// Where a mode starts. Set Up iMCP resumes at the first incomplete
    /// step, or at Done when everything is set up.
    static func entryStep(mode: OnboardingMode, progress: OnboardingProgress) -> OnboardingStep {
        switch mode {
        case .firstRun:
            return .welcome
        case .finishSetup:
            return guidedSteps.first { !progress.isComplete($0) } ?? .done
        }
    }

    /// The screen after `step` when the person continues or skips.
    static func step(after step: OnboardingStep) -> OnboardingStep {
        switch step {
        case .welcome: return .services
        case .services: return .remoteAccess
        case .remoteAccess: return .remoteSetup
        case .remoteSetup: return .connectApps
        case .connectApps: return .iPhone
        case .iPhone: return .done
        case .done: return .done
        }
    }

    /// The highlighted dot. The Welcome has its own layout without dots.
    var pageIndex: Int? { pageSteps.firstIndex(of: step) }

    /// Whether Back has somewhere to go. When it does not, the left
    /// button closes the window instead (Not Now).
    var canGoBack: Bool { step != .done && !history.isEmpty }

    /// Continue, or Skip on an optional step.
    mutating func advance() {
        var next = Self.step(after: step)
        // Local only needs nothing set up, so its setup screen is skipped.
        if next == .remoteSetup, remoteChoice == .local { next = Self.step(after: .remoteSetup) }
        guard next != step else { return }
        history.append(step)
        step = next
    }

    /// Jump to a step the flow reaches on its own, such as Done after a
    /// phone pairs.
    mutating func show(_ target: OnboardingStep) {
        guard target != step else { return }
        if target == .done {
            history.removeAll()
        } else {
            history.append(step)
        }
        step = target
    }

    mutating func goBack() {
        guard canGoBack, let previous = history.popLast() else { return }
        step = previous
    }
}

/// How AI apps reach this Mac, from simplest to most involved. The setup
/// window suggests them in this order, and Local only is the default.
enum RemoteChoice: Int, CaseIterable, Equatable, Sendable {
    /// Only this Mac's network. Nothing is exposed.
    case local
    /// Private access from the person's own devices through their tailnet.
    case tailscale
    /// A public https address through Tailscale, for cloud AI apps.
    case funnel
    /// A public https address on the person's own Cloudflare domain. Advanced.
    case cloudflare

    var isAdvanced: Bool { self == .cloudflare }

    /// The switches that make up a choice. They are the app's existing remote access state.
    struct Switches: Equatable, Sendable {
        var tailscale: Bool
        var funnel: Bool
        var cloudflare: Bool
    }

    /// The choice that the current switches amount to, so a person who already
    /// set something up sees it selected and nothing is turned off by opening the window.
    static func current(_ switches: Switches) -> RemoteChoice {
        if switches.cloudflare { return .cloudflare }
        if switches.tailscale { return switches.funnel ? .funnel : .tailscale }
        return .local
    }

    /// The switches after the person picks this choice.
    var switches: Switches {
        switch self {
        case .local: Switches(tailscale: false, funnel: false, cloudflare: false)
        case .tailscale: Switches(tailscale: true, funnel: false, cloudflare: false)
        case .funnel: Switches(tailscale: true, funnel: true, cloudflare: false)
        case .cloudflare: Switches(tailscale: false, funnel: false, cloudflare: true)
        }
    }
}
