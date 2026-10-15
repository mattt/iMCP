import SwiftUI

struct AlarmsPhoneService: PhoneService {
    let domain = CompanionDomain.alarms
    func call(_ tool: String, _ args: CompanionArguments) async throws -> Value {
        throw CompanionError("Alarms aren't available in this build.")
    }
    func status() async -> Value { [:] }
    func requestAuthorization() async throws {}
    func sync(into outbox: CompanionOutbox) async throws {}
    func startBackgroundDelivery() async {}
    func stopBackgroundDelivery() async {}
}

struct AlarmListView: View {
    var body: some View { Text("Alarms") }
}
