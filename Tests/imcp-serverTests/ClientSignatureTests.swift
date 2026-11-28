import Darwin
import Foundation
import XCTest

/// Tests for finding the client that started `imcp-server`
/// and for the checks on the client's signature.
///
/// The decisions run against fake processes.
/// The system calls run against this test process and children that it starts,
/// never against installed applications.
final class ClientSignatureTests: XCTestCase {
    // MARK: - Fixtures

    private static let team = "Q6L2SF6YDW"
    private static let otherTeam = "ABCDE12345"

    private static func token(_ pid: pid_t, version: UInt32 = 1) -> AuditToken {
        var token = audit_token_t()
        token.val.5 = UInt32(bitPattern: pid)
        token.val.7 = version
        return AuditToken(token)
    }

    /// A report for a process that passes every check.
    private static func report(
        _ pid: pid_t,
        identifier: String = "com.anthropic.claude-code",
        team: String? = ClientSignatureTests.team,
        isApplication: Bool = false
    ) -> ProcessReport {
        ProcessReport(
            token: token(pid),
            identifier: identifier,
            team: team,
            publisher: "Anthropic PBC",
            status: ClientSignaturePolicy.Status.valid | ClientSignaturePolicy.Status.runtime,
            getTaskAllow: false,
            allowsDYLDEnvironment: false,
            isStaticallyValid: isApplication ? true : nil,
            isApplication: isApplication,
            electron: nil
        )
    }

    private static let claudeApp = "com.anthropic.claudefordesktop"

    private static let passingFuses = ElectronFuses(
        runAsNode: false,
        embeddedAsarIntegrityValidation: true,
        onlyLoadAppFromAsar: true
    )

    /// Fake processes for ``ClientEvidenceCollector``.
    private struct FakeInspector: ProcessInspecting {
        var parent: pid_t = 100
        var parents: [pid_t: pid_t] = [100: 50, 50: 1]
        var tokens: [pid_t: AuditToken] = [100: token(100), 50: token(50)]
        var streams: [Int32: StreamEndpoint] = [
            STDIN_FILENO: .socket(.init(socket: 1, peer: 2)),
            STDOUT_FILENO: .socket(.init(socket: 3, peer: 4)),
        ]
        var holders: [Int32: Set<pid_t>] = [STDIN_FILENO: [100], STDOUT_FILENO: [100]]
        /// Changes the parent after the first read, as if the parent exited.
        var parentExitsAfterFirstRead = false
        private let reads = Counter()

        final class Counter {
            var value = 0
        }

        func currentParentProcessID() -> pid_t {
            reads.value += 1
            return parentExitsAfterFirstRead && reads.value > 1 ? 1 : parent
        }

        func parentProcessID(of pid: pid_t) -> pid_t? { parents[pid] }

        func auditToken(of pid: pid_t) -> AuditToken? { tokens[pid] }

        func standardStream(_ descriptor: Int32) -> StreamEndpoint {
            streams[descriptor] ?? .unsupported("closed")
        }

        func processesHoldingPeer(of endpoint: StreamEndpoint) -> Set<pid_t>? {
            guard let descriptor = streams.first(where: { $0.value == endpoint })?.key else { return nil }
            return holders[descriptor]
        }

        func report(for token: AuditToken) -> ProcessReport? {
            ClientSignatureTests.report(token.processID).with { $0.token = token }
        }
    }

    /// The app's checks against fake processes.
    private struct FakeVerifier: CodeVerifying {
        /// The real signing facts of each process.
        var signatures: [AuditToken: ClientSignature]
        var parents: [pid_t: pid_t]
        var statuses: [AuditToken: UInt32] = [:]

        func parentProcessID(of pid: pid_t) -> pid_t? { parents[pid] }

        func satisfies(_ token: AuditToken, requirement: String) -> Bool {
            guard let signature = signatures[token] else { return false }
            var expected = CodeRequirement.signed(identifier: signature.identifier, team: signature.team)
            if requirement.contains("subject.O]"), let publisher = signature.publisher {
                expected += #" and certificate leaf[subject.O] = "\#(publisher)""#
            }
            return requirement == expected
        }

        func dynamicStatus(of token: AuditToken) -> UInt32? { statuses[token] }
    }

