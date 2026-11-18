import XCTest

final class TailscaleEnablementLinkTests: XCTestCase {
    func testFindsTheAddressInTheNodesError() {
        let message =
            "Funnel is not enabled on your tailnet. To enable, visit: https://login.tailscale.com/f/funnel?node=nABC123CNTRL"
        XCTAssertEqual(
            TailscaleEnablementLink.url(in: message)?.absoluteString,
            "https://login.tailscale.com/f/funnel?node=nABC123CNTRL"
        )
    }

    func testDropsPunctuationThatEndsTheSentence() {
        let message = "Enable HTTPS at https://login.tailscale.com/admin/dns."
        XCTAssertEqual(
            TailscaleEnablementLink.url(in: message)?.absoluteString,
            "https://login.tailscale.com/admin/dns"
        )
    }

    func testIgnoresAddressesThatAreNotTailscales() {
        XCTAssertNil(TailscaleEnablementLink.url(in: "See https://example.com/f/funnel?node=1"))
        XCTAssertNil(TailscaleEnablementLink.url(in: "See https://tailscale.com.evil.example/f/funnel"))
        XCTAssertNil(TailscaleEnablementLink.url(in: "http://login.tailscale.com/f/funnel"))
        XCTAssertNil(TailscaleEnablementLink.url(in: "no address here"))
    }
}

final class TailscaleChecklistTests: XCTestCase {
    private func status(_ kind: ChecklistItem.Kind, _ items: [ChecklistItem]) -> ChecklistItem.Status? {
        items.first { $0.kind == kind }?.status
    }

    func testSignedOutAsksForSignInFirst() {
        let url = URL(string: "https://login.tailscale.com/a/abc")
        let items = TailscaleChecklist.items(
            .init(node: .needsLogin(url), funnelAllowed: nil, publicAddress: .off, wantsPublicAddress: true)
        )
        XCTAssertEqual(status(.signedIn, items), .needsAction(link: url))
        XCTAssertEqual(status(.online, items), .pending)
        XCTAssertEqual(status(.funnelAllowed, items), .pending, "nothing later is asked yet")
    }

    func testPrivateAccessStopsAfterTheName() {
        let items = TailscaleChecklist.items(
            .init(
                node: .running(dnsName: "mac.example.ts.net"),
                funnelAllowed: nil,
                publicAddress: .off,
                wantsPublicAddress: false
            )
        )
        XCTAssertEqual(items.map(\.kind), [.signedIn, .online, .name])
        XCTAssertTrue(items.allSatisfy(\.isDone))
    }

    func testMissingNameNeedsAction() {
        let items = TailscaleChecklist.items(
            .init(node: .running(dnsName: nil), funnelAllowed: nil, publicAddress: .off, wantsPublicAddress: false)
        )
        XCTAssertEqual(status(.name, items), .needsAction(link: nil))
    }

    func testFunnelFailureCarriesTheLinkFromTheError() {
        let message = "Funnel not enabled. Visit https://login.tailscale.com/f/funnel?node=n1"
        let items = TailscaleChecklist.items(
            .init(
                node: .running(dnsName: "mac.ts.net"),
                funnelAllowed: false,
                publicAddress: .failed(message),
                wantsPublicAddress: true
            )
        )
        XCTAssertEqual(
            status(.funnelAllowed, items),
            .needsAction(link: URL(string: "https://login.tailscale.com/f/funnel?node=n1"))
        )
        XCTAssertEqual(status(.publicAddress, items), .pending)
    }

    func testWaitingForApprovalShowsAWaitingState() {
        var inputs = TailscaleChecklist.Inputs(
            node: .running(dnsName: "mac.ts.net"),
            funnelAllowed: false,
            publicAddress: .failed("visit https://login.tailscale.com/f/funnel?node=n1"),
            wantsPublicAddress: true
        )
        inputs.isWaitingForApproval = true
        let items = TailscaleChecklist.items(inputs)
        XCTAssertEqual(status(.funnelAllowed, items), .waiting)
        XCTAssertEqual(items.first { $0.kind == .funnelAllowed }?.detail, "Waiting for you to approve in Tailscale…")
    }

