import Foundation

// The configuration that the Mac owns and a paired iPhone or iPad learns.
// This file uses only Foundation, so the Mac app, the iOS app, and tests compile it.
//
// The Mac builds a `MobileConfiguration` from its settings and live state, numbers it
// with a revision that only goes up, and sends it in the welcome on every authenticated
// connection and, while the phone is connected, with the `config_apply` tool when the
// Mac's settings change. The phone keeps the newest revision it has seen, follows its
// route order, and answers `config_apply` with the revision it holds, which the Mac shows.

enum MobileConfigLink {
    /// The tool that the Mac calls on the phone to hand it a new configuration.
    static let applyTool = "config_apply"
}

/// A way to reach the Mac. The cases mirror `MobileTransportMode`'s concrete routes.
enum MobileRouteKind: String, Codable, CaseIterable, Sendable {
    case local
    case cloudflare
    case tailscaleVPN
    case tailscaleFunnel

    /// The order the Mac offers when its owner hasn't chosen one.
    static let defaultOrder: [MobileRouteKind] = [.local, .cloudflare, .tailscaleVPN, .tailscaleFunnel]

    var mode: MobileTransportMode {
        switch self {
        case .local: return .localOnly
        case .cloudflare: return .cloudflare
        case .tailscaleVPN: return .tailscaleVPN
        case .tailscaleFunnel: return .tailscaleFunnel
        }
    }

    var label: String { mode.shortLabel }
}

/// One route that the Mac offers, with the address to dial.
struct MobileRoute: Codable, Equatable, Identifiable, Sendable {
    var kind: MobileRouteKind
    var label: String
    /// Tailscale VPN: the Mac's tailnet host or address.
    var host: String?
    /// Tailscale VPN: the port of the Mac's listener.
    var port: UInt16?
    /// Tailscale Funnel and Cloudflare Tunnel: the `wss://` URL.
    var url: String?

    var id: MobileRouteKind { kind }
}

/// What the phone needs to know that isn't an address.
struct MobileFeatures: Codable, Equatable, Sendable {
    /// Whether the Mac offers connection and write approvals to the phone.
    var approvals = false
    /// Whether the Mac syncs its tool-call history to the phone.
    var activityHistory = true

    init(approvals: Bool = false, activityHistory: Bool = true) {
        self.approvals = approvals
        self.activityHistory = activityHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvals = try container.decodeIfPresent(Bool.self, forKey: .approvals) ?? false
        activityHistory = try container.decodeIfPresent(Bool.self, forKey: .activityHistory) ?? true
    }
}

/// The routes, order, and settings that the Mac owns. The phone follows it.
struct MobileConfiguration: Codable, Equatable, Sendable {
    static let schema = 1

    /// The shape of this message, so a later change can tell old senders apart.
    var schema = MobileConfiguration.schema
    /// Goes up by one each time the Mac's offer changes. A phone never applies an older one.
    var revision: Int
    var macName: String
    /// The Mac's Bonjour service name.
    var service: String
    /// The mode the Mac suggests. A phone left on Automatic follows it.
    var recommendedMode: MobileTransportMode
    /// The routes to try for Automatic, in order. A route the Mac doesn't offer is absent.
    var routes: [MobileRoute]
    var features: MobileFeatures

    init(
        schema: Int = MobileConfiguration.schema,
        revision: Int,
        macName: String,
        service: String,
        recommendedMode: MobileTransportMode = .automatic,
        routes: [MobileRoute],
        features: MobileFeatures = MobileFeatures()
    ) {
        self.schema = schema
        self.revision = revision
        self.macName = macName
        self.service = service
        self.recommendedMode = recommendedMode
        self.routes = routes
        self.features = features
    }

    private enum CodingKeys: String, CodingKey {
        case schema, revision, macName, service, recommendedMode, routes, features
    }

