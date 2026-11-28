import Darwin
import Foundation
import Security

// Trust of an MCP client by the code signature of the app that started `imcp-server`.
//
// `imcp-server` finds the client in its process tree,
// gathers facts about the client's signature,
// and sends them to the app in its hello as ``ClientEvidence``.
// The app has already checked `imcp-server`'s own signature,
// so it trusts the report,
// and it checks again what a sandboxed process can check itself:
// each forwarded audit token against a code requirement,
// and the process IDs that link `imcp-server` to the client.
// See ``ClientEvidenceCollector`` and ``ClientVerification``.
//
// The check removes the need for a pasted credential
// and shows a verified publisher in the approval dialog.
// It doesn't stop an unsandboxed process that runs as the same user:
// that process can run a trusted client, such as `claude`,
// with an MCP server of its choice,
// and the client then starts `imcp-server` as a valid child.
// So trusting a client by its signature trusts every such process
// that can run the client.
// A pasted credential doesn't stop that process either,
// because it can read the client's configuration file.

// MARK: - Audit tokens

/// An audit token, which names one instance of a process.
///
/// The token includes the process ID version,
/// so it can't refer to a later process that reuses the ID,
/// and the system refuses it after the process exits.
struct AuditToken: Hashable, Sendable {
    /// The token's 32 bytes.
    let data: Data

    init(_ token: audit_token_t) {
        data = withUnsafeBytes(of: token) { Data($0) }
    }

    /// Returns a token from its bytes, or `nil` if `data` isn't the size of a token.
    init?(data: Data) {
        guard data.count == MemoryLayout<audit_token_t>.size else { return nil }
        self.data = data
    }

    var value: audit_token_t {
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { data.copyBytes(to: $0) }
        return token
    }

    /// The process ID in the token.
    var processID: pid_t {
        LocalSocket.processID(of: value)
    }
}

extension AuditToken: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let data = Data(base64Encoded: try container.decode(String.self)), let token = Self(data: data) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an audit token")
        }
        self = token
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data.base64EncodedString())
    }
}

// MARK: - Evidence

/// What `imcp-server` reports about the app that started it.
///
/// The app reads this from the hello,
/// and checks it with ``ClientVerification/verify(_:serverProcessID:using:)``.
struct ClientEvidence: Codable, Equatable, Sendable {
    /// The client: the only process that holds the other ends of `imcp-server`'s stdin and stdout.
    var client: ProcessReport
    /// The process between the client and `imcp-server`, if there is one.
    ///
    /// When the client starts `imcp-server` through a helper,
    /// the helper is `imcp-server`'s parent and the client is the helper's parent.
    var launcher: ProcessReport?
}

/// The facts about one running process that the sandboxed app may not be able to read itself.
struct ProcessReport: Codable, Equatable, Sendable {
    /// The audit token of the process.
    var token: AuditToken
    /// The signing identifier, or `nil` if the process isn't signed.
    var identifier: String?
    /// The team identifier, or `nil` for ad hoc and Apple platform code.
    var team: String?
    /// The organization in the subject of the leaf certificate.
    var publisher: String?
    /// The dynamic code-signing status of the process, from the kernel.
    var status: UInt32
    /// Whether the signature has the `com.apple.security.get-task-allow` entitlement.
    var getTaskAllow: Bool
    /// Whether the signature has the `com.apple.security.cs.allow-dyld-environment-variables` entitlement.
    var allowsDYLDEnvironment: Bool
    /// Whether the bundle on disk passes a static validation of its resources and nested code,
    /// or `nil` if the code isn't a bundle.
    ///
    /// A changed resource leaves the code hash the same,
    /// so only a static validation finds it.
    /// The kernel checks the main executable's pages at run time,
    /// so a single executable has nothing more to validate.
    var isStaticallyValid: Bool?
    /// Whether the code is an application bundle, not a command-line tool.
    var isApplication: Bool
    /// The Electron fuses, or `nil` if the bundle doesn't contain Electron.
    var electron: ElectronFuses?
}