    /// Evidence for Claude Code as the direct parent of `imcp-server`, process 300.
    private func directEvidence(
        identifier: String = "com.anthropic.claude-code",
        change: (inout ProcessReport) -> Void = { _ in }
    ) -> (ClientEvidence, FakeVerifier) {
        var client = Self.report(200, identifier: identifier)
        change(&client)
        let verifier = FakeVerifier(
            signatures: [
                client.token: ClientSignature(
                    identifier: client.identifier ?? "",
                    team: client.team ?? "",
                    publisher: "Anthropic PBC"
                )
            ],
            parents: [300: 200]
        )
        return (ClientEvidence(client: client), verifier)
    }

    /// Evidence for Claude.app, process 200, starting `imcp-server`, process 300,
    /// through its helper, process 250.
    private func launcherEvidence(
        launcherIdentifier: String = "disclaimer",
        launcherTeam: String = ClientSignatureTests.team,
        clientTeam: String = ClientSignatureTests.team
    ) -> (ClientEvidence, FakeVerifier) {
        var client = Self.report(200, identifier: Self.claudeApp, team: clientTeam, isApplication: true)
        client.electron = Self.passingFuses
        let launcher = Self.report(250, identifier: launcherIdentifier, team: launcherTeam)
        let verifier = FakeVerifier(
            signatures: [
                client.token: ClientSignature(identifier: Self.claudeApp, team: clientTeam, publisher: "Anthropic PBC"),
                launcher.token: ClientSignature(
                    identifier: launcherIdentifier,
                    team: launcherTeam,
                    publisher: "Anthropic PBC"
                ),
            ],
            parents: [300: 250, 250: 200]
        )
        return (ClientEvidence(client: client, launcher: launcher), verifier)
    }

    // MARK: - Collection

    func testCollectsDirectParentThatHoldsStdio() throws {
        let evidence = try ClientEvidenceCollector.collect(using: FakeInspector()).get()
        XCTAssertEqual(evidence.client.token, Self.token(100))
        XCTAssertNil(evidence.launcher)
    }

    func testCollectsGrandparentThroughLauncher() throws {
        var inspector = FakeInspector()
        inspector.holders = [STDIN_FILENO: [50], STDOUT_FILENO: [50]]

        let evidence = try ClientEvidenceCollector.collect(using: inspector).get()
        XCTAssertEqual(evidence.client.token, Self.token(50))
        XCTAssertEqual(evidence.launcher?.token, Self.token(100))
    }

    func testRefusesTwoLauncherLevels() {
        var inspector = FakeInspector()
        inspector.parents = [100: 50, 50: 20, 20: 1]
        inspector.tokens[20] = Self.token(20)
        inspector.holders = [STDIN_FILENO: [20], STDOUT_FILENO: [20]]

        XCTAssertEqual(ClientEvidenceCollector.collect(using: inspector), .failure(.holderOutsideTree))
    }

    func testRefusesHolderThatIsNotParent() {
        var inspector = FakeInspector()
        inspector.tokens[77] = Self.token(77)
        inspector.holders = [STDIN_FILENO: [77], STDOUT_FILENO: [77]]

        XCTAssertEqual(ClientEvidenceCollector.collect(using: inspector), .failure(.holderOutsideTree))
    }

    func testRefusesMoreThanOneHolder() {
        var inspector = FakeInspector()
        inspector.holders = [STDIN_FILENO: [100, 77], STDOUT_FILENO: [100]]

        XCTAssertEqual(
            ClientEvidenceCollector.collect(using: inspector),
            .failure(.holders(input: 2, output: 1, same: false))
        )
    }

    func testRefusesNoHolder() {
        var inspector = FakeInspector()
        inspector.holders = [STDIN_FILENO: [], STDOUT_FILENO: []]

        XCTAssertEqual(
            ClientEvidenceCollector.collect(using: inspector),
            .failure(.holders(input: 0, output: 0, same: true))
        )
    }

    func testRefusesDifferentHoldersOfStdinAndStdout() {
        var inspector = FakeInspector()
        inspector.holders = [STDIN_FILENO: [100], STDOUT_FILENO: [50]]

        XCTAssertEqual(
            ClientEvidenceCollector.collect(using: inspector),
            .failure(.holders(input: 1, output: 1, same: false))
        )
    }

