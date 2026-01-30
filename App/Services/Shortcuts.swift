import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("shortcuts")

final class ShortcutsService: Service {
    static let shared = ShortcutsService()

    private let shortcutsPath = "/usr/bin/shortcuts"
    private let executionTimeout: Duration = .seconds(300)

    var tools: [Tool] {
        Tool(
            name: "shortcuts_list",
            description: "List all available shortcuts on this Mac",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Shortcuts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.listShortcuts()
        }

        Tool(
            name: "shortcuts_run",
            description: "Run a shortcut by name, optionally with text input",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "The name of the shortcut to run"
                    ),
                    "input": .string(
                        description: "Optional text input to pass to the shortcut"
                    ),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Run Shortcut",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case let .string(name) = arguments["name"] else {
                throw NSError(
                    domain: "ShortcutsError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Shortcut name is required"]
                )
            }

            let input = arguments["input"]?.stringValue

            return try await self.runShortcut(name: name, input: input)
        }
    }

    // MARK: - Private Implementation

    private func runProcess(_ process: Process) async throws {
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    private func listShortcuts() async throws -> Value {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsPath)
        process.arguments = ["list"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        defer {
            outputHandle.closeFile()
            errorHandle.closeFile()
        }

        do {
            try await runProcess(process)
        } catch {
            log.error("Failed to run shortcuts command: \(error.localizedDescription)")
            throw NSError(
                domain: "ShortcutsError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to run shortcuts command: \(error.localizedDescription)"
                ]
            )
        }

        let outputData = (try? outputHandle.readToEnd()) ?? Data()
        let errorData = (try? errorHandle.readToEnd()) ?? Data()

        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            log.error("shortcuts list failed: \(errorMessage)")
            throw NSError(
                domain: "ShortcutsError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "shortcuts list failed: \(errorMessage)"]
            )
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            return .array([])
        }

        let shortcuts =
            output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        log.info("Found \(shortcuts.count) shortcuts")

        return .array(shortcuts.map { .string($0) })
    }

    private func runShortcut(name: String, input: String?) async throws -> Value {
        log.info("Running shortcut: \(name, privacy: .public)")

        let tempDir = FileManager.default.temporaryDirectory
        let outputFileURL = tempDir.appendingPathComponent("shortcut_output_\(UUID().uuidString).txt")

        var arguments = ["run", name, "--output-path", outputFileURL.path]
        var inputFileURL: URL?

        if let input = input {
            let inputURL = tempDir.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
            arguments.append(contentsOf: ["--input-path", inputURL.path])
            inputFileURL = inputURL
        }

        defer {
            if let inputURL = inputFileURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
            try? FileManager.default.removeItem(at: outputFileURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsPath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let errorHandle = errorPipe.fileHandleForReading
        defer { errorHandle.closeFile() }

        var errorData = Data()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.runProcess(process)
                }

                group.addTask {
                    try await Task.sleep(for: self.executionTimeout)
                    process.terminate()
                    throw NSError(
                        domain: "ShortcutsError",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Shortcut '\(name)' timed out after 5 minutes"
                        ]
                    )
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            errorData = (try? errorHandle.readToEnd()) ?? Data()
            if !errorData.isEmpty {
                let stderrMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                log.error("Shortcut '\(name, privacy: .public)' stderr: \(stderrMessage, privacy: .public)")
            }
            log.error("Failed to run shortcut '\(name, privacy: .public)': \(error.localizedDescription)")
            throw error
        }

        if errorData.isEmpty {
            errorData = (try? errorHandle.readToEnd()) ?? Data()
        }

        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            log.error("Shortcut '\(name, privacy: .public)' failed: \(errorMessage)")
            throw NSError(
                domain: "ShortcutsError",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Shortcut '\(name)' failed: \(errorMessage)"]
            )
        }

        var output: String?
        if FileManager.default.fileExists(atPath: outputFileURL.path) {
            output = try? String(contentsOf: outputFileURL, encoding: .utf8)
        }

        log.info("Shortcut '\(name, privacy: .public)' completed successfully")

        if let output = output, !output.isEmpty {
            return .object([
                "success": .bool(true),
                "shortcut": .string(name),
                "output": .string(output),
            ])
        }

        return .object([
            "success": .bool(true),
            "shortcut": .string(name),
        ])
    }
}