/// The Electron fuses that decide whether a signed Electron app can run other code.
///
/// Each value is `nil` if the fuse wire doesn't contain the fuse.
struct ElectronFuses: Codable, Equatable, Sendable {
    /// Whether `ELECTRON_RUN_AS_NODE` makes the app run any script as Node.js.
    var runAsNode: Bool?
    /// Whether Electron checks `app.asar` against the hash in the signed `Info.plist`.
    var embeddedAsarIntegrityValidation: Bool?
    /// Whether Electron loads the app only from `app.asar`.
    var onlyLoadAppFromAsar: Bool?

    /// The sentinel that precedes the fuse wire in the Electron Framework binary.
    static let sentinel = Data("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX".utf8)

    /// The path of the Electron Framework binary in an app bundle.
    static let frameworkPath = "Contents/Frameworks/Electron Framework.framework/Electron Framework"

    /// Reads the fuses from the bytes of an Electron Framework binary.
    ///
    /// The wire is the sentinel, a version byte, a length byte,
    /// and one byte for each fuse: `1` for on, `0` for off, and `r` for removed.
    ///
    /// - Returns: `nil` unless the binary has exactly one wire of a known version.
    static func read(from binary: Data) -> Self? {
        binary.withUnsafeBytes { buffer -> Self? in
            guard let base = buffer.baseAddress else { return nil }
            var offsets: [Int] = []
            var start = 0
            while offsets.count < 2, start < buffer.count,
                let match = sentinel.withUnsafeBytes({
                    memmem(base + start, buffer.count - start, $0.baseAddress, $0.count)
                })
            {
                let offset = base.distance(to: UnsafeRawPointer(match))
                offsets.append(offset)
                start = offset + 1
            }
            guard offsets.count == 1 else { return nil }

            let header = offsets[0] + sentinel.count
            guard header + 2 <= buffer.count, buffer[header] == 1 else { return nil }
            let count = Int(buffer[header + 1])
            guard header + 2 + count <= buffer.count else { return nil }
            func fuse(_ index: Int) -> Bool? {
                guard index < count else { return nil }
                switch buffer[header + 2 + index] {
                case UInt8(ascii: "1"): return true
                case UInt8(ascii: "0"): return false
                default: return nil
                }
            }
            return Self(runAsNode: fuse(0), embeddedAsarIntegrityValidation: fuse(4), onlyLoadAppFromAsar: fuse(5))
        }
    }
}

// MARK: - Policy

/// What a client must be for iMCP to trust it by its signature.
///
/// The app checks these rules on every connection, not only at approval.
enum ClientSignaturePolicy {
    /// Bits of the kernel's code-signing status word, from `<kern/cs_blobs.h>`.
    enum Status {
        static let valid: UInt32 = 0x0000_0001
        static let getTaskAllow: UInt32 = 0x0000_0004
        static let runtime: UInt32 = 0x0001_0000
        static let platformBinary: UInt32 = 0x0400_0000
        static let debugged: UInt32 = 0x1000_0000
    }

    /// Names of interpreters, shells, and launchers, which run whatever code they're given,
    /// so that their signatures identify only themselves.
    ///
    /// ``isDenied(identifier:)`` compares these with the last component of a signing identifier,
    /// without case and without a trailing version,
    /// so that `org.python.python3.13` and `com.apple.zsh` match too.
    static let deniedNames: Set<String> = [
        "bash", "bun", "csh", "dash", "deno", "env", "fish", "java", "ksh", "lua",
        "node", "nodejs", "nu", "osascript", "perl", "php", "pwsh", "python",
        "ruby", "sh", "tclsh", "tcsh", "wish", "xonsh", "zsh",
    ]

    /// Returns whether `identifier` names an interpreter, a shell, or a launcher.
    static func isDenied(identifier: String) -> Bool {
        let components = identifier.split(separator: ".")
        // A version such as the one in `python3.13` splits into its own component,
        // so check the last two components together as well.
        let candidates = [components.suffix(1), components.suffix(2)].map { $0.joined(separator: ".") }
        return candidates.contains { deniedNames.contains(baseName(of: $0)) }
    }