    func testRefusesFilesAndTerminals() {
        for kind in ["a file", "a terminal", "a named pipe or a closed pipe"] {
            var inspector = FakeInspector()
            inspector.streams[STDOUT_FILENO] = .unsupported(kind)
            XCTAssertEqual(
                ClientEvidenceCollector.collect(using: inspector),
                .failure(.unsupportedStream(descriptor: STDOUT_FILENO, kind: kind))
            )
        }
    }

    func testAcceptsPipes() throws {
        var inspector = FakeInspector()
        inspector.streams = [
            STDIN_FILENO: .pipe(handle: 1, peer: 2),
            STDOUT_FILENO: .pipe(handle: 3, peer: 4),
        ]
        XCTAssertNoThrow(try ClientEvidenceCollector.collect(using: inspector).get())
    }

    func testRefusesLaunchdAsParent() {
        var inspector = FakeInspector()
        inspector.parent = 1
        XCTAssertEqual(ClientEvidenceCollector.collect(using: inspector), .failure(.noParent))
    }

    func testRefusesParentThatExits() {
        var inspector = FakeInspector()
        inspector.parentExitsAfterFirstRead = true
        XCTAssertEqual(ClientEvidenceCollector.collect(using: inspector), .failure(.parentChanged))
    }

    // MARK: - Verification

    func testVerifiesDirectParent() {
        let (evidence, verifier) = directEvidence()
        let verification = ClientVerification.verify(evidence, serverProcessID: 300, using: verifier)

        XCTAssertEqual(
            verification,
            .verified(
                VerifiedClient(
                    signature: ClientSignature(
                        identifier: "com.anthropic.claude-code",
                        team: Self.team,
                        publisher: "Anthropic PBC"
                    ),
                    launcherIdentifier: nil,
                    isApplication: false
                )
            )
        )
    }

    func testVerifiesClientThroughKnownLauncher() {
        let (evidence, verifier) = launcherEvidence()
        let verification = ClientVerification.verify(evidence, serverProcessID: 300, using: verifier)

        XCTAssertEqual(verification.verifiedClient?.signature.identifier, Self.claudeApp)
        XCTAssertEqual(verification.verifiedClient?.launcherIdentifier, "disclaimer")
        XCTAssertEqual(verification.verifiedClient?.isApplication, true)
    }

    func testRefusesLauncherWithDifferentTeam() {
        let (evidence, verifier) = launcherEvidence(launcherTeam: Self.otherTeam)
        XCTAssertEqual(
            ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
            .failed(.unknownLauncher)
        )

        // A launcher that matches the table, with a client from another team.
        let (other, otherVerifier) = launcherEvidence(clientTeam: Self.otherTeam)
        XCTAssertEqual(
            ClientVerification.verify(other, serverProcessID: 300, using: otherVerifier),
            .failed(.launcherTeam)
        )
    }

    func testRefusesUnknownHelper() {
        let (evidence, verifier) = launcherEvidence(launcherIdentifier: "com.example.helper")
        XCTAssertEqual(
            ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
            .failed(.unknownLauncher)
        )
    }

    func testRefusesPlatformBinaryAsLauncher() {
        let (base, verifier) = launcherEvidence()
        var evidence = base
        evidence.launcher?.status |= ClientSignaturePolicy.Status.platformBinary
        XCTAssertEqual(
            ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
            .failed(.unknownLauncher)
        )
    }

    func testRefusesProcessTreeThatDiffersFromReport() {
        // `imcp-server`'s parent isn't the reported client.
        let (direct, directBase) = directEvidence()
        var directVerifier = directBase
        directVerifier.parents = [300: 999]
        XCTAssertEqual(
            ClientVerification.verify(direct, serverProcessID: 300, using: directVerifier),
            .failed(.processTree)
        )

        // The launcher's parent isn't the reported client.
        let (launched, launchedBase) = launcherEvidence()
        var launchedVerifier = launchedBase
        launchedVerifier.parents[250] = 999
        XCTAssertEqual(
            ClientVerification.verify(launched, serverProcessID: 300, using: launchedVerifier),
            .failed(.processTree)
        )

        // A report of a launcher where `imcp-server` is the client's direct child.
        launchedVerifier.parents = [300: 200]
        XCTAssertEqual(
            ClientVerification.verify(launched, serverProcessID: 300, using: launchedVerifier),
            .failed(.processTree)
        )
    }