    /// A route from a newer Mac that this phone doesn't know decodes to nil and is skipped.
    private struct LossyRoute: Decodable {
        var route: MobileRoute?
        init(from decoder: Decoder) throws {
            route = try? MobileRoute(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        revision = try container.decode(Int.self, forKey: .revision)
        macName = try container.decodeIfPresent(String.self, forKey: .macName) ?? ""
        service = try container.decode(String.self, forKey: .service)
        let mode = try container.decodeIfPresent(String.self, forKey: .recommendedMode)
        recommendedMode = mode.flatMap(MobileTransportMode.init(rawValue:)) ?? .automatic
        routes = try container.decodeIfPresent([LossyRoute].self, forKey: .routes)?.compactMap(\.route) ?? []
        features = try container.decodeIfPresent(MobileFeatures.self, forKey: .features) ?? MobileFeatures()
    }

    /// Whether a phone holding `current` should replace it with this one.
    /// An equal or older revision never replaces a newer one.
    func supersedes(_ current: MobileConfiguration?) -> Bool {
        guard let current else { return true }
        return revision > current.revision
    }

    func route(_ kind: MobileRouteKind) -> MobileRoute? {
        routes.first { $0.kind == kind }
    }

    var tailnetHost: String? { route(.tailscaleVPN)?.host }
    var tailnetPort: UInt16? { route(.tailscaleVPN)?.port }
    var funnelURL: String? { route(.tailscaleFunnel)?.url }
    var cloudflareURL: String? { route(.cloudflare)?.url }

    /// The endpoints to dial for `mode`, in this configuration's order.
    /// Automatic follows the Mac: it uses the mode the Mac recommends,
    /// and when that is Automatic too, every route in the Mac's order.
    func candidates(for mode: MobileTransportMode) -> [MobileTransportCandidate] {
        let effective = mode == .automatic ? recommendedMode : mode
        return routes.compactMap { route in
            guard effective == .automatic || route.kind.mode == effective else { return nil }
            switch route.kind {
            case .local:
                return .bonjour(service: service)
            case .tailscaleVPN:
                let host = route.host?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let host, !host.isEmpty else { return nil }
                let port = (route.port ?? 0) > 0 ? route.port! : MobileLink.defaultRemotePort
                return .tailscaleVPN(host: host, port: port)
            case .tailscaleFunnel:
                return MobileLink.normalizedWebSocketURL(route.url).flatMap(URL.init(string:))
                    .map { .tailscaleFunnel(url: $0) }
            case .cloudflare:
                return MobileLink.normalizedWebSocketURL(route.url).flatMap(URL.init(string:))
                    .map { .cloudflare(url: $0) }
            }
        }
    }
}

/// The body of the Mac's `config_apply` call.
struct MobileConfigApplyRequest: Codable, Equatable, Sendable {
    var configuration: MobileConfiguration
}

/// The phone's answer: the revision it holds after the call, and whether this call changed it.
struct MobileConfigApplyResponse: Codable, Equatable, Sendable {
    var revision: Int
    var applied: Bool
}

// MARK: - What the phone keeps

/// The routes a phone knows for its Mac: the Mac's configuration, and the individual
/// addresses from pairing or an older Mac that the phone falls back to without one.
struct MobilePhoneRoutes: Equatable, Sendable {
    var service: String
    var tailnetHost: String?
    var tailnetPort: UInt16?
    var funnelURL: String?
    var cloudflareURL: String?
    var configuration: MobileConfiguration?

    /// Follows `configuration` if it is newer than the one held, or returns nil.
    /// The Mac's routes replace the saved ones: a route it no longer offers is cleared, not kept.
    func applying(_ configuration: MobileConfiguration) -> MobilePhoneRoutes? {
        guard configuration.supersedes(self.configuration) else { return nil }
        return MobilePhoneRoutes(
            service: configuration.service.isEmpty ? service : configuration.service,
            tailnetHost: configuration.tailnetHost,
            tailnetPort: configuration.tailnetPort,
            funnelURL: configuration.funnelURL,
            cloudflareURL: configuration.cloudflareURL,
            configuration: configuration
        )
    }

    /// Takes what the Mac says in its welcome. A Mac that sends a configuration decides everything,
    /// and an older revision changes nothing. A Mac from before configurations only advertises
    /// endpoints, which are merged into the saved ones.
    func updating(from welcome: MobileWelcome) -> MobilePhoneRoutes {
        if let configuration = welcome.configuration { return applying(configuration) ?? self }
        var copy = self
        if let host = welcome.tailnetHost, !host.isEmpty { copy.tailnetHost = host }
        if let port = welcome.tailnetPort, port > 0 { copy.tailnetPort = port }
        if let funnel = MobileLink.normalizedWebSocketURL(welcome.funnelURL) { copy.funnelURL = funnel }
        if let cloudflare = MobileLink.normalizedWebSocketURL(welcome.cloudflareURL) {
            copy.cloudflareURL = cloudflare
        }
        return copy
    }

