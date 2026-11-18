// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

// Adapted from Ping Warden's onboarding (OnboardingView.swift).

import SwiftUI

// MARK: - Layout scale

/// One spacing scale for every screen, so gaps read as related or separate
/// at a glance: 4 inside a label pair, 8 between a title and its line, 16
/// between items, 24 between groups.
enum OnboardingSpacing {
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let gutter: CGFloat = 40
    /// The readable column for body text and cards.
    static let column: CGFloat = 420
}

// MARK: - Window content

/// The setup window: the first-run Welcome, the guided steps that follow it, and Set Up iMCP,
/// which resumes at the first step that is not done. Each guided screen centers its content
/// vertically between the title bar and the button row.
struct OnboardingView: View {
    /// The window is 540 points wide and as tall as the current screen's content, so no screen
    /// carries a band of empty space. Shorter screens keep a floor height so the window does not
    /// jump between steps and the footer buttons stay under the pointer. On a display too short
    /// for a screen, the window stops at the display's visible height and the screen scrolls.
    static let width: CGFloat = 540
    static let minimumContentHeight: CGFloat = 420
    /// Accessibility text sizes scroll inside a window of this height.
    static let accessibilityHeight: CGFloat = 680

    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The window measures this view and sizes itself, no taller than its display.
        // A screen that doesn't fit scrolls rather than asking the window to grow past the display.
        ViewThatFits(in: .vertical) {
            sizedContent
            ScrollView { sizedContent }
        }
        .background(.background)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.step)
    }

    /// The current screen at its own height, or the accessibility height.
    private var sizedContent: some View {
        Group {
            if model.step == .welcome {
                WelcomeScreen(model: model)
            } else {
                VStack(spacing: 0) {
                    if dynamicTypeSize.isAccessibilitySize {
                        ScrollView { steppedContent }
                    } else {
                        steppedContent
                    }
                    footer
                }
            }
        }
        .frame(width: Self.width)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? Self.accessibilityHeight : nil)
        .fixedSize(horizontal: false, vertical: !dynamicTypeSize.isAccessibilitySize)
    }

    /// The current screen, centered in at least the floor height.
    private var steppedContent: some View {
        screen
            .padding(.horizontal, OnboardingSpacing.gutter)
            .padding(.top, OnboardingSpacing.small)
            .padding(.bottom, OnboardingSpacing.large)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Self.minimumContentHeight)
    }

    @ViewBuilder
    private var screen: some View {
        Group {
            switch model.step {
            case .welcome: EmptyView()
            case .services: ServicesScreen(model: model, serverController: model.serverController)
            case .connectApps: ConnectAppsScreen(model: model)
            case .remoteAccess, .remoteSetup:
                RemoteAccessScreen(
                    model: model,
                    serverController: model.serverController,
                    cloudflare: model.serverController.cloudflareTunnel,
                    isSetup: model.step == .remoteSetup
                )
            case .iPhone: IPhoneScreen(model: model)
            case .done: DoneScreen(model: model, serverController: model.serverController)
            }
        }
        .id(model.step)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
    }

    // MARK: Footer

    private var footer: some View {
        OnboardingGlassGroup(spacing: 8) {
            ZStack {
                PageDots(count: model.navigator.pageSteps.count, index: model.navigator.pageIndex)
                HStack(spacing: 8) {
                    leadingButton
                    Spacer(minLength: 12)
                    trailingButton
                }
            }
        }
        .padding(.horizontal, OnboardingSpacing.large)
        .frame(height: 76)
    }

    @ViewBuilder
    private var leadingButton: some View {
        if model.step == .done {
            Button("Open Settings") { model.openSettingsTapped() }
                .onboardingSecondary()
                .accessibilityIdentifier("onboarding.openSettings")
        } else {
            Button(model.navigator.canGoBack ? "Back" : "Not Now") { model.backTapped() }
                .onboardingSecondary()
                .keyboardShortcut(model.navigator.canGoBack ? nil : .cancelAction)
                .accessibilityIdentifier("onboarding.back")
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch model.step {
        case .welcome:
            EmptyView()
        case .done:
            Button("Done") { model.closeTapped() }
                .onboardingPrimary()
                .accessibilityIdentifier("onboarding.done")
        case .services, .remoteAccess:
            Button("Continue") { model.continueTapped() }
                .onboardingPrimary()
                .accessibilityIdentifier("onboarding.continue")
        case .connectApps, .iPhone, .remoteSetup:
            if model.progress.isComplete(model.step) {
                Button("Continue") { model.continueTapped() }
                    .onboardingPrimary()
                    .accessibilityIdentifier("onboarding.continue")
            } else {
                Button("Skip") { model.continueTapped() }
                    .onboardingSecondary()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }
}

// MARK: - Buttons

extension View {
    /// The screen's one primary action: prominent Liquid Glass on macOS 26,
    /// the bordered prominent style before it.
    @ViewBuilder
    func onboardingPrimary(isDefault: Bool = true) -> some View {
        let base = self.controlSize(.large).keyboardShortcut(isDefault ? .defaultAction : nil)
        if #available(macOS 26, *) {
            base.buttonStyle(.glassProminent)
        } else {
            base.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func onboardingSecondary() -> some View {
        let base = self.controlSize(.large)
        if #available(macOS 26, *) {
            base.buttonStyle(.glass)
        } else {
            base.buttonStyle(.bordered)
        }
    }
}

struct PageDots: View {
    let count: Int
    let index: Int?

    var body: some View {
        if count > 0, let index {
            HStack(spacing: 7) {
                ForEach(0 ..< count, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Color.primary : Color.secondary.opacity(dot < index ? 0.7 : 0.35))
                        .frame(width: 7, height: 7)
                        .scaleEffect(dot == index ? 1.15 : 1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(index + 1) of \(count)")
        }
    }
}

// MARK: - Screens

struct ScreenTitle: View {
    let title: String
    var subtitle: String?
    var large = false

    var body: some View {
        VStack(spacing: OnboardingSpacing.small) {
            Text(title)
                .font(large ? .largeTitle : .title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OnboardingSpacing.column)
            }
        }
    }
}

struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: OnboardingSpacing.column)
    }
}

struct LargeAppIcon: View {
    var size: CGFloat = 80

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct WelcomeBenefitRow: View {
    let benefit: OnboardingCopy.Benefit

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingSpacing.medium) {
            Image(systemName: benefit.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OnboardingSpacing.tight) {
                Text(benefit.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(benefit.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
