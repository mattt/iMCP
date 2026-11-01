import Network

/// Bonjour helpers that the app uses to find iMCP Helper.
///
/// `imcp-server` connects to the app over a Unix domain socket
/// and doesn't use Bonjour.
enum BonjourDiscovery {
    /// Returns whether `result` is a service advertised by this Mac.
    ///
    /// Bonjour reports a service registered on this Mac on the loopback interface,
    /// and a service from another Mac only on network interfaces.
    static func isLocal(_ result: NWBrowser.Result) -> Bool {
        result.interfaces.contains { $0.type == .loopback }
    }
}
