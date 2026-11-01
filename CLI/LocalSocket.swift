import Darwin
import Foundation
import Security

/// The Unix domain socket that connects `imcp-server` to the iMCP app.
///
/// The sandboxed app listens on a socket in its own container,
/// and `imcp-server` derives the same path from the app's bundle identifier.
/// Before either side sends anything,
/// it reads the peer's audit token from the socket
/// and checks the peer's code signature against ``CodeRequirement``.
/// The socket replaces Bonjour and loopback TCP,
/// which let any local process advertise a service or accept a session.
enum LocalSocket {
    /// The iMCP app's bundle identifier, which names its sandbox container.
    static let appBundleIdentifier = "co.dododo.iMCP"

    /// The name of the socket file in the app's caches directory.
    static let fileName = "imcp.sock"

    /// The largest path that fits in `sockaddr_un.sun_path`, excluding the terminating NUL.
    static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The path doesn't fit in a socket address.
        case pathTooLong(String)
        /// Another iMCP app listens on the path.
        case addressInUse(String)
        /// Something other than a socket exists at the path.
        case notASocket(String)
        /// A system call failed.
        case posix(call: String, code: Int32)

        var description: String {
            switch self {
            case .pathTooLong(let path):
                return "The socket path is longer than \(LocalSocket.maximumPathLength) bytes: \(path)"
            case .addressInUse(let path):
                return "Another copy of iMCP is listening at \(path)"
            case .notASocket(let path):
                return "Something other than a socket exists at \(path)"
            case .posix(let call, let code):
                return "\(call) failed: \(String(cString: strerror(code))) (\(code))"
            }
        }