    /// Returns `name` in lowercase, without a trailing version such as `3`, `3.13`, or `-5.34`.
    private static func baseName(of name: String) -> String {
        var name = Substring(name.lowercased())
        while let last = name.last, last.isNumber || last == "." || last == "-" {
            name.removeLast()
        }
        return String(name)
    }

    /// A helper that a client uses to start an MCP server,
    /// and that iMCP looks past to find the client.
    struct KnownLauncher: Equatable, Sendable {
        var identifier: String
        var team: String

        var requirement: String {
            CodeRequirement.signed(identifier: identifier, team: team)
        }
    }

    /// The helpers that iMCP looks past.
    ///
    /// iMCP looks past one helper at most,
    /// only when the helper and the client have the same team,
    /// and never past an unknown helper or a platform binary.
    static let knownLaunchers: [KnownLauncher] = [
        // Claude.app starts each stdio server through `Contents/Helpers/disclaimer`.
        KnownLauncher(identifier: "disclaimer", team: "Q6L2SF6YDW")
    ]

    /// The longest identifier or publisher that iMCP accepts, in UTF-8 bytes.
    static let maximumFieldLength = 128

    /// Returns whether `value` can be quoted in a code requirement and shown in the approval dialog.
    static func isSafeField(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumFieldLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                return false
            default:
                return scalar != "\"" && scalar != "\\"
            }
        }
    }

    /// Returns why a process fails the rules for its signature, or `nil` if it passes.
    ///
    /// - Parameter status: The dynamic status word to check,
    ///   which the app reads itself when it can.
    static func failure(of report: ProcessReport, status: UInt32) -> ClientSignatureFailure? {
        guard status & Status.valid != 0, report.isStaticallyValid != false else {
            return .invalidSignature
        }
        guard status & Status.platformBinary == 0 else { return .platformBinary }
        guard status & Status.runtime != 0 else { return .notHardened }
        guard status & (Status.getTaskAllow | Status.debugged) == 0, !report.getTaskAllow else {
            return .debuggable
        }
        guard !report.allowsDYLDEnvironment else { return .allowsDYLDEnvironment }
        if let identifier = report.identifier, isDenied(identifier: identifier) {
            return .runsOtherCode
        }
        if let electron = report.electron {
            guard electron.runAsNode == false,
                electron.embeddedAsarIntegrityValidation == true,
                electron.onlyLoadAppFromAsar == true
            else { return .electronFuses }
        }
        return nil
    }
}

// MARK: - Verification

/// The signing identity that iMCP trusts a client by.
///
/// The identity has no path or code hash,
/// so it stays the same when the client updates.
struct ClientSignature: Codable, Hashable, Sendable {
    /// The signing identifier, such as `com.anthropic.claude-code`.
    var identifier: String
    /// The team identifier, from the leaf certificate's organizational unit.
    var team: String
    /// The organization in the subject of the leaf certificate, if it has one.
    var publisher: String?

    /// The requirement that code with this identity satisfies:
    /// a certificate that Apple issued, the identifier, and the team.
    var requirement: String {
        CodeRequirement.signed(identifier: identifier, team: team)
    }

    /// The publisher and team, for display.
    var publisherDescription: String {
        publisher.map { "\($0) (\(team))" } ?? "team \(team)"
    }
}

/// A client whose signature iMCP verified.
struct VerifiedClient: Hashable, Sendable {
    var signature: ClientSignature
    /// The signing identifier of the helper that started `imcp-server`, if any.
    var launcherIdentifier: String?
    /// Whether the client is an application bundle.
    /// A command-line tool runs for whatever process starts it.
    var isApplication: Bool
}

