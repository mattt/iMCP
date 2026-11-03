import Darwin
import Foundation
import XCTest

/// Tests for the Unix domain socket between `imcp-server` and the app,
/// and for the code-signing requirements that each side checks.
///
/// The test process isn't signed by the iMCP team,
/// so these tests check the requirements against it only to show that they reject it.
/// Checks between signed builds need manual testing.
final class LocalSocketTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        // Keep socket paths short: `sun_path` holds 104 bytes.
        directory = "/tmp/imcp-\(getpid())-\(UInt32.random(in: 0 ... .max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: - Paths

    func testContainerPathIsInAppContainerCaches() {
        XCTAssertEqual(
            LocalSocket.containerPath(homeDirectory: "/Users/someone"),
            "/Users/someone/Library/Containers/co.dododo.iMCP/Data/Library/Caches/imcp.sock"
        )
    }

    func testSandboxedServerPathIsFirstClientPath() {
        let home = "/Users/someone"
        XCTAssertEqual(
            LocalSocket.serverPath(isSandboxed: true, homeDirectory: home),
            LocalSocket.clientPaths(homeDirectory: home).first
        )
    }

    func testUnsandboxedDebugServerPathIsAClientPath() {
        let home = "/Users/someone"
        let path = LocalSocket.serverPath(isSandboxed: false, homeDirectory: home)
        XCTAssertEqual(path, "/Users/someone/Library/Caches/co.dododo.iMCP/imcp.sock")
        XCTAssertTrue(LocalSocket.clientPaths(homeDirectory: home).contains(path))
    }

    func testContainerPathFitsForLongUserNames() throws {
        let home = "/Users/" + String(repeating: "a", count: 32)
        XCTAssertNoThrow(try LocalSocket.address(for: LocalSocket.containerPath(homeDirectory: home)))
    }

    func testAddressRejectsPathLongerThanSunPath() {
        let path = "/" + String(repeating: "a", count: LocalSocket.maximumPathLength)
        XCTAssertThrowsError(try LocalSocket.address(for: path)) { error in
            XCTAssertEqual(error as? LocalSocket.Error, .pathTooLong(path))
        }
        XCTAssertNoThrow(try LocalSocket.address(for: String(path.dropLast())))
    }

    // MARK: - Requirements

    func testReleaseRequirementsPinTeamAndIdentifier() {
        XCTAssertEqual(
            CodeRequirement.releaseClient,
            #"anchor apple generic and identifier "imcp-server" and certificate leaf[subject.OU] = "TTY35UM57S""#
        )
        XCTAssertEqual(
            CodeRequirement.releaseServer,
            #"anchor apple generic and identifier "co.dododo.iMCP" and certificate leaf[subject.OU] = "TTY35UM57S""#
        )
    }

    func testDebugRequirementsExtendReleaseRequirements() {
        XCTAssertEqual(
            CodeRequirement.debugClient,
            #"(\#(CodeRequirement.releaseClient)) or identifier "imcp-server""#
        )
        XCTAssertEqual(
            CodeRequirement.debugServer,
            #"(\#(CodeRequirement.releaseServer)) or identifier "co.dododo.iMCP" or identifier "iMCP""#
        )
        XCTAssertEqual(CodeRequirement.client, CodeRequirement.debugClient)
        XCTAssertEqual(CodeRequirement.server, CodeRequirement.debugServer)
    }

    func testRequirementsCompile() throws {
        for requirement in [
            CodeRequirement.releaseClient,
            CodeRequirement.releaseServer,
            CodeRequirement.debugClient,
            CodeRequirement.debugServer,
        ] {
            XCTAssertNoThrow(try CodeRequirement.compile(requirement), requirement)
        }
        XCTAssertThrowsError(try CodeRequirement.compile("identifier"))
    }

    func testPeerCheckUsesAuditTokenOfConnectedProcess() throws {
        let path = directory + "/peer.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }
        let client = try LocalSocket.connect(to: path)
        defer { close(client) }
        let server = try LocalSocket.accept(listener)
        defer { close(server) }

        let token = try LocalSocket.peerAuditToken(of: server)
        var ownToken = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &ownToken) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        XCTAssertEqual(status, KERN_SUCCESS)
        XCTAssertEqual(withUnsafeBytes(of: token) { Data($0) }, withUnsafeBytes(of: ownToken) { Data($0) })

        for usesDynamicCode in [false, true] {
            XCTAssertTrue(
                LocalSocket.peerSatisfies("always", descriptor: server, usesDynamicCode: usesDynamicCode)
            )
            XCTAssertTrue(
                LocalSocket.peerSatisfies("always", descriptor: client, usesDynamicCode: usesDynamicCode)
            )
        }
    }

    func testRequirementsRejectProcessesOutsideTheTeam() throws {
        let path = directory + "/peer.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }
        let client = try LocalSocket.connect(to: path)
        defer { close(client) }
        let server = try LocalSocket.accept(listener)
        defer { close(server) }

        for requirement in [CodeRequirement.releaseClient, CodeRequirement.releaseServer, CodeRequirement.client] {
            for usesDynamicCode in [false, true] {
                XCTAssertFalse(
                    LocalSocket.peerSatisfies(requirement, descriptor: server, usesDynamicCode: usesDynamicCode),
                    requirement
                )
            }
        }
    }

    // MARK: - Listening

    func testListenReplacesStaleSocket() throws {
        let path = directory + "/stale.sock"
        close(try LocalSocket.listen(at: path) { _ in false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let listener = try LocalSocket.listen(at: path) { _ in
            XCTFail("Nothing listens on a stale socket")
            return true
        }
        defer { close(listener) }
        XCTAssertNoThrow(close(try LocalSocket.connect(to: path)))
    }

    func testListenFailsWhileAnotherServerListens() throws {
        let path = directory + "/busy.sock"
        let first = try LocalSocket.listen(at: path) { _ in false }
        defer { close(first) }

        XCTAssertThrowsError(try LocalSocket.listen(at: path) { _ in true }) { error in
            XCTAssertEqual(error as? LocalSocket.Error, .addressInUse(path))
        }
    }

    func testListenReplacesListenerThatFailsCheck() throws {
        let path = directory + "/impostor.sock"
        let impostor = try LocalSocket.listen(at: path) { _ in false }
        defer { close(impostor) }

        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }

        // New connections reach the new listener, not the impostor.
        let client = try LocalSocket.connect(to: path)
        defer { close(client) }
        let accepted = try LocalSocket.accept(listener)
        close(accepted)
    }

    func testListenReplacesListenerInThisProcess() throws {
        let path = directory + "/own.sock"
        let earlier = try LocalSocket.listen(at: path) { _ in false }
        defer { close(earlier) }

        // A listener in this process isn't another copy of the app,
        // even if it would pass the code-signing check.
        let listener = try LocalSocket.listen(at: path) { occupant in
            LocalSocket.isOtherServer(occupant, requirement: "always")
        }
        defer { close(listener) }

        // New connections reach the new listener.
        let client = try LocalSocket.connect(to: path)
        defer { close(client) }
        close(try LocalSocket.accept(listener))
    }

    func testStatusDistinguishesSocketsFromOtherFiles() throws {
        let path = directory + "/status.sock"
        XCTAssertEqual(LocalSocket.status(at: path), .missing)

        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }
        guard case .socket = LocalSocket.status(at: path) else {
            return XCTFail("A listening socket's file is a socket")
        }

        XCTAssertEqual(unlink(path), 0)
        XCTAssertEqual(LocalSocket.status(at: path), .missing)
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertEqual(LocalSocket.status(at: path), .notASocket)
    }

    func testListenDoesNotRemoveOtherFiles() throws {
        let path = directory + "/file.sock"
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))

        XCTAssertThrowsError(try LocalSocket.listen(at: path) { _ in false }) { error in
            XCTAssertEqual(error as? LocalSocket.Error, .notASocket(path))
        }
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data("keep".utf8))
    }

    func testListenCreatesPrivateSocket() throws {
        let path = directory + "/nested/private.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Connecting

    func testConnectSkipsMissingPathsAndChecksListener() throws {
        let path = directory + "/server.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }
        let accepted = acceptInBackground(listener)

        let (descriptor, connectedPath) = try LocalSocket.connect(
            toFirstOf: [directory + "/missing.sock", path],
            requiring: "always"
        )
        close(descriptor)
        XCTAssertEqual(connectedPath, path)
        close(try accepted())
    }

    func testConnectRejectsListenerWhoseProcessDoesNotHoldConnection() throws {
        let path = directory + "/unaccepted.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }

        // Nothing accepts the connection, so no process has its other end open,
        // as when the process that the token names isn't the one that holds the listener.
        XCTAssertThrowsError(
            try LocalSocket.connect(toFirstOf: [path], requiring: "always", acceptTimeout: .milliseconds(100))
        ) { error in
            let untrusted = error as? CodeRequirement.UntrustedPeer
            XCTAssertEqual(untrusted?.path, path)
            XCTAssertEqual((untrusted?.underlying as? LocalSocket.PeerNotHeld)?.processID, getpid())
        }
    }

    func testProcessHoldsPeerOnlyAfterAccept() throws {
        let path = directory + "/held.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }
        let client = try LocalSocket.connect(to: path)
        defer { close(client) }

        XCTAssertFalse(try LocalSocket.process(getpid(), holdsPeerOf: client))

        let server = try LocalSocket.accept(listener)
        defer { close(server) }
        XCTAssertTrue(try LocalSocket.process(getpid(), holdsPeerOf: client))
        XCTAssertTrue(try LocalSocket.process(getpid(), holdsPeerOf: server))
        XCTAssertFalse(try LocalSocket.process(getppid(), holdsPeerOf: client))

        let token = try LocalSocket.peerAuditToken(of: client)
        XCTAssertNoThrow(try LocalSocket.checkPeerHoldsConnection(client, token: token, timeout: .zero))
    }

    func testPeerCheckReportsClosedConnection() throws {
        let path = directory + "/closed.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }
        let client = try LocalSocket.connect(to: path)
        defer { close(client) }
        close(try LocalSocket.accept(listener))

        XCTAssertThrowsError(try LocalSocket.process(getpid(), holdsPeerOf: client)) { error in
            XCTAssertEqual((error as? LocalSocket.Error)?.code, ECONNRESET)
        }
    }

    func testConnectRejectsListenerThatFailsRequirement() throws {
        let path = directory + "/server.sock"
        let listener = try LocalSocket.listen(at: path) { _ in false }
        defer { close(listener) }

        XCTAssertThrowsError(try LocalSocket.connect(toFirstOf: [path], requiring: CodeRequirement.server)) { error in
            XCTAssertEqual((error as? CodeRequirement.UntrustedPeer)?.path, path)
        }

        // The rejected connection wrote nothing before it closed.
        let accepted = try LocalSocket.accept(listener)
        defer { close(accepted) }
        var byte: UInt8 = 0
        XCTAssertEqual(read(accepted, &byte, 1), 0)
    }

    func testConnectReportsMissingApp() {
        XCTAssertThrowsError(
            try LocalSocket.connect(toFirstOf: [directory + "/missing.sock"], requiring: "always")
        ) { error in
            XCTAssertEqual((error as? LocalSocket.Error)?.code, ENOENT)
        }
    }

    // MARK: - Hello

    func testReadLineStopsAtNewline() throws {
        let (reader, writer) = try socketPair()
        defer {
            close(reader)
            close(writer)
        }

        let bytes = Array("first\nsecond".utf8)
        XCTAssertEqual(write(writer, bytes, bytes.count), bytes.count)

        let line = try LocalSocket.readLine(from: reader, maximumLength: 64, timeout: .seconds(1))
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "first")

        var rest = [UInt8](repeating: 0, count: 16)
        let count = read(reader, &rest, rest.count)
        XCTAssertEqual(String(decoding: rest[..<count], as: UTF8.self), "second")
    }

    func testReadLineRejectsLongLine() throws {
        let (reader, writer) = try socketPair()
        defer {
            close(reader)
            close(writer)
        }

        let bytes = [UInt8](repeating: UInt8(ascii: "a"), count: 9) + [UInt8(ascii: "\n")]
        XCTAssertEqual(write(writer, bytes, bytes.count), bytes.count)

        XCTAssertThrowsError(try LocalSocket.readLine(from: reader, maximumLength: 8, timeout: .seconds(1))) {
            XCTAssertEqual(($0 as? LocalSocket.Error)?.code, EMSGSIZE)
        }
    }

    func testReadLineTimesOut() throws {
        let (reader, writer) = try socketPair()
        defer {
            close(reader)
            close(writer)
        }

        XCTAssertThrowsError(
            try LocalSocket.readLine(from: reader, maximumLength: 8, timeout: .milliseconds(50))
        ) {
            XCTAssertEqual(($0 as? LocalSocket.Error)?.code, EAGAIN)
        }
    }

    func testReadLineDeadlineCoversWholeLine() throws {
        let (reader, writer) = try socketPair()
        defer {
            close(reader)
            close(writer)
        }

        // A peer that sends a byte more often than the timeout still runs out of time.
        let sender = Thread {
            for _ in 0 ..< 20 {
                var byte = UInt8(ascii: "a")
                guard write(writer, &byte, 1) == 1 else { return }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        sender.start()

        let start = ContinuousClock.now
        XCTAssertThrowsError(
            try LocalSocket.readLine(from: reader, maximumLength: 64, timeout: .milliseconds(100))
        ) {
            XCTAssertEqual(($0 as? LocalSocket.Error)?.code, EAGAIN)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(400))
    }

    func testHelloRejectsUnknownVersion() throws {
        for version in [0, 2] {
            let line = Data(#"{"version":\#(version)}"#.utf8)
            XCTAssertThrowsError(try LocalSocketHello.decode(line)) { error in
                XCTAssertEqual(error as? LocalSocketHello.Error, .unsupportedVersion(version))
            }
        }
        XCTAssertThrowsError(try LocalSocketHello.decode(Data(#"{"credential":"x"}"#.utf8)))
        XCTAssertEqual(try LocalSocketHello.decode(Data(#"{"version":1}"#.utf8)), LocalSocketHello())
    }

    func testHelloRoundTrips() throws {
        let hello = LocalSocketHello()
        let data = try hello.encoded()
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))
        XCTAssertEqual(try LocalSocketHello.decode(data.dropLast()), hello)
        XCTAssertLessThanOrEqual(data.count - 1, LocalSocketHello.maximumLength)
    }

    /// Accepts one connection on a background thread.
    ///
    /// - Returns: A function that waits for the accepted descriptor.
    private func acceptInBackground(_ listener: Int32) -> () throws -> Int32 {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Int32, any Error> = .failure(
            LocalSocket.Error.posix(call: "accept", code: EAGAIN)
        )
        Thread {
            result = Result { try LocalSocket.accept(listener) }
            done.signal()
        }.start()
        return {
            done.wait()
            return try result.get()
        }
    }

    private func socketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw LocalSocket.Error.posix(call: "socketpair", code: errno)
        }
        return (descriptors[0], descriptors[1])
    }
}
