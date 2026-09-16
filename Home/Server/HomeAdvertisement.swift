import Foundation
import Network
import dnssd

/// Publishes the helper only to processes on this Mac, without multicast discovery.
@MainActor
final class HomeAdvertisement {
    private var reference: DNSServiceRef?
    private var permissionBrowser: NWBrowser?
    private var continuation: CheckedContinuation<Void, Error>?

    func start(port: UInt16) async throws {
        // Browsing also lets macOS present its local network permission prompt.
        let browser = NWBrowser(for: .bonjour(type: "_imcp-home._tcp", domain: "local."), using: .tcp)
        permissionBrowser = browser
        browser.start(queue: .main)
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.finish(DNSServiceErrorType(kDNSServiceErr_Timeout))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let result = DNSServiceRegister(
                &reference,
                0,
                kDNSServiceInterfaceIndexLocalOnly,
                "iMCP Home",
                "_imcp-home._tcp",
                "local.",
                "localhost.",
                port.bigEndian,
                0,
                nil,
                { _, _, error, _, _, _, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let advertiser = Unmanaged<HomeAdvertisement>.fromOpaque(context).takeUnretainedValue()
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
                    "Home helper Bonjour registration failed (\(error)). Allow iMCP Home in System Settings → Privacy & Security → Local Network, then retry."
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
