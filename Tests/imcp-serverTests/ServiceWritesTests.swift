import Foundation
import MCP
import XCTest

/// These tests use a private `UserDefaults` suite and fake services; they change no real data.
final class ServiceWritesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ServiceWritesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A service with one read tool, one tool that says it writes,
    /// and one that doesn't say either way, which MCP treats as a write.
    private final class FakeService: Service, @unchecked Sendable {
        let writesEnabledByDefault: Bool
        let ran = OSAllocatedCounter()

        init(writesEnabledByDefault: Bool) {
            self.writesEnabledByDefault = writesEnabledByDefault
        }

        var tools: [Tool] {
            Tool(
                name: "fake_read",
                description: "Reads",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ) { _ in
                self.ran.increment()
                return "read"
            }
            Tool(
                name: "fake_write",
                description: "Writes",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ) { _ in
                self.ran.increment()
                return "wrote"
            }
            Tool(
                name: "fake_unmarked",
                description: "Doesn't say",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(destructiveHint: true, openWorldHint: false)
            ) { _ in
                self.ran.increment()
                return "wrote"
            }
        }
    }

    private func listed(_ service: FakeService) -> Set<String> {
        Set(service.listedTools(defaults: defaults).map(\.name))
    }

    // MARK: - Classification

    func testAToolThatDoesNotSayItOnlyReadsIsAWrite() {
        let service = FakeService(writesEnabledByDefault: true)
        XCTAssertEqual(service.writeToolNames, ["fake_write", "fake_unmarked"])
        XCTAssertTrue(service.hasWriteTools)
    }

    func testShippedServicesClassifyTheirWriteTools() {
        XCTAssertEqual(
            MusicService.shared.writeToolNames,
            MusicPlaylistWrites.toolNames.union(["music_control"])
        )
        XCTAssertEqual(MailService.shared.writeToolNames, ["mail_compose"])
    }

    // MARK: - Defaults

    func testServicesThatAlreadyHadWritesStartWithThemOn() {
        XCTAssertTrue(MusicService.shared.writesEnabledByDefault)
        XCTAssertTrue(MailService.shared.writesEnabledByDefault)
        XCTAssertTrue(MusicService.shared.areWritesEnabled(defaults: defaults))
    }

    func testANewServiceWithWritesStartsWithThemOff() {
        let service = FakeService(writesEnabledByDefault: false)
        XCTAssertFalse(service.areWritesEnabled(defaults: defaults))
        XCTAssertEqual(listed(service), ["fake_read"])
    }

    func testAChoiceOverridesTheDefaultEitherWay() {
        let off = FakeService(writesEnabledByDefault: true)
        ServiceWrites.setEnabled(false, serviceID: off.serviceID, defaults: defaults)
        XCTAssertFalse(off.areWritesEnabled(defaults: defaults))

        defaults.removePersistentDomain(forName: suiteName)
        let on = FakeService(writesEnabledByDefault: false)
        ServiceWrites.setEnabled(true, serviceID: on.serviceID, defaults: defaults)
        XCTAssertTrue(on.areWritesEnabled(defaults: defaults))
    }

    // MARK: - Listing and refusing

    func testListingHidesWriteToolsWhileOffAndShowsThemWhenOn() {
        let service = FakeService(writesEnabledByDefault: false)
        XCTAssertFalse(service.isToolListed("fake_write", defaults: defaults))
        XCTAssertFalse(service.isToolListed("fake_unmarked", defaults: defaults))
        XCTAssertTrue(service.isToolListed("fake_read", defaults: defaults))

        ServiceWrites.setEnabled(true, serviceID: service.serviceID, defaults: defaults)
        XCTAssertEqual(listed(service), ["fake_read", "fake_write", "fake_unmarked"])
    }

    func testCallsToWriteToolsAreRefusedWhileOffAndChangeNothing() async throws {
        let service = FakeService(writesEnabledByDefault: false)
        for name in ["fake_write", "fake_unmarked"] {
            do {
                _ = try await service.call(tool: name, with: [:], defaults: defaults)
                XCTFail("\(name) ran while writes were off")
            } catch {
                XCTAssertEqual(error as? WritesDisabledError, WritesDisabledError(tool: name))
                XCTAssertTrue("\(error)".contains("Allow writes"))
            }
        }
        XCTAssertEqual(service.ran.value, 0)

        let value = try await service.call(tool: "fake_read", with: [:], defaults: defaults)
        XCTAssertEqual(value, "read")
        XCTAssertEqual(service.ran.value, 1)
    }

    func testCallsRunOnceWritesAreOnAndStopWhenTurnedOffAgain() async throws {
        let service = FakeService(writesEnabledByDefault: false)
        ServiceWrites.setEnabled(true, serviceID: service.serviceID, defaults: defaults)
        let value = try await service.call(tool: "fake_write", with: [:], defaults: defaults)
        XCTAssertEqual(value, "wrote")

        ServiceWrites.setEnabled(false, serviceID: service.serviceID, defaults: defaults)
        do {
            _ = try await service.call(tool: "fake_write", with: [:], defaults: defaults)
            XCTFail("ran after writes were turned off")
        } catch {
            XCTAssertTrue(error is WritesDisabledError)
        }
    }

    func testAnUnknownToolStillGetsNoAnswer() async throws {
        let service = FakeService(writesEnabledByDefault: false)
        let value = try await service.call(tool: "nope", with: [:], defaults: defaults)
        XCTAssertNil(value)
    }

    func testSettingsAreKeptPerService() {
        let a = FakeService(writesEnabledByDefault: false)
        ServiceWrites.setEnabled(true, serviceID: "OtherService", defaults: defaults)
        XCTAssertFalse(a.areWritesEnabled(defaults: defaults))
        XCTAssertEqual(ServiceWrites.settingKey(forService: "NotesService"), "writesEnabled.NotesService")
    }
}

/// A counter that a `Sendable` tool closure can bump.
final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
