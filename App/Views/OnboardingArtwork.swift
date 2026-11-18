// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

// Adapted from Ping Warden's onboarding (OnboardingArtwork.swift).

import SwiftUI

// MARK: - Shared surfaces

enum OnboardingMetrics {
    static let cardCornerRadius: CGFloat = 14
    static let largeCardCornerRadius: CGFloat = 16
}

/// The project's card surface: Liquid Glass on macOS 26, the regular
/// material before it. Matches the Dashboard's cards.
struct OnboardingCardBackground: ViewModifier {
    var cornerRadius: CGFloat = OnboardingMetrics.largeCardCornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

/// Groups glass shapes so they render together on macOS 26; a plain
/// container before it.
struct OnboardingGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Done step

/// A filled circle whose check mark draws itself, or an X for a failure.
struct DrawnStatusMark: View {
    enum Kind {
        case success
        case attention
        case failure
    }

    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(fill)
            mark
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                progress = 1
            } else {
                withAnimation(.easeOut(duration: 0.52).delay(0.16)) { progress = 1 }
            }
        }
    }

    private var fill: Color {
        switch kind {
        case .success: return .green
        case .attention: return .orange
        case .failure: return .red
        }
    }

    private var mark: Path {
        var path = Path()
        switch kind {
        case .success, .attention:
            path.move(to: CGPoint(x: 25, y: 43))
            path.addLine(to: CGPoint(x: 37, y: 55))
            path.addLine(to: CGPoint(x: 60, y: 29))
        case .failure:
            path.move(to: CGPoint(x: 29, y: 29))
            path.addLine(to: CGPoint(x: 55, y: 55))
            path.move(to: CGPoint(x: 55, y: 29))
            path.addLine(to: CGPoint(x: 29, y: 55))
        }
        return path
    }
}