/// Why iMCP doesn't trust a client by its signature.
enum ClientSignatureFailure: Equatable, Sendable {
    /// The process tree doesn't match what `imcp-server` reported.
    case processTree
    /// The signature isn't valid, or Apple didn't issue its certificate to a team.
    case invalidSignature
    /// The client is part of macOS.
    case platformBinary
    /// The client doesn't use the hardened runtime.
    case notHardened
    /// The client allows debugging.
    case debuggable
    /// The client loads libraries named in its environment.
    case allowsDYLDEnvironment
    /// The client is an interpreter, a shell, or a launcher.
    case runsOtherCode
    /// The client is an Electron app whose fuses let it run other code.
    case electronFuses
    /// `imcp-server` was started through a helper that iMCP doesn't know.
    case unknownLauncher
    /// The helper that started `imcp-server` has a different team from the client.
    case launcherTeam

    /// One line for the approval dialog.
    var message: String {
        switch self {
        case .processTree:
            return "iMCP can't confirm which app started this connection."
        case .invalidSignature:
            return "iMCP can't verify this app's signature."
        case .platformBinary:
            return "iMCP doesn't trust parts of macOS by their signature."
        case .notHardened, .debuggable, .allowsDYLDEnvironment:
            return "This app's signature lets other code change it."
        case .runsOtherCode:
            return "This app runs scripts or other programs, so its signature doesn't identify the client."
        case .electronFuses:
            return "This app's settings let it run scripts that it doesn't contain."
        case .unknownLauncher, .launcherTeam:
            return "iMCP doesn't recognize the helper that started this connection."
        }
    }
}

/// The checks that the app runs itself on a process that `imcp-server` reported.
protocol CodeVerifying {
    /// Returns the parent process ID of `pid`, or `nil` if it can't be read.
    func parentProcessID(of pid: pid_t) -> pid_t?
    /// Returns whether the running process with `token` satisfies `requirement`.
    func satisfies(_ token: AuditToken, requirement: String) -> Bool
    /// Returns the dynamic code-signing status of the process with `token`,
    /// or `nil` if it can't be read.
    func dynamicStatus(of token: AuditToken) -> UInt32?
}

/// What iMCP knows about the signature of the client on a connection.
enum ClientVerification: Hashable, Sendable {
    /// The client passed every check.
    case verified(VerifiedClient)
    /// `imcp-server` identified the client, but the client fails a check.
    case failed(ClientSignatureFailure)
    /// `imcp-server` didn't identify the client,
    /// for example because it runs in a terminal or under an interpreter.
    case unidentified

    var verifiedClient: VerifiedClient? {
        if case .verified(let client) = self { return client }
        return nil
    }

    /// Checks the evidence that `imcp-server` sent.
    ///
    /// - Parameters:
    ///   - evidence: The evidence from the hello.
    ///   - serverProcessID: The process ID of `imcp-server`, from the socket's audit token.
    ///   - verifier: The checks that the app runs itself.
    static func verify(
        _ evidence: ClientEvidence?,
        serverProcessID: pid_t,
        using verifier: some CodeVerifying
    ) -> Self {
        guard let evidence else { return .unidentified }

        // The process tree links `imcp-server` to the client, through one helper at most.
        // A process that exits leaves its children to launchd,
        // so the parents that the app reads now are the processes that the tokens name.
        let client = evidence.client
        let serverParent = verifier.parentProcessID(of: serverProcessID)
        if let launcher = evidence.launcher {
            guard serverParent == launcher.token.processID,
                verifier.parentProcessID(of: launcher.token.processID) == client.token.processID
            else { return .failed(.processTree) }
        } else {
            guard serverParent == client.token.processID else { return .failed(.processTree) }
        }

        guard let signature = verifiedSignature(of: client, using: verifier) else {
            return .failed(.invalidSignature)
        }
        let clientStatus = verifier.dynamicStatus(of: client.token) ?? client.status
        if let failure = ClientSignaturePolicy.failure(of: client, status: clientStatus) {
            return .failed(failure)
        }

        if let launcher = evidence.launcher {
            guard
                let known = ClientSignaturePolicy.knownLaunchers.first(where: {
                    launcher.identifier == $0.identifier
                        && verifier.satisfies(launcher.token, requirement: $0.requirement)
                })
            else { return .failed(.unknownLauncher) }
            guard known.team == signature.team else { return .failed(.launcherTeam) }
            let launcherStatus = verifier.dynamicStatus(of: launcher.token) ?? launcher.status
            if ClientSignaturePolicy.failure(of: launcher, status: launcherStatus) != nil {
                return .failed(.unknownLauncher)
            }
        }

        return .verified(
            VerifiedClient(
                signature: signature,
                launcherIdentifier: evidence.launcher?.identifier,
                isApplication: client.isApplication
            )
        )
    }