        var code: Int32? {
            if case .posix(_, let code) = self { return code }
            return nil
        }
    }

    // MARK: - Paths

    /// Returns the home directory of the current user from the user database.
    ///
    /// `NSHomeDirectory()` returns the container in a sandboxed app,
    /// and an MCP client can start `imcp-server` with a different `HOME`.
    static var userHomeDirectory: String {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
    }

    /// Returns the socket path in the app's sandbox container.
    static func containerPath(
        homeDirectory: String = userHomeDirectory,
        appBundleIdentifier: String = appBundleIdentifier
    ) -> String {
        "\(homeDirectory)/Library/Containers/\(appBundleIdentifier)/Data/Library/Caches/\(fileName)"
    }

    #if DEBUG
        /// Returns the socket path for a Debug build of the app that runs without App Sandbox.
        ///
        /// Debug builds made with `CODE_SIGNING_ALLOWED=NO` have no entitlements,
        /// so they run outside a container.
        /// Release builds always run in App Sandbox and never use this path.
        static func unsandboxedPath(
            homeDirectory: String = userHomeDirectory,
            appBundleIdentifier: String = appBundleIdentifier
        ) -> String {
            "\(homeDirectory)/Library/Caches/\(appBundleIdentifier)/\(fileName)"
        }
    #endif

    /// Returns the paths where `imcp-server` looks for the app, in order.
    static func clientPaths(homeDirectory: String = userHomeDirectory) -> [String] {
        #if DEBUG
            return [
                containerPath(homeDirectory: homeDirectory),
                unsandboxedPath(homeDirectory: homeDirectory),
            ]
        #else
            return [containerPath(homeDirectory: homeDirectory)]
        #endif
    }

    /// Returns the path where the app listens.
    ///
    /// - Parameter isSandboxed: Whether the app runs in App Sandbox.
    static func serverPath(isSandboxed: Bool, homeDirectory: String = userHomeDirectory) -> String {
        #if DEBUG
            if !isSandboxed {
                return unsandboxedPath(homeDirectory: homeDirectory)
            }
        #endif
        return containerPath(homeDirectory: homeDirectory)
    }

    /// Whether the current process runs in App Sandbox.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Sockets

    /// Returns a socket address for `path`.
    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else {
            throw Error.pathTooLong(path)
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    /// Creates a stream socket that doesn't raise `SIGPIPE`
    /// and isn't inherited by child processes.
    static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Error.posix(call: "socket", code: errno)
        }

        var on: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
        else {
            let code = errno
            close(descriptor)
            throw Error.posix(call: "setsockopt", code: code)
        }
        return descriptor
    }

    /// Connects to the socket at `path` and returns the connected descriptor.
    static func connect(to path: String) throws -> Int32 {
        var address = try address(for: path)
        let descriptor = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw Error.posix(call: "connect", code: code)
        }
        return descriptor
    }

    /// Binds a listening socket at `path`, replacing a stale socket file.
    ///
    /// A socket file stays behind when the app exits without removing it.
    /// When `bind` reports that the path is in use,
    /// this function connects to it to find out whether anything listens there.
    /// If nothing does, or if the listener fails `isServer`,
    /// it removes the file and binds again.
    /// Otherwise it throws ``Error/addressInUse(_:)``.
    ///
    /// - Parameters:
    ///   - path: The socket path. Its parent directory is created if needed.
    ///   - backlog: The maximum length of the queue of pending connections.
    ///   - isServer: Returns whether the process on the other end of a
    ///     connected descriptor is a copy of the iMCP app.
    static func listen(
        at path: String,
        backlog: Int32 = 16,
        isServer: (Int32) -> Bool
    ) throws -> Int32 {
        var address = try address(for: path)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let descriptor = try makeSocket()
        func bindToPath() -> Int32 {
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }

        do {
            if bindToPath() != 0 {
                let code = errno
                guard code == EADDRINUSE else {
                    throw Error.posix(call: "bind", code: code)
                }
                try removeStaleSocket(at: path, isServer: isServer)
                guard bindToPath() == 0 else {
                    throw Error.posix(call: "bind", code: errno)
                }
            }

            // Only the user's own processes can connect.
            // The container directory is private to the user as well.
            guard chmod(path, 0o600) == 0 else {
                throw Error.posix(call: "chmod", code: errno)
            }
            guard Darwin.listen(descriptor, backlog) == 0 else {
                throw Error.posix(call: "listen", code: errno)
            }
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    /// What exists at a socket path.
    enum PathStatus: Equatable {
        /// Nothing, or something that `lstat` can't read.
        case missing
        /// A socket file, identified by its device and inode.
        case socket(device: dev_t, inode: ino_t)
        /// A file that isn't a socket.
        case notASocket
    }

    /// Returns what exists at `path`, without following a symbolic link.
    static func status(at path: String) -> PathStatus {
        var status = stat()
        guard lstat(path, &status) == 0 else { return .missing }
        guard status.st_mode & S_IFMT == S_IFSOCK else { return .notASocket }
        return .socket(device: status.st_dev, inode: status.st_ino)
    }

    /// Removes the socket file at `path` unless a copy of iMCP listens on it.
    static func removeStaleSocket(at path: String, isServer: (Int32) -> Bool) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw Error.posix(call: "lstat", code: errno)
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else {
            throw Error.notASocket(path)
        }

        if let occupant = try? connect(to: path) {
            defer { close(occupant) }
            if isServer(occupant) {
                throw Error.addressInUse(path)
            }
        }

        guard unlink(path) == 0 || errno == ENOENT else {
            throw Error.posix(call: "unlink", code: errno)
        }
    }

    /// Accepts a connection on a listening socket and returns a blocking descriptor for it.
    ///
    /// An accepted socket inherits `O_NONBLOCK` from a nonblocking listener,
    /// so this function clears it.
    static func accept(_ listener: Int32) throws -> Int32 {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else {
            throw Error.posix(call: "accept", code: errno)
        }

        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
        return descriptor
    }

    /// Returns the audit token of the process on the other end of a connected socket.
    ///
    /// The kernel records the connecting process for the listener,
    /// and the listening process for the connecting side.
    /// The token includes the process ID version,
    /// so it can't refer to a different process that reuses the ID.
    static func peerAuditToken(of descriptor: Int32) throws -> audit_token_t {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            throw Error.posix(call: "getsockopt(LOCAL_PEERTOKEN)", code: errno)
        }
        return token
    }

    /// Returns the process ID in an audit token.
    static func processID(of token: audit_token_t) -> pid_t {
        // `audit_token_to_pid` reads the same field.
        pid_t(bitPattern: token.val.5)
    }

    /// Returns whether the process on the other end of `descriptor` satisfies `requirement`.
    static func peerSatisfies(_ requirement: String, descriptor: Int32, usesDynamicCode: Bool) -> Bool {
        do {
            let token = try peerAuditToken(of: descriptor)
            try CodeRequirement.check(auditToken: token, against: requirement, usesDynamicCode: usesDynamicCode)
            return true
        } catch {
            return false
        }
    }

    /// Returns whether a process other than this one listens on the other end of `occupant`
    /// and satisfies `requirement`.
    ///
    /// The app uses this to decide whether a socket file at its path is stale.
    /// A listener in this process is one that the app no longer uses,
    /// so it doesn't count.
    static func isOtherServer(_ occupant: Int32, requirement: String) -> Bool {
        guard let token = try? peerAuditToken(of: occupant), processID(of: token) != getpid() else {
            return false
        }
        return (try? CodeRequirement.check(auditToken: token, against: requirement, usesDynamicCode: true)) != nil
    }

    // MARK: - Peer ownership

    /// The kernel's identifiers for a Unix domain socket and for the socket that it's connected to.
    ///
    /// `proc_pidfdinfo` reports the kernel addresses of the sockets' protocol control blocks.
    /// It obscures them, but it reports the same value for a socket to every process,
    /// so they can be compared across processes.
    struct SocketIdentity: Equatable {
        /// The socket's control block.
        var socket: UInt64
        /// The connected socket's control block, or 0 if the socket isn't connected.
        var peer: UInt64
    }

    /// Returns the identity of the Unix domain socket that process `pid` has open as `descriptor`.
    static func socketIdentity(process pid: pid_t, descriptor: Int32) -> SocketIdentity? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size,
            info.psi.soi_kind == SOCKINFO_UN
        else { return nil }
        return SocketIdentity(socket: info.psi.soi_pcb, peer: info.psi.soi_proto.pri_un.unsi_conn_pcb)
    }

    /// Returns the socket descriptors that process `pid` has open.
    static func socketDescriptors(process pid: pid_t) throws -> [Int32] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else {
            throw Error.posix(call: "proc_pidinfo(PROC_PIDLISTFDS)", code: errno)
        }
        // Leave room for descriptors that the process opens in the meantime.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else {
            throw Error.posix(call: "proc_pidinfo(PROC_PIDLISTFDS)", code: errno)
        }
        return descriptors.prefix(Int(filled) / stride)
            .filter { $0.proc_fdtype == PROX_FDTYPE_SOCKET }
            .map(\.proc_fd)
    }

    /// Returns whether process `pid` has the other end of `descriptor` open.
    ///
    /// - Throws: ``Error/posix(call:code:)`` with `ECONNRESET`
    ///   if the other end closed the connection.
    static func process(_ pid: pid_t, holdsPeerOf descriptor: Int32) throws -> Bool {
        guard let own = socketIdentity(process: getpid(), descriptor: descriptor) else {
            throw Error.posix(call: "proc_pidfdinfo(PROC_PIDFDSOCKETINFO)", code: errno)
        }
        guard own.peer != 0 else {
            throw Error.posix(call: "connect", code: ECONNRESET)
        }
        let peer = SocketIdentity(socket: own.peer, peer: own.socket)
        return try socketDescriptors(process: pid).contains {
            socketIdentity(process: pid, descriptor: $0) == peer
        }
    }

    /// The process that `LOCAL_PEERTOKEN` names doesn't have the other end of the connection open.
    struct PeerNotHeld: Swift.Error, CustomStringConvertible {
        let processID: pid_t

        var description: String {
            "Process \(processID) doesn't have the other end of the connection open"
        }
    }

    /// Checks that the process in `token` has the other end of `descriptor` open.
    ///
    /// For the connecting side, `LOCAL_PEERTOKEN` doesn't come from the listening process itself.
    /// The kernel looks up the process ID that the listening socket last recorded
    /// and returns the audit token of whatever process has that ID now.
    /// If the listener's process exited and left the socket to another process,
    /// such as a child that inherited it,
    /// a new process that reuses the ID would answer for the listener.
    /// This check rejects that case: the process must hold the accepted socket.
    ///
    /// The listener accepts the connection after `connect` returns,
    /// so the check waits up to `timeout` for the socket to appear in the process.
    /// It then reads the token again, and requires the same process ID and ID version,
    /// so the process that it checked is the one that the token names.
    ///
    /// - Throws: ``PeerNotHeld`` if the process doesn't have the socket open,
    ///   or ``Error/posix(call:code:)`` with `ECONNRESET` if the listener closed the connection.
    static func checkPeerHoldsConnection(
        _ descriptor: Int32,
        token: audit_token_t,
        timeout: Duration = .seconds(3)
    ) throws {
        let pid = processID(of: token)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while try !process(pid, holdsPeerOf: descriptor) {
            guard clock.now < deadline else {
                throw PeerNotHeld(processID: pid)
            }
            usleep(5_000)
        }

        let current = try peerAuditToken(of: descriptor)
        guard withUnsafeBytes(of: current, { Data($0) }) == withUnsafeBytes(of: token, { Data($0) }) else {
            throw PeerNotHeld(processID: pid)
        }
    }

    /// Connects to the first path where a process that satisfies `requirement` listens.
    ///
    /// Nothing is written to a socket before its listener passes the check
    /// and ``checkPeerHoldsConnection(_:token:timeout:)``.
    ///
    /// - Parameter acceptTimeout: How long to wait for the listener to accept the connection.
    /// - Returns: The connected descriptor and its path.
    /// - Throws: The error for the last path if no path has a verified listener.
    static func connect(
        toFirstOf paths: [String],
        requiring requirement: String,
        acceptTimeout: Duration = .seconds(3)
    ) throws -> (descriptor: Int32, path: String) {
        var lastError: any Swift.Error = Error.posix(call: "connect", code: ENOENT)
        for path in paths {
            let descriptor: Int32
            do {
                descriptor = try connect(to: path)
            } catch {
                lastError = error
                continue
            }

            do {
                let token = try peerAuditToken(of: descriptor)
                try CodeRequirement.check(auditToken: token, against: requirement, usesDynamicCode: false)
                try checkPeerHoldsConnection(descriptor, token: token, timeout: acceptTimeout)
                return (descriptor, path)
            } catch let error as Error where error.code == ECONNRESET || error.code == ENOTCONN {
                // The app closed the connection, for example because its server is off.
                close(descriptor)
                lastError = error
            } catch {
                close(descriptor)
                lastError = CodeRequirement.UntrustedPeer(path: path, underlying: error)
            }
        }
        throw lastError
    }

    /// Reads bytes up to and including the first newline, one byte at a time,
    /// so that nothing after the line is consumed.
    ///
    /// - Parameters:
    ///   - descriptor: A blocking socket.
    ///   - maximumLength: The most bytes to read before the newline.
    ///   - timeout: How long to wait for the whole line.
    /// - Returns: The line without its newline.
    static func readLine(from descriptor: Int32, maximumLength: Int, timeout: Duration) throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        defer {
            var none = timeval()
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        }

        var line = Data()
        var byte: UInt8 = 0
        while true {
            // `SO_RCVTIMEO` limits each read, so give each read only the time that's left.
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw Error.posix(call: "read", code: EAGAIN)
            }
            let (seconds, attoseconds) = remaining.components
            var interval = timeval(
                tv_sec: Int(seconds),
                tv_usec: max(1, Int32(attoseconds / 1_000_000_000_000))
            )
            guard
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
                    == 0
            else {
                throw Error.posix(call: "setsockopt(SO_RCVTIMEO)", code: errno)
            }

            let count = read(descriptor, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw Error.posix(call: "read", code: errno)
            }
            guard count == 1 else {
                throw Error.posix(call: "read", code: ECONNRESET)
            }
            if byte == UInt8(ascii: "\n") {
                return line
            }
            guard line.count < maximumLength else {
                throw Error.posix(call: "read", code: EMSGSIZE)
            }
            line.append(byte)
        }
    }
}

