import Foundation
import Network
import dnssd

/// Publishes the helper only to processes on this Mac, without multicast discovery.
///
/// The TXT record gives the protocol version, which iMCP checks before it connects,
/// the process ID, which lets iMCP try the helper it launched or chose first,
/// and whether the helper shows a pairing code, so iMCP connects in the matching way.
@MainActor
final class HelperAdvertisement {
    private var reference: DNSServiceRef?
    private var permissionBrowser: NWBrowser?
    private var continuation: CheckedContinuation<Void, Error>?

    func start(port: UInt16, pairing: Bool) async throws {
        // Browsing also lets macOS present its local network permission prompt.
        let browser = NWBrowser(for: .bonjour(type: HomeHelperPairing.serviceType, domain: "local."), using: .tcp)
        permissionBrowser = browser
        browser.start(queue: .main)
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.finish(DNSServiceErrorType(kDNSServiceErr_Timeout))
        }
        defer { timeout.cancel() }
        // A TXT record is a sequence of length-prefixed key=value strings.
        let record = [
            "\(HomeHelperPairing.protocolVersionTXTKey)=\(HomeHelperPairing.protocolVersion)",
            "\(HomeHelperPairing.processIDTXTKey)=\(ProcessInfo.processInfo.processIdentifier)",
            pairing ? "\(HomeHelperPairing.pairingTXTKey)=1" : nil,
        ].compactMap { $0 }.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let result = DNSServiceRegister(
                &reference,
                0,
                kDNSServiceInterfaceIndexLocalOnly,
                "iMCP Helper",
                HomeHelperPairing.serviceType,
                "local.",
                "localhost.",
                port.bigEndian,
                UInt16(record.count),
                record,
                { _, _, error, _, _, _, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let advertiser = Unmanaged<HelperAdvertisement>.fromOpaque(context).takeUnretainedValue()
                        advertiser.finish(error)
                    }
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            if result != kDNSServiceErr_NoError { finish(result); return }
            guard let reference else { finish(DNSServiceErrorType(kDNSServiceErr_Unknown)); return }
            let queueResult = DNSServiceSetDispatchQueue(reference, .main)
            if queueResult != kDNSServiceErr_NoError { finish(queueResult) }

        }
    }

    private func finish(_ error: DNSServiceErrorType) {
        let continuation = continuation
        self.continuation = nil
        permissionBrowser?.cancel()
        permissionBrowser = nil
        if error == kDNSServiceErr_NoError {
            continuation?.resume()
        } else {
            stop()
            continuation?.resume(
                throwing: HomeError(
                    "iMCP Helper Bonjour registration failed (\(error)). Allow iMCP Helper in System Settings → Privacy & Security → Local Network, then retry."
                )
            )
        }
    }

    func stop() {
        permissionBrowser?.cancel()
        permissionBrowser = nil
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil
    }
}