    /// Returns the identity in `report`, after the app checks it against the running process.
    ///
    /// The requirement pins Apple's certificate, the identifier, the team,
    /// and the publisher that the dialog shows.
    private static func verifiedSignature(of report: ProcessReport, using verifier: some CodeVerifying)
        -> ClientSignature?
    {
        guard let identifier = report.identifier, ClientSignaturePolicy.isSafeField(identifier),
            let team = report.team, ClientSignaturePolicy.isSafeField(team)
        else { return nil }
        let publisher = report.publisher.flatMap { ClientSignaturePolicy.isSafeField($0) ? $0 : nil }
        let signature = ClientSignature(identifier: identifier, team: team, publisher: publisher)

        var requirement = signature.requirement
        if let publisher {
            requirement += #" and certificate leaf[subject.O] = "\#(publisher)""#
        }
        guard verifier.satisfies(report.token, requirement: requirement) else { return nil }
        return signature
    }
}

/// Runs the app's checks with the system's code-signing services.
///
/// It validates each token against the kernel's copy of the code signature,
/// which a sandboxed process can do for a process outside its container.
struct SystemCodeVerifier: CodeVerifying {
    func parentProcessID(of pid: pid_t) -> pid_t? {
        ProcessInspection.parentProcessID(of: pid)
    }

    func satisfies(_ token: AuditToken, requirement: String) -> Bool {
        (try? CodeRequirement.check(auditToken: token.value, against: requirement, usesDynamicCode: true)) != nil
    }

    func dynamicStatus(of token: AuditToken) -> UInt32? {
        guard let code = ProcessInspection.code(for: token, usesDynamicCode: true) else { return nil }
        let information = ProcessInspection.signingInformation(of: code, flags: kSecCSDynamicInformation)
        return (information?[kSecCodeInfoStatus] as? NSNumber)?.uint32Value
    }
}

// MARK: - Collection

/// The parts of a process's standard input or output that identify its other end.
enum StreamEndpoint: Equatable, Sendable {
    /// A connected Unix domain socket.
    case socket(LocalSocket.SocketIdentity)
    /// A pipe, identified by the kernel's handles for this end and the other end.
    case pipe(handle: UInt64, peer: UInt64)
    /// Something without another end that iMCP can find, such as a file or a terminal.
    case unsupported(String)
}

/// The process inspection that `imcp-server` needs to find its client.
///
/// A protocol, so that tests can check the decisions without real processes.
protocol ProcessInspecting {
    /// The parent of this process.
    func currentParentProcessID() -> pid_t
    /// Returns the parent process ID of `pid`, or `nil` if it can't be read.
    func parentProcessID(of pid: pid_t) -> pid_t?
    /// Returns the audit token of `pid`, or `nil` if it can't be read.
    func auditToken(of pid: pid_t) -> AuditToken?
    /// Describes this process's descriptor `descriptor`.
    func standardStream(_ descriptor: Int32) -> StreamEndpoint
    /// Returns every process of the user, including this one,
    /// that has the other end of `endpoint` open,
    /// or `nil` if the processes can't be listed.
    func processesHoldingPeer(of endpoint: StreamEndpoint) -> Set<pid_t>?
    /// Returns the facts about the signature of the running process with `token`.
    func report(for token: AuditToken) -> ProcessReport?
}