    func testRefusesReportThatDiffersFromRunningCode() {
        // `imcp-server` reports another identifier than the one that the process has.
        var (evidence, verifier) = directEvidence()
        evidence.client.identifier = "com.anthropic.claudefordesktop"
        XCTAssertEqual(
            ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
            .failed(.invalidSignature)
        )

        // The publisher is part of the requirement too.
        (evidence, verifier) = directEvidence()
        evidence.client.publisher = "Someone Else"
        XCTAssertEqual(
            ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
            .failed(.invalidSignature)
        )
    }

    func testRefusesUnsignedAndUnsafeFields() {
        for change: (inout ProcessReport) -> Void in [
            { $0.team = nil },
            { $0.identifier = nil },
            { $0.identifier = #"com.anthropic.claude-code" or identifier "x"# },
            { $0.identifier = "com.anthropic.claude-code\u{202E}" },
        ] {
            let (evidence, verifier) = directEvidence(change: change)
            XCTAssertEqual(
                ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
                .failed(.invalidSignature)
            )
        }
    }

    func testEachRuleOfTheBar() {
        let cases: [(ClientSignatureFailure, (inout ProcessReport) -> Void)] = [
            (.invalidSignature, { $0.status &= ~ClientSignaturePolicy.Status.valid }),
            (.invalidSignature, { $0.isStaticallyValid = false }),
            (.notHardened, { $0.status &= ~ClientSignaturePolicy.Status.runtime }),
            (.debuggable, { $0.getTaskAllow = true }),
            (.debuggable, { $0.status |= ClientSignaturePolicy.Status.getTaskAllow }),
            (.debuggable, { $0.status |= ClientSignaturePolicy.Status.debugged }),
            (.allowsDYLDEnvironment, { $0.allowsDYLDEnvironment = true }),
            (.platformBinary, { $0.status |= ClientSignaturePolicy.Status.platformBinary }),
        ]
        for (failure, change) in cases {
            let (evidence, verifier) = directEvidence(change: change)
            XCTAssertEqual(
                ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
                .failed(failure)
            )
        }
    }

    func testAppReadsStatusItselfWhenItCan() {
        // `imcp-server` reports a hardened runtime, but the kernel's status has none.
        let (evidence, base) = directEvidence()
        var verifier = base
        verifier.statuses[evidence.client.token] = ClientSignaturePolicy.Status.valid
        XCTAssertEqual(
            ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
            .failed(.notHardened)
        )
    }

    func testRefusesInterpretersShellsAndLaunchers() {
        let identifiers = [
            "node", "python3", "bun", "deno", "ruby", "perl", "osascript", "env",
            "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish",
            "com.apple.zsh", "org.python.python", "org.python.python3.13", "org.nodejs.node",
            "Node", "perl5.34", "python3.12",
        ]
        for identifier in identifiers {
            XCTAssertTrue(ClientSignaturePolicy.isDenied(identifier: identifier), identifier)
            let (evidence, verifier) = directEvidence(identifier: identifier)
            XCTAssertEqual(
                ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
                .failed(.runsOtherCode),
                identifier
            )
        }
        for identifier in ["com.anthropic.claude-code", "com.anthropic.claudefordesktop", "disclaimer", "envoy"] {
            XCTAssertFalse(ClientSignaturePolicy.isDenied(identifier: identifier), identifier)
        }
    }

    func testEachElectronFuse() {
        let failing: [ElectronFuses] = [
            ElectronFuses(),
            ElectronFuses(runAsNode: true, embeddedAsarIntegrityValidation: true, onlyLoadAppFromAsar: true),
            ElectronFuses(runAsNode: false, embeddedAsarIntegrityValidation: false, onlyLoadAppFromAsar: true),
            ElectronFuses(runAsNode: false, embeddedAsarIntegrityValidation: true, onlyLoadAppFromAsar: false),
            ElectronFuses(runAsNode: nil, embeddedAsarIntegrityValidation: true, onlyLoadAppFromAsar: true),
        ]
        for fuses in failing {
            let (evidence, verifier) = directEvidence { $0.electron = fuses }
            XCTAssertEqual(
                ClientVerification.verify(evidence, serverProcessID: 300, using: verifier),
                .failed(.electronFuses),
                String(describing: fuses)
            )
        }

        let (evidence, verifier) = directEvidence { $0.electron = Self.passingFuses }
        XCTAssertNotNil(ClientVerification.verify(evidence, serverProcessID: 300, using: verifier).verifiedClient)
    }

    func testVerifiesDirectParentWithPipesByTheSameRules() throws {
        // A command-line client from another team that starts the server as its direct child,
        // with pipes for stdin and stdout, and entitlements for JIT and unsigned executable memory,
        // which the rules allow.
        var inspector = FakeInspector()
        inspector.streams = [
            STDIN_FILENO: .pipe(handle: 11, peer: 12),
            STDOUT_FILENO: .pipe(handle: 13, peer: 14),
        ]
        var collected = try ClientEvidenceCollector.collect(using: inspector).get()
        XCTAssertNil(collected.launcher)
        collected.client.identifier = "codex"
        collected.client.team = Self.otherTeam
        collected.client.publisher = "OpenAI, L.L.C."

        let verifier = FakeVerifier(
            signatures: [
                collected.client.token: ClientSignature(
                    identifier: "codex",
                    team: Self.otherTeam,
                    publisher: "OpenAI, L.L.C."
                )
            ],
            parents: [300: 100]
        )
        let verification = ClientVerification.verify(collected, serverProcessID: 300, using: verifier)
        XCTAssertEqual(verification.verifiedClient?.signature.identifier, "codex")
        XCTAssertEqual(verification.verifiedClient?.signature.team, Self.otherTeam)
        XCTAssertEqual(verification.verifiedClient?.isApplication, false)

        // Another holder of either pipe stops the evidence.
        inspector.holders[STDOUT_FILENO] = [100, 77]
        XCTAssertEqual(
            ClientEvidenceCollector.collect(using: inspector),
            .failure(.holders(input: 1, output: 2, same: false))
        )
    }

    func testNoEvidenceIsUnidentified() {
        XCTAssertEqual(
            ClientVerification.verify(nil, serverProcessID: 300, using: FakeVerifier(signatures: [:], parents: [:])),
            .unidentified
        )
    }

    func testUpdatedClientKeepsItsIdentity() {
        // An update starts a new process with new code; only the token and the bundle change.
        let (before, beforeVerifier) = directEvidence()
        var (after, afterVerifier) = directEvidence()
        let updated = Self.token(200, version: 2)
        after.client.token = updated
        afterVerifier.signatures = [updated: beforeVerifier.signatures.values.first!]

        let first = ClientVerification.verify(before, serverProcessID: 300, using: beforeVerifier)
        let second = ClientVerification.verify(after, serverProcessID: 300, using: afterVerifier)
        XCTAssertNotNil(first.verifiedClient)
        XCTAssertEqual(first, second)
    }

    // MARK: - Hello

    func testHelloWithEvidenceRoundTripsWithinLimit() throws {
        let (evidence, _) = launcherEvidence()
        let hello = LocalSocketHello(credential: ClientCredential.generate(), evidence: evidence)

        let data = try hello.encodedWithinLimit()
        XCTAssertLessThanOrEqual(data.count - 1, LocalSocketHello.maximumLength)
        XCTAssertEqual(try LocalSocketHello.decode(data.dropLast()), hello)
    }

    func testHelloWithoutEvidenceOmitsIt() throws {
        let data = try LocalSocketHello(credential: nil).encodedWithinLimit()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"version":1}"# + "\n")
    }