/// The first line that `imcp-server` sends after it verifies the app,
/// before any MCP messages.
struct LocalSocketHello: Codable, Equatable {
    /// The longest hello the app reads, excluding the newline.
    static let maximumLength = 1024

    /// The environment variable that holds the client's credential
    /// in the client's MCP server settings.
    static let credentialEnvironmentVariable = "IMCP_CLIENT_CREDENTIAL"

    /// The version of this exchange.
    var version: Int = 1

    /// The credential that iMCP issued to the client, if it has one.
    var credential: String?

    /// Returns a hello with the credential from `environment`.
    static func fromEnvironment(_ environment: [String: String]) -> Self {
        let credential = environment[credentialEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(credential: credential?.isEmpty == false ? credential : nil)
    }

    /// Returns the hello as a line of JSON.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Decodes a hello from a line without its newline.
    static func decode(_ line: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: line)
    }
}

/// The code-signing requirements that `imcp-server` and the iMCP app check in each other.
///
/// The requirements pin the signing identifier and the team.
/// An identifier alone isn't enough:
/// anyone can sign a binary with the identifier `imcp-server`.
enum CodeRequirement {
    /// The team that signs iMCP and `imcp-server`.
    static let teamIdentifier = "TTY35UM57S"

    /// The signing identifier of `imcp-server`.
    ///
    /// Xcode signs a command-line tool with its product name,
    /// not its `PRODUCT_BUNDLE_IDENTIFIER`.
    static let serverSigningIdentifier = "imcp-server"

