struct FinancePhoneService: PhoneService {
    let domain = CompanionDomain.finance
    func call(_ tool: String, _ args: CompanionArguments) async throws -> Value {
        throw CompanionError("Finance isn't available in this build.")
    }
    func status() async -> Value { [:] }
    func requestAuthorization() async throws {}
    func sync(into outbox: CompanionOutbox) async throws {}
    func startBackgroundDelivery() async {}
    func stopBackgroundDelivery() async {}
}
