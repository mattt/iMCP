import Foundation
import Security

/// The secret that limits iMCP Helper to the iMCP instance that launched it.
///
/// iMCP makes a new secret for each launch and passes it in the helper's
/// launch environment, which other processes can't read,
/// unlike the launch arguments.
/// iMCP presents it in the experimental capabilities of its `initialize` request,
/// and the helper ends any connection that doesn't present it.
enum HomeHelperSecret {
    static let environmentKey = "IMCP_HELPER_SECRET"
    static let capabilityKey = "app.imcp.helper.secret"

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HomeError("Cannot create a secret for iMCP Helper.")
        }
        return Data(bytes).base64EncodedString()
    }

    /// Compares the secrets in time that depends only on their lengths.
    static func matches(_ presented: String?, _ expected: String) -> Bool {
        guard let presented, !expected.isEmpty else { return false }
        let lhs = Array(presented.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}