    /// The signing identifier of the iMCP app.
    static let appSigningIdentifier = LocalSocket.appBundleIdentifier

    /// The signing identifier of a Debug build of the app made with `CODE_SIGNING_ALLOWED=NO`,
    /// which the linker signs ad hoc with the product name.
    static let unsignedAppSigningIdentifier = "iMCP"

    enum Error: Swift.Error, Equatable {
        case invalidRequirement(OSStatus)
        case noSuchCode(OSStatus)
        case rejected(OSStatus)
    }

    /// The process that listens at a path failed the code-signing check.
    struct UntrustedPeer: Swift.Error, CustomStringConvertible {
        let path: String
        let underlying: any Swift.Error

        var description: String {
            "The process listening at \(path) isn't a signed copy of iMCP (\(underlying))"
        }
    }

    /// Returns a requirement for code that Apple issued to the iMCP team
    /// with the signing identifier `identifier`.
    ///
    /// The leaf certificate's organizational unit is the team identifier
    /// for both Developer ID and Apple Development certificates.
    static func signed(identifier: String, team: String = teamIdentifier) -> String {
        #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)""#
    }

    /// The requirement that the app checks in `imcp-server`.
    static let releaseClient = signed(identifier: serverSigningIdentifier)

    /// The requirement that `imcp-server` checks in the app.
    static let releaseServer = signed(identifier: appSigningIdentifier)

