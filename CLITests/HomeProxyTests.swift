import AppKit
import XCTest

final class HomeProxyTests: XCTestCase {
    @MainActor
    func testLiveLaunchAndRecovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["IMCP_HELPER_PATH"] else {
            throw XCTSkip("Set IMCP_HELPER_PATH to run the signed helper integration test.")
        }
        let backend = HomeService(helperURL: URL(fileURLWithPath: path))
        let initial = await backend.isActivated
        XCTAssertFalse(initial)
        try await backend.activate()
        let active = await backend.isActivated
        XCTAssertTrue(active)
        let homes = try await backend.call("homes_list", [:])
        XCTAssertNotEqual(homes, .null)
        do {
            _ = try await backend.call("accessories_get", ["accessory": "invalid"])
            XCTFail("The helper must report invalid accessory IDs.")
        } catch let error as HomeError {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let helper = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == "co.dododo.iMCP.Helper"
            }
        )
        XCTAssertTrue(helper.forceTerminate())
        for _ in 0 ..< 50 {
            if helper.isTerminated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(helper.isTerminated)
        let recovered = try await backend.call("homes_list", [:])
        XCTAssertEqual(recovered, homes)
        let reactivated = await backend.isActivated
        XCTAssertTrue(reactivated)
    }
}