    func testAllDoneWhenThePublicAddressIsActive() {
        let url = URL(string: "https://mac.ts.net/mcp")!
        let items = TailscaleChecklist.items(
            .init(
                node: .running(dnsName: "mac.ts.net"),
                funnelAllowed: true,
                publicAddress: .active(url),
                wantsPublicAddress: true
            )
        )
        XCTAssertTrue(items.allSatisfy(\.isDone))
        XCTAssertEqual(items.last?.detail, "https://mac.ts.net/mcp")
    }

    func testAllowedButNotYetOnIsWaiting() {
        let items = TailscaleChecklist.items(
            .init(
                node: .running(dnsName: "mac.ts.net"),
                funnelAllowed: true,
                publicAddress: .off,
                wantsPublicAddress: true
            )
        )
        XCTAssertEqual(status(.publicAddress, items), .waiting)
    }
}

final class CloudflareChecklistTests: XCTestCase {
    private func inputs(
        signedIn: Bool = true,
        domains: [String] = ["example.com"],
        host: String = "",
        binary: Bool = true
    ) -> CloudflareChecklist.Inputs {
        .init(
            isSignedIn: signedIn,
            activeDomains: domains,
            selectedDomain: nil,
            hostnameInput: host,
            isBinaryAvailable: binary
        )
    }

    func testSignedOutShowsEveryPrerequisiteWithItsReason() {
        let items = CloudflareChecklist.items(inputs(signedIn: false, domains: []))
        XCTAssertEqual(
            items.first { $0.kind == .cloudflareAccount }?.status,
            .needsAction(link: CloudflareChecklist.accountSignupURL)
        )
        XCTAssertEqual(items.first { $0.kind == .domain }?.status, .pending)
        XCTAssertFalse(CloudflareChecklist.isReady(items))
    }

    func testSignedInWithoutAnActiveDomainExplainsNameServers() {
        let items = CloudflareChecklist.items(inputs(domains: []))
        let domain = items.first { $0.kind == .domain }
        XCTAssertEqual(domain?.status, .needsAction(link: CloudflareChecklist.addSiteURL))
        XCTAssertTrue(domain?.detail?.contains("name servers") == true)
    }

    func testReadyOnlyWithAccountDomainSignInAndHostname() {
        XCTAssertFalse(CloudflareChecklist.isReady(CloudflareChecklist.items(inputs())), "no hostname yet")
        XCTAssertTrue(CloudflareChecklist.isReady(CloudflareChecklist.items(inputs(host: "imcp"))))
        XCTAssertFalse(CloudflareChecklist.isReady(CloudflareChecklist.items(inputs(host: "imcp.other.org"))))
    }

    func testHostnamesAreCompletedOrRejected() {
        XCTAssertEqual(CloudflareChecklist.fullHostname(input: "imcp", domain: "example.com"), "imcp.example.com")
        XCTAssertEqual(
            CloudflareChecklist.fullHostname(input: " IMCP.example.com ", domain: "example.com"),
            "imcp.example.com"
        )
        XCTAssertEqual(CloudflareChecklist.fullHostname(input: "example.com", domain: "example.com"), "example.com")
        XCTAssertNil(CloudflareChecklist.fullHostname(input: "imcp.other.org", domain: "example.com"))
        XCTAssertNil(CloudflareChecklist.fullHostname(input: "bad name", domain: "example.com"))
        XCTAssertNil(CloudflareChecklist.fullHostname(input: "", domain: "example.com"))
    }

    func testPermissionListMatchesTheCallsTheClientMakes() {
        let names = CloudflareChecklist.requiredPermissions.map { "\($0.scope) \($0.name) \($0.access)" }
        XCTAssertEqual(
            names,
            [
                "Zone Zone Read", "Zone DNS Edit", "Account Account Settings Read", "Account Cloudflare Tunnel Edit",
            ]
        )
    }
}
