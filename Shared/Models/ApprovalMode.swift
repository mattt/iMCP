import Foundation
import MCP

/// Global approval policy for MCP tool calls in iMCP.
enum ApprovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Every read or write tool call prompts for confirmation on the Mac (and paired iPhone) before running.
    case askEverything
    /// Only write tool calls (`tool.isWrite`) prompt for confirmation; read-only tools run immediately.
    case askWritesOnly
    /// Grants full read and write access in iMCP without iMCP pop-ups; the connected agent manages prompts.
    case agentManaged
    /// Grants full read and write access in iMCP without individual approvals.
    case allowEverything

    static let defaultMode: ApprovalMode = .askWritesOnly
    static let defaultsKey = "approvalMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askEverything:
            "Ask for Everything"
        case .askWritesOnly:
            "Ask for Writes Only"
        case .agentManaged:
            "Ask in Agent (Full Access in iMCP)"
        case .allowEverything:
            "Allow Everything"
        }
    }

    var summary: String {
        switch self {
        case .askEverything:
            "Present a confirmation prompt before every read or write tool call."
        case .askWritesOnly:
            "Present a confirmation prompt for writes. Read-only tools run right away."
        case .agentManaged:
            "Allow all reads and writes in iMCP so your AI app asks before each action."
        case .allowEverything:
            "Allow all reads and writes in iMCP without individual confirmation prompts."
        }
    }

    /// Whether Mac and outbound confirmation pop-ups are skipped by iMCP.
    var skipsConfirmationPopups: Bool {
        switch self {
        case .askEverything, .askWritesOnly:
            false
        case .agentManaged, .allowEverything:
            true
        }
    }

    /// Whether iMCP allows write tools across enabled services regardless of per-service Allow writes switches.
    var bypassesServiceWriteToggles: Bool {
        switch self {
        case .askEverything, .askWritesOnly:
            false
        case .agentManaged, .allowEverything:
            true
        }
    }

    /// Whether Settings shows client-side configuration instructions for this mode.
    var showsAgentConfigurationHelp: Bool {
        switch self {
        case .askEverything, .askWritesOnly:
            false
        case .agentManaged, .allowEverything:
            true
        }
    }

    func requiresConfirmation(isWrite: Bool) -> Bool {
        switch self {
        case .askEverything:
            true
        case .askWritesOnly:
            isWrite
        case .agentManaged, .allowEverything:
            false
        }
    }

    func requiresConfirmation(for tool: Tool) -> Bool {
        requiresConfirmation(isWrite: tool.isWrite)
    }

    static func current(defaults: UserDefaults = .standard) -> ApprovalMode {
        guard let rawValue = defaults.string(forKey: defaultsKey),
            let mode = ApprovalMode(rawValue: rawValue)
        else {
            return defaultMode
        }
        return mode
    }

    static func setCurrent(_ mode: ApprovalMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }

    struct AgentInstruction: Identifiable, Equatable, Sendable {
        let id: String
        let agentName: String
        let instructions: String
        let codeSnippet: String?

        init(id: String, agentName: String, instructions: String, codeSnippet: String? = nil) {
            self.id = id
            self.agentName = agentName
            self.instructions = instructions
            self.codeSnippet = codeSnippet
        }
    }

    var agentInstructionsHeading: String? {
        switch self {
        case .askEverything, .askWritesOnly:
            nil
        case .agentManaged:
            "Configure your AI app to prompt before each iMCP tool call:"
        case .allowEverything:
            "Configure your AI app to permit all iMCP reads and writes without prompting:"
        }
    }

    var agentInstructions: [AgentInstruction] {
        switch self {
        case .askEverything, .askWritesOnly:
            return []
        case .agentManaged:
            return [
                AgentInstruction(
                    id: "claude-desktop",
                    agentName: "Claude Desktop",
                    instructions:
                        "Open Claude Desktop Settings, choose Connectors or Extensions, select iMCP, and set its tools to \"Always ask\" or \"Needs approval\" instead of \"Always allow\"."
                ),
                AgentInstruction(
                    id: "claude-code",
                    agentName: "Claude Code",
                    instructions:
                        "Remove \"mcp__iMCP__*\" from permissions.allow in ~/.claude/settings.json, or run /permissions in a session, so Claude Code asks before each iMCP tool call."
                ),
                AgentInstruction(
                    id: "claude-ai",
                    agentName: "claude.ai",
                    instructions:
                        "Open Settings > Connectors on claude.ai, expand iMCP, and set each tool permission to \"Needs approval\" so Claude asks before running actions."
                ),
                AgentInstruction(
                    id: "duet",
                    agentName: "Duet",
                    instructions:
                        "Open Duet's MCP or tool permissions settings, select iMCP, and keep tool approvals set to ask before running actions."
                ),
                AgentInstruction(
                    id: "muse",
                    agentName: "Muse",
                    instructions:
                        "Open Muse's connected tools settings, select iMCP, and keep read and write permissions set to ask for confirmation before running."
                ),
            ]
        case .allowEverything:
            return [
                AgentInstruction(
                    id: "claude-desktop",
                    agentName: "Claude Desktop",
                    instructions:
                        "Open Claude Desktop Settings, choose Connectors or Extensions, select iMCP, and set its tools to \"Always allow\" to permit all reads and writes."
                ),
                AgentInstruction(
                    id: "claude-code",
                    agentName: "Claude Code",
                    instructions:
                        "Add \"mcp__iMCP__*\" to permissions.allow in ~/.claude/settings.json, or pass --allowedTools \"mcp__iMCP__*\", to permit all iMCP reads and writes.",
                    codeSnippet: """
                        {
                          "permissions": {
                            "allow": [
                              "mcp__iMCP__*"
                            ]
                          }
                        }
                        """
                ),
                AgentInstruction(
                    id: "claude-ai",
                    agentName: "claude.ai",
                    instructions:
                        "Open Settings > Connectors on claude.ai, expand iMCP, and set tool permissions to \"Always allow\" to permit all reads and writes without prompts."
                ),
                AgentInstruction(
                    id: "duet",
                    agentName: "Duet",
                    instructions:
                        "Open Duet's MCP or tool permissions settings, select iMCP, and add iMCP tools to the auto-approve or allowed list to permit all reads and writes."
                ),
                AgentInstruction(
                    id: "muse",
                    agentName: "Muse",
                    instructions:
                        "Open Muse's connected tools settings, select iMCP, and allow iMCP read and write tools in its permission profile. Sensitive actions may still prompt in Muse."
                ),
            ]
        }
    }
}