/// Finds the client that started `imcp-server`, and gathers ``ClientEvidence`` about it.
enum ClientEvidenceCollector {
    /// Why `imcp-server` sends no evidence.
    enum Unavailable: Error, Equatable, CustomStringConvertible {
        /// launchd is the parent, so the process that started `imcp-server` has exited.
        case noParent
        /// The parent changed or exited while `imcp-server` inspected it.
        case parentChanged
        /// Standard input or output isn't a pipe or a Unix domain socket.
        case unsupportedStream(descriptor: Int32, kind: String)
        /// The processes of the user couldn't be listed.
        case processesUnavailable
        /// Not exactly one process holds the other ends of both standard input and output.
        case holders(input: Int, output: Int, same: Bool)
        /// The process that holds the other ends is neither the parent nor the grandparent.
        case holderOutsideTree
        /// The client's signature couldn't be read.
        case signatureUnavailable

        var description: String {
            switch self {
            case .noParent:
                return "the process that started imcp-server has exited"
            case .parentChanged:
                return "the process that started imcp-server changed"
            case .unsupportedStream(let descriptor, let kind):
                return "\(descriptor == STDIN_FILENO ? "stdin" : "stdout") is \(kind)"
            case .processesUnavailable:
                return "the processes couldn't be listed"
            case .holders(let input, let output, let same):
                if input == 1, output == 1, !same {
                    return "different processes hold the other ends of stdin and stdout"
                }
                return "\(input) process(es) hold the other end of stdin and \(output) hold the other end of stdout"
            case .holderOutsideTree:
                return "the process that holds the other end of stdio didn't start imcp-server"
            case .signatureUnavailable:
                return "the client's signature couldn't be read"
            }
        }
    }

    /// Finds the client and gathers the evidence about it.
    ///
    /// The client is the only process that holds the other ends of stdin and stdout.
    /// It must be the parent of `imcp-server`,
    /// or the parent of the parent, which is then a launcher.
    static func collect(using inspector: some ProcessInspecting) -> Result<ClientEvidence, Unavailable> {
        let parent = inspector.currentParentProcessID()
        guard parent > 1 else { return .failure(.noParent) }
        guard let parentToken = inspector.auditToken(of: parent) else { return .failure(.parentChanged) }
        // A parent that exits leaves this process to launchd,
        // so an unchanged parent ID means that the token names the parent.
        guard inspector.currentParentProcessID() == parent else { return .failure(.parentChanged) }

        var holders: [Set<pid_t>] = []
        for descriptor in [STDIN_FILENO, STDOUT_FILENO] {
            let endpoint = inspector.standardStream(descriptor)
            if case .unsupported(let kind) = endpoint {
                return .failure(.unsupportedStream(descriptor: descriptor, kind: kind))
            }
            guard let found = inspector.processesHoldingPeer(of: endpoint) else {
                return .failure(.processesUnavailable)
            }
            holders.append(found)
        }
        guard holders[0].count == 1, holders[0] == holders[1], let holder = holders[0].first else {
            return .failure(.holders(input: holders[0].count, output: holders[1].count, same: holders[0] == holders[1]))
        }

        let clientToken: AuditToken
        var launcherToken: AuditToken?
        if holder == parent {
            clientToken = parentToken
        } else if inspector.parentProcessID(of: parent) == holder {
            guard let holderToken = inspector.auditToken(of: holder) else { return .failure(.parentChanged) }
            // Confirm that the launcher still runs and that its parent is still the holder,
            // so that the holder's token names the launcher's parent.
            guard inspector.parentProcessID(of: parent) == holder,
                inspector.auditToken(of: parent) == parentToken
            else { return .failure(.parentChanged) }
            clientToken = holderToken
            launcherToken = parentToken
        } else {
            return .failure(.holderOutsideTree)
        }
        guard inspector.currentParentProcessID() == parent else { return .failure(.parentChanged) }

        guard let client = inspector.report(for: clientToken) else { return .failure(.signatureUnavailable) }
        var launcher: ProcessReport?
        if let launcherToken {
            guard let report = inspector.report(for: launcherToken) else { return .failure(.signatureUnavailable) }
            launcher = report
        }
        return .success(ClientEvidence(client: client, launcher: launcher))
    }
}

