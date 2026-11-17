import Foundation

// Activity history events synced from the Mac to a paired iPhone or iPad.
// This file uses only Foundation, so the Mac app, the iOS app, and tests compile it.

enum MobileActivityLink {
    static let syncTool = "activity_sync"
}

/// One MCP tool call recorded on the Mac and synced to paired iOS devices.
struct MobileActivityEvent: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, CaseIterable, Sendable {
        case succeeded
        case failed
        case denied
    }

    var id: UUID
    var sequence: Int64
    var timestamp: Date
    var clientName: String
    var serviceName: String
    var toolName: String
    var isWrite: Bool
    var outcome: Outcome
    var detail: String?
    var durationMs: Int

    init(
        id: UUID = UUID(),
        sequence: Int64 = 0,
        timestamp: Date = Date(),
        clientName: String,
        serviceName: String,
        toolName: String,
        isWrite: Bool,
        outcome: Outcome,
        detail: String? = nil,
        durationMs: Int = 0
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.clientName = clientName
        self.serviceName = serviceName
        self.toolName = toolName
        self.isWrite = isWrite
        self.outcome = outcome
        self.detail = detail
        self.durationMs = durationMs
    }
}

struct MobileActivitySyncRequest: Codable, Equatable, Sendable {
    var events: [MobileActivityEvent]
}

struct MobileActivitySyncResponse: Codable, Equatable, Sendable {
    var ackedSequence: Int64
}