    /// The endpoints to try for `mode`, in order. Once the Mac has sent a configuration, it decides the order.
    func candidates(for mode: MobileTransportMode) -> [MobileTransportCandidate] {
        if let configuration { return configuration.candidates(for: mode) }
        return mode.candidates(
            service: service,
            tailnetHost: tailnetHost,
            tailnetPort: tailnetPort,
            funnelURL: funnelURL,
            cloudflareURL: cloudflareURL
        )
    }
}

// MARK: - Building from the Mac's state

/// The Mac's settings and live addresses that decide what it offers.
struct MobileMacState: Equatable, Sendable {
    var macName: String
    var service: String
    var recommendedMode: MobileTransportMode = .automatic
    /// The order the owner chose. Missing kinds follow in the default order.
    var order: [MobileRouteKind] = MobileRouteKind.defaultOrder
    var disabled: Set<MobileRouteKind> = []
    var tailnetHost: String?
    var tailnetPort: UInt16?
    var funnelURL: String?
    var cloudflareURL: String?
    var features = MobileFeatures()
}

enum MobileConfigurationBuilder {
    /// One route as the Mac's settings list it, offered or not.
    struct Entry: Equatable, Identifiable, Sendable {
        var kind: MobileRouteKind
        /// Whether the owner has this route on.
        var enabled: Bool
        /// The address that the phone would dial, or nil when the Mac has none yet.
        var address: String?
        /// Whether the route goes into the configuration.
        var isOffered: Bool

        var id: MobileRouteKind { kind }
    }

    /// `order` without repeats, followed by any kind it lacks in the default order.
    static func normalizedOrder(_ order: [MobileRouteKind]) -> [MobileRouteKind] {
        var seen = Set<MobileRouteKind>()
        let given = order.filter { seen.insert($0).inserted }
        return given + MobileRouteKind.defaultOrder.filter { !seen.contains($0) }
    }

    /// Every route in the owner's order, with whether it is on and has an address.
    static func entries(_ state: MobileMacState) -> [Entry] {
        let localOnly = state.recommendedMode == .localOnly
        return normalizedOrder(state.order).map { kind in
            let enabled = !state.disabled.contains(kind)
            var address: String?
            switch kind {
            case .local:
                address = state.service
            case .tailscaleVPN:
                if let host = clean(state.tailnetHost) {
                    let port = (state.tailnetPort ?? 0) > 0 ? state.tailnetPort : nil
                    address = port.map { "\(host):\($0)" } ?? host
                }
            case .tailscaleFunnel:
                address = MobileLink.normalizedWebSocketURL(state.funnelURL)
            case .cloudflare:
                address = MobileLink.normalizedWebSocketURL(state.cloudflareURL)
            }
            // A Mac set to local only offers nothing else.
            let offered = enabled && address != nil && (kind == .local || !localOnly)
            return Entry(kind: kind, enabled: enabled, address: address, isOffered: offered)
        }
    }

    static func build(_ state: MobileMacState, revision: Int) -> MobileConfiguration {
        let routes = entries(state).filter(\.isOffered).map { entry -> MobileRoute in
            var route = MobileRoute(kind: entry.kind, label: entry.kind.label)
            switch entry.kind {
            case .local:
                break
            case .tailscaleVPN:
                route.host = clean(state.tailnetHost)
                route.port = (state.tailnetPort ?? 0) > 0 ? state.tailnetPort : nil
            case .tailscaleFunnel, .cloudflare:
                route.url = entry.address
            }
            return route
        }
        return MobileConfiguration(
            revision: revision,
            macName: state.macName,
            service: state.service,
            recommendedMode: state.recommendedMode,
            routes: routes,
            features: state.features
        )
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension MobileRoute {
    init(kind: MobileRouteKind, label: String) {
        self.init(kind: kind, label: label, host: nil, port: nil, url: nil)
    }
}
