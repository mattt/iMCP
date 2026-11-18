import Foundation
import OSLog
import Security

/// The status that iMCP reads over XPC, written by the helper's window as HomeKit loads.
final class HelperPublishedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var detail: String? = "Starting."

    func set(ready: Bool, detail: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.ready = ready
        self.detail = detail
    }

    var current: HomeXPCStatus {
        lock.lock()
        defer { lock.unlock() }
        return HomeXPCStatus(
            protocolVersion: HomeHelperIdentity.protocolVersion,
            homeKitReady: ready,
            detail: detail
        )
    }
}

/// Serves the Home tools over XPC to the iMCP that carries this helper.
///
/// launchd starts the helper when iMCP looks up its Mach service.
/// The listener accepts only a client that is iMCP's app, signed by the helper's own team,
/// so no other process can drive HomeKit through the helper.
/// A helper that has no team identifier, such as an unsigned build, refuses every client.
final class HelperXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let exported: HelperXPCService
    private let requirement: String?
    private let log = Logger.service("helper.xpc")

    init(backend: any HomeBackend, status: HelperPublishedStatus) throws {
        guard let helperIdentifier = Bundle.main.bundleIdentifier else {
            throw HomeError("iMCP Helper has no bundle identifier.")
        }
        let appIdentifier = HomeHelperIdentity.appBundleIdentifier(helperBundleIdentifier: helperIdentifier)
        listener = Self.makeListener(
            machServiceName: HomeHelperIdentity.machServiceName(appBundleIdentifier: appIdentifier)
        )
        exported = HelperXPCService(dispatcher: HomeToolDispatcher(backend: backend), status: status)
        requirement = HomeHelperIdentity.ownTeamIdentifier()
            .flatMap { HomeHelperIdentity.clientRequirement(helperBundleIdentifier: helperIdentifier, team: $0) }
            .flatMap { Self.isParseable($0) ? $0 : nil }
        super.init()
        listener.delegate = self
        if requirement == nil {
            log.error("iMCP Helper isn't signed with a team identifier, so it refuses every client.")
        }
    }

    func resume() { listener.resume() }

    // The Mac Catalyst SDK marks `NSXPCListener.init(machServiceName:)` and
    // `NSXPCConnection.setCodeSigningRequirement(_:)` unavailable,
    // although Foundation provides both in the same process at runtime,
    // so the helper calls them through the Objective-C runtime.
    private static func makeListener(machServiceName: String) -> NSXPCListener {
        let allocated = NSXPCListener.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        let initializer = NSSelectorFromString("initWithMachServiceName:")
        typealias Initializer = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
        let implementation = unsafeBitCast(allocated.method(for: initializer), to: Initializer.self)
        return implementation(allocated, initializer, machServiceName as NSString) as! NSXPCListener
    }

    private static func setCodeSigningRequirement(_ requirement: String, on connection: NSXPCConnection) {
        let setter = NSSelectorFromString("setCodeSigningRequirement:")
        precondition(connection.responds(to: setter), "NSXPCConnection can't set a code signing requirement.")
        _ = connection.perform(setter, with: requirement as NSString)
    }

    /// Whether Security accepts the requirement, which NSXPCConnection raises an exception for if not.
    private static func isParseable(_ requirement: String) -> Bool {
        var compiled: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        // Messages from a client that fails the requirement are refused, and the connection is invalidated.
        Self.setCodeSigningRequirement(requirement, on: connection)
        connection.exportedInterface = NSXPCInterface(with: HomeHelperXPC.self)
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}

final class HelperXPCService: NSObject, HomeHelperXPC, @unchecked Sendable {
    private let dispatcher: HomeToolDispatcher
    private let status: HelperPublishedStatus

    init(dispatcher: HomeToolDispatcher, status: HelperPublishedStatus) {
        self.dispatcher = dispatcher
        self.status = status
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        reply((try? JSONEncoder().encode(status.current)) ?? Data())
    }

    func callTool(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let dispatcher = dispatcher
        Task {
            let response = await dispatcher.perform(request)
            let data =
                (try? JSONEncoder().encode(response))
                ?? Data(#"{"error":"iMCP Helper couldn't encode its response."}"#.utf8)
            reply(data)
        }
    }
}
