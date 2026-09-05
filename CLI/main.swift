import Logging
import ServiceLifecycle

var log = Logger(label: "me.mattt.iMCP.server") { StreamLogHandler.standardError(label: $0) }
#if DEBUG
    log.logLevel = .debug
#else
    log.logLevel = .warning
#endif

// `.gracefullyShutdownGroup` is load-bearing: `MCPService.run()` returns
// when the Bonjour connection to the menubar app drops. With the library
// default of `.cancelGroup`, that return raises `ServiceGroupError` at the
// top level → Swift runtime fatal error. See ServiceGroupConfigurationTests.
let lifecycle = ServiceGroup(
    configuration: .init(
        services: [
            .init(
                service: MCPService(),
                successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: .gracefullyShutdownGroup
            )
        ],
        gracefulShutdownSignals: [.sigint, .sigterm],
        logger: log
    )
)

try await lifecycle.run()
