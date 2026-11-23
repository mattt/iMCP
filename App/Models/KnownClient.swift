import Foundation

/// An AI app that iMCP shows with its own logo and steps.
struct KnownClient: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        /// Runs on this Mac, and iMCP can add itself to its settings.
        case onThisMac
        /// Connects over a public address.
        case cloud
    }

    let id: String
    let name: String
    let kind: Kind
    /// The asset catalog image, or nil for an app that uses a symbol.
    let logoAsset: String?
    let symbol: String
    /// The id of this app's entry in ``ApprovalMode/agentInstructions``.
    let instructionID: String
    /// Short steps for connecting.
    let steps: String
    /// Lowercased fragments that identify the app by the name it reports.
    let aliases: [String]

    static let claudeDesktop = KnownClient(
        id: "claudeDesktop",
        name: "Claude Desktop",
        kind: .onThisMac,
        logoAsset: "ConnectorClaude",
        symbol: "bubble.left.fill",
        instructionID: "claude-desktop",
        steps: "Press Set Up. iMCP adds itself to Claude Desktop.",
        aliases: ["claude desktop"]
    )
    static let claudeCode = KnownClient(
        id: "claudeCode",
        name: "Claude Code",
        kind: .onThisMac,
        logoAsset: "ConnectorClaudeCode",
        symbol: "terminal",
        instructionID: "claude-code",
        steps: "Press Set Up. iMCP adds itself to Claude Code.",
        aliases: ["claude code", "claude-code"]
    )
    static let claudeAI = KnownClient(
        id: "claudeAI",
        name: "Claude Web",
        kind: .cloud,
        logoAsset: "ConnectorClaude",
        symbol: "bubble.left.fill",
        instructionID: "claude-ai",
        steps:
            "In Claude Web (claude.ai), open Settings, then Connectors, then Add custom connector. Paste the address.",
        aliases: ["claude web", "claude.ai", "claude"]
    )
    static let claudeDuet = KnownClient(
        id: "claudeDuet",
        name: "Claude Duet",
        kind: .cloud,
        logoAsset: "ConnectorClaudeDuet",
        symbol: "bubble.left.and.bubble.right.fill",
        instructionID: "duet",
        steps: "Add a custom connector in Claude Duet and paste the address. Approve once in iMCP.",
        aliases: ["duet"]
    )
    static let muse = KnownClient(
        id: "muse",
        name: "Muse",
        kind: .cloud,
        logoAsset: "ConnectorMuse",
        symbol: "sparkles",
        instructionID: "muse",
        steps: "Add a connector in Muse and paste the address. Sign in when it asks.",
        aliases: ["muse"]
    )
    static let gemini = KnownClient(
        id: "gemini",
        name: "Gemini",
        kind: .cloud,
        logoAsset: "ConnectorGemini",
        symbol: "sparkle",
        instructionID: "gemini",
        steps: "Add a custom connector in Gemini and paste the address. Approve once in iMCP.",
        aliases: ["gemini"]
    )

    /// In the order Settings lists them.
    static let all: [KnownClient] = [.claudeDesktop, .claudeCode, .claudeAI, .claudeDuet, .muse, .gemini]

    /// The known app that a reported name belongs to, or nil for any other app.
    /// A specific app wins over the generic "Claude".
    static func match(name: String) -> KnownClient? {
        let lowered = name.lowercased()
        let order: [KnownClient] = [.claudeDuet, .muse, .gemini, .claudeCode, .claudeDesktop, .claudeAI]
        return order.first { client in client.aliases.contains { lowered.contains($0) } }
    }
}