// MARK: - System inspection

/// Process inspection with `libproc`, Mach, and the code-signing services.
///
/// `imcp-server` runs without App Sandbox, so it can list other processes' descriptors
/// and read their signatures from disk.
/// `task_name_for_pid` and `proc_pidinfo` have public headers but no Apple documentation.
struct SystemProcessInspector: ProcessInspecting {
    func currentParentProcessID() -> pid_t {
        getppid()
    }

    func parentProcessID(of pid: pid_t) -> pid_t? {
        ProcessInspection.parentProcessID(of: pid)
    }

    func auditToken(of pid: pid_t) -> AuditToken? {
        // A task name port allows only inspection, and needs no entitlement for the user's own processes.
        var name = mach_port_name_t(MACH_PORT_NULL)
        guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, name) }

        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let result = AuditToken(token)
        return result.processID == pid ? result : nil
    }

    func standardStream(_ descriptor: Int32) -> StreamEndpoint {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return .unsupported("closed") }
        switch status.st_mode & S_IFMT {
        case S_IFSOCK:
            guard let identity = LocalSocket.socketIdentity(process: getpid(), descriptor: descriptor),
                identity.peer != 0
            else { return .unsupported("a socket that isn't a connected Unix domain socket") }
            return .socket(identity)
        case S_IFIFO:
            guard let pipe = ProcessInspection.pipeHandles(process: getpid(), descriptor: descriptor),
                pipe.peer != 0
            else { return .unsupported("a named pipe or a closed pipe") }
            return .pipe(handle: pipe.handle, peer: pipe.peer)
        case S_IFCHR:
            return .unsupported(isatty(descriptor) == 1 ? "a terminal" : "a device")
        case S_IFREG:
            return .unsupported("a file")
        default:
            return .unsupported("an unsupported kind of file")
        }
    }

    func processesHoldingPeer(of endpoint: StreamEndpoint) -> Set<pid_t>? {
        guard let processes = ProcessInspection.userProcessIDs() else { return nil }
        var holders = Set<pid_t>()
        for pid in processes {
            // A process that exits or that this process can't inspect has no descriptors to compare.
            guard let descriptors = try? LocalSocket.descriptors(process: pid) else { continue }
            let holds = descriptors.contains { descriptor in
                switch endpoint {
                case .socket(let own):
                    return descriptor.proc_fdtype == PROX_FDTYPE_SOCKET
                        && LocalSocket.socketIdentity(process: pid, descriptor: descriptor.proc_fd)
                            == LocalSocket.SocketIdentity(socket: own.peer, peer: own.socket)
                case .pipe(_, let peer):
                    return descriptor.proc_fdtype == PROX_FDTYPE_PIPE
                        && ProcessInspection.pipeHandles(process: pid, descriptor: descriptor.proc_fd)?.handle == peer
                case .unsupported:
                    return false
                }
            }
            if holds { holders.insert(pid) }
        }
        return holders
    }

    func report(for token: AuditToken) -> ProcessReport? {
        guard let code = ProcessInspection.code(for: token, usesDynamicCode: false),
            let information = ProcessInspection.signingInformation(
                of: code,
                flags: kSecCSSigningInformation | kSecCSRequirementInformation | kSecCSDynamicInformation
            )
        else { return nil }

        let isValid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        let entitlements = information[kSecCodeInfoEntitlementsDict] as? [String: Any] ?? [:]
        let certificates = information[kSecCodeInfoCertificates] as? [SecCertificate] ?? []
        var report = ProcessReport(
            token: token,
            identifier: information[kSecCodeInfoIdentifier] as? String,
            team: information[kSecCodeInfoTeamIdentifier] as? String,
            publisher: certificates.first.flatMap(ProcessInspection.organization(of:)),
            status: isValid ? (information[kSecCodeInfoStatus] as? NSNumber)?.uint32Value ?? 0 : 0,
            getTaskAllow: entitlements["com.apple.security.get-task-allow"] as? Bool == true,
            allowsDYLDEnvironment: entitlements["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool
                == true,
            isStaticallyValid: nil,
            isApplication: false,
            electron: nil
        )

        var staticCode: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let url = path as URL?
        else {
            report.isStaticallyValid = false
            return report
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            report.isApplication = url.pathExtension == "app"
            report.isStaticallyValid = ProcessInspection.bundleIsValid(staticCode, runningCode: information)
            let framework = url.appendingPathComponent(ElectronFuses.frameworkPath)
            if FileManager.default.fileExists(atPath: framework.path) {
                let binary = try? Data(contentsOf: framework, options: .alwaysMapped)
                report.electron = binary.flatMap(ElectronFuses.read(from:)) ?? ElectronFuses()
            }
        }
        return report
    }
}

