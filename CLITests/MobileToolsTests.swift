import XCTest

final class MobileToolsTests: XCTestCase {
    private let backend = MobileToolRecorder()

    func testForwardingPreservesToolNameAndArguments() async throws {
        let tools = MobileTools.all(backend: backend)
        for tool in tools {
            let arguments: [String: Value] = ["probe": .string(tool.name)]
            let value = try await tool.callAsFunction(arguments)
            XCTAssertEqual(value, .object(arguments))
        }
        let calls = await backend.names
        XCTAssertEqual(calls, tools.map(\.name))
        XCTAssertEqual(
            Set(calls),
            [
                "health_fetch", "health_statistics", "workouts_fetch", "clinical_records_fetch",
                "finance_accounts_list", "finance_balances_fetch", "finance_transactions_fetch",
                "alarms_list", "alarms_create", "timers_create", "alarms_cancel", "mobile_status",
            ]
        )
        XCTAssertEqual(calls.count, 12)
    }

    func testEachServiceHasItsToolsAndTheStatusTool() {
        func names(_ domain: MobileDomain) -> Set<String> {
            Set(MobileTools.tools(for: domain, backend: backend).map(\.name))
        }
        XCTAssertEqual(
            names(.health),
            ["health_fetch", "health_statistics", "workouts_fetch", "clinical_records_fetch", "mobile_status"]
        )
        XCTAssertEqual(
            names(.finance),
            ["finance_accounts_list", "finance_balances_fetch", "finance_transactions_fetch", "mobile_status"]
        )
        XCTAssertEqual(
            names(.alarms),
            ["alarms_list", "alarms_create", "timers_create", "alarms_cancel", "mobile_status"]
        )
        XCTAssertEqual(MobileTools.domain(of: "timers_create"), .alarms)
        XCTAssertEqual(MobileTools.domain(of: "finance_accounts_list"), .finance)
        XCTAssertNil(MobileTools.domain(of: "mobile_status"))
    }

    func testAnnotationsAreExplicit() {
        let reads: Set<String> = [
            "health_fetch", "health_statistics", "workouts_fetch", "clinical_records_fetch",
            "finance_accounts_list", "finance_balances_fetch", "finance_transactions_fetch",
            "alarms_list", "mobile_status",
        ]
        for tool in MobileTools.all(backend: backend) {
            XCTAssertEqual(tool.annotations.readOnlyHint, reads.contains(tool.name), tool.name)
            XCTAssertEqual(tool.annotations.destructiveHint, tool.name == "alarms_cancel", tool.name)
            XCTAssertEqual(tool.annotations.openWorldHint, false, tool.name)
        }
    }

    func testDescriptionsStateTheLimitsOfEachFramework() throws {
        let tools = MobileTools.all(backend: backend)
        func description(_ name: String) throws -> String {
            try XCTUnwrap(tools.first { $0.name == name }).description
        }
        XCTAssertTrue(try description("alarms_list").contains("Clock"))
        XCTAssertTrue(try description("health_fetch").contains("denied"))
        XCTAssertTrue(try description("health_fetch").contains("synced_at"))
    }

    func testRejectsUnknownArgumentsAndWrongTypes() throws {
        XCTAssertThrowsError(try validate("health_fetch", ["type": "stepCount", "surprise": true]))
        XCTAssertThrowsError(try validate("health_fetch", [:]))
        XCTAssertThrowsError(try validate("health_fetch", ["type": "stepCount", "limit": "10"]))
        XCTAssertThrowsError(try validate("health_fetch", ["type": "stepCount", "limit": 0]))
        XCTAssertThrowsError(try validate("health_fetch", ["type": "stepCount", "limit": 5000]))
        XCTAssertThrowsError(try validate("health_statistics", ["type": "stepCount", "interval": "fortnight"]))
        XCTAssertThrowsError(try validate("clinical_records_fetch", ["type": "photoRecord"]))
        XCTAssertThrowsError(try validate("finance_transactions_fetch", ["status": "lost"]))
        XCTAssertThrowsError(try validate("alarms_cancel", [:]))
        XCTAssertThrowsError(try validate("timers_create", ["title": "Tea", "duration_seconds": 0]))
        XCTAssertThrowsError(try validate("timers_create", ["title": "Tea", "duration_seconds": 1.5]))
        XCTAssertThrowsError(try validate("mobile_status", ["verbose": true]))
    }

    func testAlarmSchedulesCannotBeMixed() throws {
        try validate("alarms_create", ["title": "Flight", "fire_at": "2030-01-01T06:00:00Z"])
        try validate("alarms_create", ["title": "Gym", "hour": 6, "minute": 30, "weekdays": ["monday", "friday"]])
        try validate("alarms_create", ["title": "Wake", "hour": 7, "minute": 0])
        XCTAssertThrowsError(
            try validate("alarms_create", ["title": "Both", "fire_at": "2030-01-01T06:00:00Z", "hour": 6, "minute": 0])
        )
        XCTAssertThrowsError(try validate("alarms_create", ["title": "Late", "hour": 24, "minute": 0]))
        XCTAssertThrowsError(try validate("alarms_create", ["title": "Odd", "hour": 6, "minute": 0, "weekdays": []]))
        XCTAssertThrowsError(
            try validate(
                "alarms_create",
                ["title": "Twice", "hour": 6, "minute": 0, "weekdays": ["monday", "monday"]]
            )
        )
        XCTAssertThrowsError(
            try validate("alarms_create", ["title": "Day", "hour": 6, "minute": 0, "weekdays": ["mon"]])
        )
    }

    func testHealthTypeNamesAcceptFrameworkIdentifiers() {
        XCTAssertEqual(MobileTools.healthTypeName("HKQuantityTypeIdentifierStepCount"), "stepCount")
        XCTAssertEqual(MobileTools.healthTypeName("HKCategoryTypeIdentifierSleepAnalysis"), "sleepAnalysis")
        XCTAssertEqual(MobileTools.healthTypeName("HKClinicalTypeIdentifierAllergyRecord"), "allergyRecord")
        XCTAssertEqual(MobileTools.healthTypeName("heartRate"), "heartRate")
        XCTAssertEqual(MobileTools.healthTypeName("HeartRate"), "heartRate")
    }

    func testDateArgumentsAcceptTimestampsAndDays() throws {
        let arguments = MobileArguments([
            "start": "2026-01-02", "end": "2026-01-03T04:05:06.789Z", "bad": "yesterday",
        ])
        let start = try XCTUnwrap(try arguments.date("start"))
        let end = try XCTUnwrap(try arguments.date("end"))
        XCTAssertLessThan(start, end)
        XCTAssertEqual(end.timeIntervalSince1970, 1_767_413_106.789, accuracy: 0.001)
        XCTAssertThrowsError(try arguments.date("bad"))
        XCTAssertNil(try arguments.date("missing"))
    }

    private func validate(_ name: String, _ input: [String: Value]) throws {
        let tool = try XCTUnwrap(MobileTools.all(backend: backend).first { $0.name == name })
        try ToolInput.validate(input, schema: tool.inputSchema)
    }
}

private actor MobileToolRecorder: MobileBackend {
    var names: [String] = []
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        names.append(tool)
        return .object(input)
    }
}
