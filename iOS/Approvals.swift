import Foundation
import MCP
import OSLog
import SwiftUI
import UIKit
import UserNotifications

/// The approvals that the Mac asks this phone to answer.
///
/// The Mac sends its open requests with `approval_sync` and takes the answers back in the same call.
/// Nothing here is written to disk, so no database lock is held when iOS suspends the app.
@MainActor
final class PhoneApprovals: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneApprovals()

    static let category = "co.dododo.iMCP.approval"
    private static let approveAction = "approve"
    private static let denyAction = "deny"

    @Published private(set) var requests: [RemoteApprovalRequest] = []

    let inbox = ApprovalInbox()
    private let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "approvals")

    /// Registers the notification buttons. Call once at launch.
    func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(
            identifier: Self.approveAction,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: Self.denyAction,
            title: "Deny",
            options: [.destructive]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [approve, deny],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Handles the Mac's `approval_sync` call.
    func sync(_ request: RemoteApprovalSyncRequest) -> RemoteApprovalSyncResponse {
        let result = inbox.sync(pending: request.pending, ack: request.ack)
        refresh()
        if UIApplication.shared.applicationState != .active {
            for added in result.added { notify(added) }
        }
        if !result.removed.isEmpty {
            let ids = result.removed.map(Self.notificationID)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
        return RemoteApprovalSyncResponse(answers: result.answers)
    }

    /// Records the person's answer from the app.
    func answer(_ id: String, _ decision: RemoteApprovalDecision) {
        inbox.answer(id, decision)
        refresh()
        let ids = [Self.notificationID(id)]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Drops requests that expired while the app was open.
    func refresh() {
        requests = inbox.visible()
    }

    private static func notificationID(_ id: String) -> String { "approval-\(id)" }

    private func notify(_ request: RemoteApprovalRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        var lines = request.details
        if let body = request.body { lines.append(body) }
        content.body = lines.joined(separator: "\n")
        content.categoryIdentifier = Self.category
        content.userInfo = ["id": request.id]
        content.sound = .default
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.notificationID(request.id), content: content, trigger: nil)
        ) { [log] error in
            if let error { log.error("Couldn't post the approval: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Notification buttons

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["id"] as? String else { return }
        let decision: RemoteApprovalDecision
        switch response.actionIdentifier {
        case Self.approveAction: decision = .approve
        case Self.denyAction: decision = .deny
        default: return  // The person opened the app; the request is on screen.
        }
        // Keep the app awake until the Mac has the answer, then let go.
        await BackgroundWork.run("Deliver approval") {
            await MainActor.run {
                PhoneApprovals.shared.inbox.answerFromNotification(id, decision)
                PhoneApprovals.shared.refresh()
                PhoneConnection.shared.start()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if !PhoneApprovals.shared.inbox.hasUndeliveredAnswers { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

extension PhoneBackend {
    /// The tool that the Mac calls to show approvals here and collect the answers.
    nonisolated var approvalTool: Tool {
        Tool(
            name: RemoteApprovalLink.syncTool,
            description: "Show the Mac's open approvals and return the answers given here.",
            inputSchema: .object(properties: [:], additionalProperties: true),
            annotations: .init(readOnlyHint: false, openWorldHint: false)
        ) { input in
            let request = try MobileCoding.decoder.decode(
                RemoteApprovalSyncRequest.self,
                from: JSONEncoder().encode(input)
            )
            let response = await BackgroundWork.run("Sync approvals") {
                await PhoneApprovals.shared.sync(request)
            }
            return try JSONDecoder().decode(Value.self, from: MobileCoding.encoder.encode(response))
        }
    }
}

// MARK: - Views

/// The approvals waiting for an answer, at the top of the status screen.
struct ApprovalsSection: View {
    @ObservedObject var approvals: PhoneApprovals

    var body: some View {
        if !approvals.requests.isEmpty {
            Section {
                ForEach(approvals.requests) { request in
                    ApprovalRow(request: request) { approvals.answer(request.id, $0) }
                }
            } header: {
                Text("Waiting for You")
            } footer: {
                Text("The first answer from this device or the Mac counts. A request nobody answers is denied.")
            }
        }
    }
}

private struct ApprovalRow: View {
    let request: RemoteApprovalRequest
    let onAnswer: (RemoteApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.title).font(.headline)
            ForEach(request.details, id: \.self) { Text($0).font(.subheadline) }
            if let body = request.body {
                Text(body)
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Expires \(request.expiresAt, style: .relative)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Deny", role: .destructive) { onAnswer(.deny) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Approve") { onAnswer(.approve) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