/// System calls that both `imcp-server` and the app use to inspect processes.
enum ProcessInspection {
    /// Returns the parent process ID of `pid`, or `nil` if it can't be read.
    static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbsi_ppid)
    }

    /// Returns the kernel's handles for the pipe that `pid` has open as `descriptor`
    /// and for the pipe's other end.
    static func pipeHandles(process pid: pid_t, descriptor: Int32) -> (handle: UInt64, peer: UInt64)? {
        var info = pipe_fdinfo()
        let size = Int32(MemoryLayout<pipe_fdinfo>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDPIPEINFO, &info, size) == size else { return nil }
        return (info.pipeinfo.pipe_handle, info.pipeinfo.pipe_peerhandle)
    }

    /// Returns the IDs of the processes whose effective user is this process's user.
    static func userProcessIDs() -> [pid_t]? {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return nil }
        // Leave room for processes that start in the meantime.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return nil }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    /// Returns the code object for the running process with `token`.
    ///
    /// - Parameter usesDynamicCode: Whether to use the kernel's copy of the code signature,
    ///   which a sandboxed caller needs for a process outside its container.
    static func code(for token: AuditToken, usesDynamicCode: Bool) -> SecCode? {
        var attributes: [CFString: Any] = [kSecGuestAttributeAudit: token.data]
        if usesDynamicCode {
            attributes[kSecGuestAttributeDynamicCode] = true
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    /// Returns the signing information of running code.
    static func signingInformation(of code: SecCode, flags: UInt32) -> [CFString: Any]? {
        var information: CFDictionary?
        // `SecCodeCopySigningInformation` takes a running code object where it takes a static one,
        // and only a running one has dynamic information.
        let status = SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self),
            SecCSFlags(rawValue: flags),
            &information
        )
        guard status == errSecSuccess else { return nil }
        return information as? [CFString: Any]
    }

    /// Returns whether a bundle's resources and nested code on disk pass a strict validation,
    /// and whether the bundle is the code that runs.
    ///
    /// The kernel checks the main executable's pages at run time,
    /// so this skips the executable.
    /// For Claude.app, the validation took about 0.1 seconds;
    /// hashing a 330 MB executable, as for Claude Code, took about 0.6 seconds.
    static func bundleIsValid(_ staticCode: SecStaticCode, runningCode: [CFString: Any]) -> Bool {
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else { return false }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
            let unique = (information as? [CFString: Any])?[kSecCodeInfoUnique] as? Data
        else { return false }
        return unique == runningCode[kSecCodeInfoUnique] as? Data
    }

    /// Returns the organization in the subject of `certificate`.
    static func organization(of certificate: SecCertificate) -> String? {
        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any],
            let subject = values[kSecOIDX509V1SubjectName] as? [CFString: Any],
            let fields = subject[kSecPropertyKeyValue] as? [[CFString: Any]]
        else { return nil }
        let organization = fields.first { ($0[kSecPropertyKeyLabel] as? String) == (kSecOIDOrganizationName as String) }
        return organization?[kSecPropertyKeyValue] as? String
    }
}