    #if DEBUG
        /// Release requirements extended to unsigned Debug builds.
        ///
        /// Debug builds made with `CODE_SIGNING_ALLOWED=NO` are signed ad hoc,
        /// so the only thing to check is the identifier,
        /// which any process can claim.
        /// This code isn't compiled into Release builds.
        static let debugClient = "(\(releaseClient)) or identifier \"\(serverSigningIdentifier)\""
        static let debugServer =
            "(\(releaseServer)) or identifier \"\(appSigningIdentifier)\" or identifier \"\(unsignedAppSigningIdentifier)\""
    #endif

    /// The requirement for the process that connects to the app.
    static var client: String {
        #if DEBUG
            debugClient
        #else
            releaseClient
        #endif
    }

    /// The requirement for the process that listens on the socket.
    static var server: String {
        #if DEBUG
            debugServer
        #else
            releaseServer
        #endif
    }

    /// Parses `requirement` and throws if it isn't valid requirement language.
    static func compile(_ requirement: String) throws -> SecRequirement {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw Error.invalidRequirement(status)
        }
        return compiled
    }

    /// Checks the running process with `auditToken` against `requirement`.
    ///
    /// - Parameter usesDynamicCode: Whether to validate the process
    ///   from the code directory that the kernel holds for it.
    ///   A sandboxed caller needs this to validate a process outside its container.
    static func check(auditToken: audit_token_t, against requirement: String, usesDynamicCode: Bool) throws {
        let compiled = try compile(requirement)
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        var attributes: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
        if usesDynamicCode {
            attributes[kSecGuestAttributeDynamicCode] = true
        }

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else {
            throw Error.noSuchCode(status)
        }

        let validity = SecCodeCheckValidity(code, [], compiled)
        guard validity == errSecSuccess else {
            throw Error.rejected(validity)
        }
    }
}