    func testOldHelloWithOnlyCredentialDecodes() throws {
        let line = Data(#"{"credential":"imcp_abc","version":1}"#.utf8)
        let hello = try LocalSocketHello.decode(line)
        XCTAssertEqual(hello.credential, "imcp_abc")
        XCTAssertNil(hello.evidence)
    }

    func testHelloWithUnreadableEvidenceKeepsCredential() throws {
        let line = Data(#"{"credential":"imcp_abc","evidence":{"client":42},"version":1}"#.utf8)
        let hello = try LocalSocketHello.decode(line)
        XCTAssertEqual(hello.credential, "imcp_abc")
        XCTAssertNil(hello.evidence)
    }

    func testHelloDropsEvidenceThatDoesNotFit() throws {
        var (evidence, _) = directEvidence()
        evidence.client.identifier = String(repeating: "a", count: 2000)
        let hello = LocalSocketHello(credential: "imcp_abc", evidence: evidence)

        let decoded = try LocalSocketHello.decode(try hello.encodedWithinLimit().dropLast())
        XCTAssertEqual(decoded.credential, "imcp_abc")
        XCTAssertNil(decoded.evidence)
    }

    func testAuditTokenCodesAsBase64() throws {
        let token = Self.token(1234, version: 7)
        let data = try JSONEncoder().encode([token])
        XCTAssertEqual(try JSONDecoder().decode([AuditToken].self, from: data), [token])
        XCTAssertEqual(token.processID, 1234)
        XCTAssertThrowsError(try JSONDecoder().decode([AuditToken].self, from: Data(#"["AAAA"]"#.utf8)))
    }

    // MARK: - Electron fuses

    func testReadsElectronFuseWire() {
        var binary = Data(repeating: 0, count: 64)
        binary.append(ElectronFuses.sentinel)
        binary.append(contentsOf: [1, 9])
        binary.append(Data("010011011".utf8))
        binary.append(Data(repeating: 0, count: 64))

        XCTAssertEqual(ElectronFuses.read(from: binary), Self.passingFuses)
    }

    func testFuseWireReportsRemovedAndMissingFuses() {
        var binary = ElectronFuses.sentinel
        binary.append(contentsOf: [1, 5])
        binary.append(Data("1r001".utf8))

        XCTAssertEqual(
            ElectronFuses.read(from: binary),
            ElectronFuses(runAsNode: true, embeddedAsarIntegrityValidation: true, onlyLoadAppFromAsar: nil)
        )
    }

    func testFuseWireMustBeUniqueAndKnown() {
        var wire = ElectronFuses.sentinel
        wire.append(contentsOf: [1, 6])
        wire.append(Data("010011".utf8))

        XCTAssertNil(ElectronFuses.read(from: wire + wire))
        XCTAssertNil(ElectronFuses.read(from: Data("no fuses here".utf8)))

        var unknownVersion = ElectronFuses.sentinel
        unknownVersion.append(contentsOf: [2, 6])
        unknownVersion.append(Data("010011".utf8))
        XCTAssertNil(ElectronFuses.read(from: unknownVersion))

        var truncated = ElectronFuses.sentinel
        truncated.append(contentsOf: [1, 9, UInt8(ascii: "0")])
        XCTAssertNil(ElectronFuses.read(from: truncated))
    }

    // MARK: - System inspection

    func testAuditTokenOfThisProcess() throws {
        let inspector = SystemProcessInspector()
        let token = try XCTUnwrap(inspector.auditToken(of: getpid()))
        XCTAssertEqual(token.processID, getpid())
        XCTAssertEqual(token, ownToken())
        XCTAssertNil(inspector.auditToken(of: -5))
    }

    func testParentOfThisProcess() {
        XCTAssertEqual(SystemProcessInspector().parentProcessID(of: getpid()), getppid())
        XCTAssertEqual(SystemProcessInspector().currentParentProcessID(), getppid())
    }

    func testStandardStreamKinds() throws {
        let inspector = SystemProcessInspector()

        let path = NSTemporaryDirectory() + "imcp-stream-\(UUID().uuidString)"
        let file = open(path, O_CREAT | O_RDWR, 0o600)
        defer {
            close(file)
            unlink(path)
        }
        XCTAssertEqual(inspector.standardStream(file), .unsupported("a file"))

        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { ends.forEach { close($0) } }
        guard case .pipe(_, let peer) = inspector.standardStream(ends[0]) else {
            return XCTFail("A pipe's read end is a pipe")
        }
        guard case .pipe(let handle, _) = inspector.standardStream(ends[1]) else {
            return XCTFail("A pipe's write end is a pipe")
        }
        XCTAssertEqual(peer, handle)

        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach { close($0) } }
        guard case .socket(let identity) = inspector.standardStream(sockets[0]) else {
            return XCTFail("A socket pair is a socket")
        }
        XCTAssertNotEqual(identity.peer, 0)
    }

    func testFindsChildThatHoldsOtherEndOfPipe() throws {
        let pipe = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardOutput = pipe
        try child.run()
        defer { child.terminate() }
        // Only the child keeps the write end.
        try pipe.fileHandleForWriting.close()

        let inspector = SystemProcessInspector()
        let endpoint = inspector.standardStream(pipe.fileHandleForReading.fileDescriptor)
        guard case .pipe = endpoint else { return XCTFail("Expected a pipe, got \(endpoint)") }
        XCTAssertEqual(inspector.processesHoldingPeer(of: endpoint), [child.processIdentifier])
    }

    func testFindsDirectParentThatHoldsBothPipes() throws {
        // This process plays the client: it starts a child whose stdin and stdout are pipes,
        // and keeps only the other ends.
        let input = Pipe()
        let output = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer { child.terminate() }

        // `Process` closes this process's copies of the child's ends,
        // as a client does after it starts the server, so read the child's ends from the peers of this process's.
        let pipeHandles = { (descriptor: Int32) in
            ProcessInspection.pipeHandles(process: getpid(), descriptor: descriptor)
        }
        let clientInput = try XCTUnwrap(pipeHandles(input.fileHandleForWriting.fileDescriptor))
        let clientOutput = try XCTUnwrap(pipeHandles(output.fileHandleForReading.fileDescriptor))
        let childInput = (handle: clientInput.peer, peer: clientInput.handle)
        let childOutput = (handle: clientOutput.peer, peer: clientOutput.handle)

        // From the child's side, this process is the only holder of the other end of each pipe.
        let inspector = SystemProcessInspector()
        XCTAssertEqual(
            inspector.processesHoldingPeer(of: .pipe(handle: childInput.handle, peer: childInput.peer)),
            [getpid()]
        )
        XCTAssertEqual(
            inspector.processesHoldingPeer(of: .pipe(handle: childOutput.handle, peer: childOutput.peer)),
            [getpid()]
        )
    }

    func testFindsChildThatHoldsOtherEndOfSocket() throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardInput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
        try child.run()
        defer { child.terminate() }
        close(sockets[1])

        let inspector = SystemProcessInspector()
        let endpoint = inspector.standardStream(sockets[0])
        guard case .socket = endpoint else { return XCTFail("Expected a socket, got \(endpoint)") }
        XCTAssertEqual(inspector.processesHoldingPeer(of: endpoint), [child.processIdentifier])
    }

    func testThisProcessCountsAsHolder() throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { ends.forEach { close($0) } }

        let inspector = SystemProcessInspector()
        XCTAssertEqual(inspector.processesHoldingPeer(of: inspector.standardStream(ends[0])), [getpid()])
    }

    func testReportsAndVerifiesThisProcess() throws {
        let token = ownToken()
        let report = try XCTUnwrap(SystemProcessInspector().report(for: token))
        XCTAssertEqual(report.token, token)

        let verifier = SystemCodeVerifier()
        XCTAssertTrue(verifier.satisfies(token, requirement: "always"))
        XCTAssertFalse(verifier.satisfies(token, requirement: "never"))
        XCTAssertFalse(
            verifier.satisfies(token, requirement: CodeRequirement.signed(identifier: "com.anthropic.claude-code"))
        )
        let status = try XCTUnwrap(verifier.dynamicStatus(of: token))
        XCTAssertNotEqual(status & ClientSignaturePolicy.Status.valid, 0)
        XCTAssertEqual(verifier.parentProcessID(of: getpid()), getppid())
    }

    func testCollectorRefusesThisTestProcess() {
        // The test runner's stdio doesn't lead to a supported client,
        // and whatever the collector finds must fail the checks.
        let result = ClientEvidenceCollector.collect(using: SystemProcessInspector())
        if case .success(let evidence) = result {
            XCTAssertNil(
                ClientVerification.verify(evidence, serverProcessID: getpid(), using: SystemCodeVerifier())
                    .verifiedClient
            )
        }
    }

    private func ownToken() -> AuditToken {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return AuditToken(token)
    }
}

extension ProcessReport {
    fileprivate func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }
}
