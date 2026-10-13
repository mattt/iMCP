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
                $0.bundleURL.map(HomeHelperLocator.isHelper(at:)) ?? false
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

final class HomeHelperLocatorTests: XCTestCase {
    private let chosen = URL(fileURLWithPath: "/Users/x/Build/iMCP Helper.app")
    private let system = URL(fileURLWithPath: "/Applications/iMCP Helper.app")
    private let user = URL(fileURLWithPath: "/Users/x/Applications/iMCP Helper.app")
    private let registered = URL(fileURLWithPath: "/Users/x/Dev/iMCP Helper.app")
    private let embedded = URL(fileURLWithPath: "/Applications/iMCP.app/Contents/Helpers/iMCP Helper.app")

    func testChosenHelperWins() {
        let url = HomeHelperLocator.resolve(
            chosen: chosen,
            installed: [system, user],
            registered: registered,
            embedded: embedded,
            isHelper: { _ in true }
        )
        XCTAssertEqual(url, chosen)
    }

    func testFallsBackInOrderWhenChosenIsGone() {
        let url = HomeHelperLocator.resolve(
            chosen: chosen,
            installed: [system, user],
            registered: registered,
            embedded: embedded,
            isHelper: { $0 != self.chosen && $0 != self.system }
        )
        XCTAssertEqual(url, user)
    }

    func testRegisteredThenEmbedded() {
        XCTAssertEqual(
            HomeHelperLocator.resolve(
                chosen: nil,
                installed: [system, user],
                registered: registered,
                embedded: embedded,
                isHelper: { $0 == self.registered || $0 == self.embedded }
            ),
            registered
        )
        XCTAssertEqual(
            HomeHelperLocator.resolve(
                chosen: nil,
                installed: [system, user],
                registered: nil,
                embedded: embedded,
                isHelper: { $0 == self.embedded }
            ),
            embedded
        )
    }

    func testRejectsAppsWithoutTheMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func app(_ name: String, marker: Bool?) throws -> URL {
            let url = directory.appendingPathComponent("\(name).app")
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "test.\(name)", "CFBundlePackageType": "APPL"]
            if let marker { info[HomeHelperLocator.markerKey] = marker }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        XCTAssertTrue(HomeHelperLocator.isHelper(at: try app("Helper", marker: true)))
        XCTAssertFalse(HomeHelperLocator.isHelper(at: try app("Other", marker: nil)))
        XCTAssertFalse(HomeHelperLocator.isHelper(at: try app("Off", marker: false)))
        XCTAssertFalse(HomeHelperLocator.isHelper(at: directory.appendingPathComponent("Missing.app")))
        XCTAssertNil(
            HomeHelperLocator.resolve(
                chosen: try app("Chosen", marker: nil),
                installed: [],
                registered: nil,
                embedded: nil,
                isHelper: HomeHelperLocator.isHelper(at:)
            )
        )
    }

    func testInstallLocations() {
        // The sandbox can't read ~/Applications without a user selection,
        // so only /Applications is searched automatically.
        XCTAssertEqual(
            HomeHelperLocator.installLocations.map(\.path),
            ["/Applications/iMCP Helper.app"]
        )
    }

    func testRunningHelperMatchesTheResolvedPathWithoutReadingInfoPlist() {
        var reads = 0
        let isHelper: (URL) -> Bool = { _ in
            reads += 1
            return false
        }
        XCTAssertTrue(
            HomeHelperLocator.isRunningHelper(
                bundleURL: URL(fileURLWithPath: "/Users/x/Build/./iMCP Helper.app"),
                localizedName: "iMCP Helper",
                helper: chosen,
                isHelper: isHelper
            )
        )
        XCTAssertEqual(reads, 0)
    }

    func testRunningHelperChecksTheMarkerOnlyForAppsNamediMCPHelper() {
        var reads = 0
        let isHelper: (URL) -> Bool = { _ in
            reads += 1
            return true
        }
        XCTAssertFalse(
            HomeHelperLocator.isRunningHelper(
                bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                localizedName: "Safari",
                helper: system,
                isHelper: isHelper
            )
        )
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(
            HomeHelperLocator.isRunningHelper(
                bundleURL: registered,
                localizedName: "iMCP Helper",
                helper: system,
                isHelper: isHelper
            )
        )
        XCTAssertFalse(
            HomeHelperLocator.isRunningHelper(
                bundleURL: nil,
                localizedName: "iMCP Helper",
                helper: system,
                isHelper: isHelper
            )
        )
    }
}