/// Serializes interactive tool confirmation prompts in FIFO order so parallel tool calls
/// wait their turn instead of colliding with `.busy`.
actor ToolConfirmationQueue {
    static let shared = ToolConfirmationQueue()

    private var isLocked = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    var queuedCount: Int { waiters.count }

    nonisolated func serialize<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isLocked {
            isLocked = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume()
        } else {
            isLocked = false
        }
    }
}

/// Central enforcement point for `ApprovalMode` around `Service.call`.
enum ToolCallApproval {
    static func confirmationRequest(
        tool: Tool,
        serviceName: String?,
        arguments: [String: Value],
        clientName: String?
    ) -> OutboundConfirmationRequest {
        let action = tool.annotations.title ?? "Run \(tool.name)"
        var details: [OutboundConfirmationRequest.Detail] = []
        if let serviceName, !serviceName.isEmpty {
            details.append(.init(label: "Service", value: serviceName))
        }
        details.append(.init(label: "Tool", value: tool.name, isIdentifier: true))
        details.append(.init(label: "Access", value: tool.isWrite ? "Write" : "Read-only"))

        var body: String?
        for key in arguments.keys.sorted() {
            guard let value = arguments[key] else { continue }
            if tool.name == "messages_send", key == "text", let text = value.stringValue {
                body = text
                continue
            }
            details.append(.init(label: key, value: formattedArgumentValue(value)))
        }

        return OutboundConfirmationRequest(
            action: action,
            clientName: clientName,
            details: details,
            body: body
        )
    }

    static func execute(
        tool: Tool,
        in service: any Service,
        serviceName: String? = nil,
        arguments: [String: Value],
        clientName: String?,
        defaults: UserDefaults = .standard,
        confirmer: any OutboundConfirming,
        queue: ToolConfirmationQueue = .shared
    ) async throws -> Value {
        if tool.isWrite, !service.areWritesEnabled(defaults: defaults) {
            throw WritesDisabledError(tool: tool.name)
        }

        let mode = ApprovalMode.current(defaults: defaults)
        let confirmedByGate: Bool
        if mode.requiresConfirmation(for: tool) {
            let request = confirmationRequest(
                tool: tool,
                serviceName: serviceName,
                arguments: arguments,
                clientName: clientName
            )
            try await queue.serialize {
                switch await confirmer.confirm(request) {
                case .approved:
                    return
                case .declined:
                    throw OutboundConfirmationError.declined(action: request.action)
                case .timedOut:
                    throw OutboundConfirmationError.timedOut(action: request.action)
                case .busy:
                    throw OutboundConfirmationError.busy(action: request.action)
                }
            }
            confirmedByGate = true
        } else {
            confirmedByGate = false
        }

        guard
            let value = try await ToolCallContext.$clientName.withValue(
                clientName,
                operation: {
                    try await ToolCallContext.$alreadyConfirmedByGlobalGate.withValue(
                        confirmedByGate,
                        operation: {
                            try await service.call(tool: tool.name, with: arguments, defaults: defaults)
                        }
                    )
                }
            )
        else {
            throw ToolExecutionError.toolNotFound(tool.name)
        }
        return value
    }

    private static func formattedArgumentValue(_ value: Value) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .double(let number):
            return String(number)
        case .string(let text):
            return text
        case .data(let mimeType, let data):
            let kind = mimeType ?? "binary"
            return "\(kind) (\(data.count) bytes)"
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }
    }
}

private enum ToolExecutionError: LocalizedError {
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            "Tool not found: \(name)"
        }
    }
}
