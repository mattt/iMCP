import SwiftUI

struct HealthPhoneService: PhoneService {
    let domain = CompanionDomain.health
    func call(_ tool: String, _ args: CompanionArguments) async throws -> Value {
        throw CompanionError("Health isn't available in this build.")
    }
    func status() async -> Value { [:] }
    func requestAuthorization() async throws {}
    func sync(into outbox: CompanionOutbox) async throws {}
    func startBackgroundDelivery() async {}
    func stopBackgroundDelivery() async {}
}

struct HealthAccessView: View {
    var body: some View { Text("Health") }
}
