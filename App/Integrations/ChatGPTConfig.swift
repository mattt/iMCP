import Foundation
import TOML

/// A safe edit of the `config.toml` file that ChatGPT and Codex read.
///
/// The file holds the person's other settings, and swift-toml has no
/// format-preserving document to round-trip (see the package notes in
/// `ChatGPT.showConfigurationPanel`). So this parses the file with swift-toml,
/// makes the smallest text edit that sets `mcp_servers.iMCP.command`,
/// and parses the result again before anyone writes it:
/// the result must parse, its iMCP command must be the new value,
/// and every other key and value must be unchanged.
///
/// An iMCP entry that the text edit cannot update without guessing —
/// a quoted or dotted key, an inline table, or an array of tables —
/// is refused, and so is a file that does not parse.
enum ChatGPTConfig {
    enum ConfigError: LocalizedError {
        case doesNotParse(String)
        case ambiguousIMCPEntry
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .doesNotParse(let detail):
                "That file is not valid TOML, so iMCP left it unchanged. \(detail) "
                    + "Add iMCP in ChatGPT instead: open ChatGPT Settings > MCP servers, "
                    + "add a STDIO server named iMCP, and paste the server command."
            case .ambiguousIMCPEntry:
                "That file already sets up iMCP in a form iMCP cannot update safely, "
                    + "so iMCP left it unchanged. "
                    + "Add iMCP in ChatGPT instead: open ChatGPT Settings > MCP servers, "
                    + "add a STDIO server named iMCP, and paste the server command."
            case .verificationFailed:
                "iMCP could not check its edit safely, so it left that file unchanged. "
                    + "Add iMCP in ChatGPT instead: open ChatGPT Settings > MCP servers, "
                    + "add a STDIO server named iMCP, and paste the server command."
            }
        }
    }

    /// Returns `original` edited so that `mcp_servers.iMCP.command` is `command`.
    ///
    /// - Throws: `ConfigError` when the file does not parse,
    ///   when its iMCP entry is in an ambiguous form,
    ///   or when the edited text does not check out.
    static func updatedConfig(original: String, command: String) throws -> String {
        let before = try parse(original)

        let edited = try textEdit(original: original, tree: before, command: command)

        let after = try parse(edited)
        guard commandValue(in: after) == command else { throw ConfigError.verificationFailed }

        var expected = before
        setCommand(command, in: &expected)
        guard expected.isEquivalent(to: after) else { throw ConfigError.verificationFailed }

        return edited
    }

    /// The `command` for the iMCP server in a parsed file, if any.
    static func commandValue(in tree: DynamicTOMLValue) -> String? {
        guard case .table(let root) = tree,
            case .table(let servers)? = root["mcp_servers"],
            case .table(let imcp)? = servers["iMCP"],
            case .string(let command)? = imcp["command"]
        else { return nil }
        return command
    }

    // MARK: - Parsing

    private static func parse(_ text: String) throws -> DynamicTOMLValue {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .table([:]) }
        do {
            return try TOMLDecoder().decode(DynamicTOMLValue.self, from: text)
        } catch {
            throw ConfigError.doesNotParse(String(describing: error))
        }
    }

    private static func setCommand(_ command: String, in tree: inout DynamicTOMLValue) {
        guard case .table(var root) = tree else { return }
        var servers: [String: DynamicTOMLValue]
        if case .table(let existing)? = root["mcp_servers"] {
            servers = existing
        } else {
            servers = [:]
        }
        var imcp: [String: DynamicTOMLValue]
        if case .table(let existing)? = servers["iMCP"] {
            imcp = existing
        } else {
            imcp = [:]
        }
        imcp["command"] = .string(command)
        servers["iMCP"] = .table(imcp)
        root["mcp_servers"] = .table(servers)
        tree = .table(root)
    }

    // MARK: - Text edit

    private static let tableHeader = "[mcp_servers.iMCP]"

    private static func textEdit(original: String, tree: DynamicTOMLValue, command: String) throws -> String {
        let commandLine = "command = \(escapedBasicString(command))"

        guard case .table(let root) = tree else { throw ConfigError.verificationFailed }
        let servers = root["mcp_servers"]
        if let servers, !isTable(servers) { throw ConfigError.ambiguousIMCPEntry }
        let existingIMCP: DynamicTOMLValue?
        if case .table(let serversTable)? = servers {
            existingIMCP = serversTable["iMCP"]
        } else {
            existingIMCP = nil
        }

        var lines = original.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let states = lineStates(lines)

        if let existingIMCP {
            // An entry that is not a plain table cannot be edited by line.
            guard isTable(existingIMCP) else { throw ConfigError.ambiguousIMCPEntry }
            guard
                let headerIndex = lines.indices.first(where: {
                    states[$0].startsSection && isIMCPHeader(lines[$0])
                })
            else {
                // Quoted keys, dotted keys, and inline tables land here.
                throw ConfigError.ambiguousIMCPEntry
            }

            let end = sectionEnd(from: headerIndex, lines: lines, states: states)
            let commandIndexes = (headerIndex + 1 ..< end).filter {
                !states[$0].isInMultilineString
                    && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("command")
                    && isCommandKeyLine(lines[$0])
            }
            if let commandIndex = commandIndexes.first {
                lines[commandIndex] = commandLine
            } else {
                lines.insert(commandLine, at: headerIndex + 1)
            }
            return lines.joined(separator: "\n") + "\n"
        }

        if !lines.isEmpty { lines.append("") }
        lines.append(tableHeader)
        lines.append(commandLine)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isTable(_ value: DynamicTOMLValue) -> Bool {
        if case .table = value { return true }
        return false
    }

    /// Whether a line is the standard iMCP table header, with an optional trailing comment.
    ///
    /// Quoted spellings of the same header do not match, on purpose:
    /// they are refused as ambiguous instead.
    private static func isIMCPHeader(_ line: String) -> Bool {
        let beforeComment =
            line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return beforeComment.trimmingCharacters(in: .whitespaces) == tableHeader
    }

    /// Whether a line sets a bare `command` key, as in `command = ...` or `command=...`.
    private static func isCommandKeyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("command") else { return false }
        let rest = trimmed.dropFirst("command".count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("=")
    }

    /// The line after a section: its next section header, or the end of the file.
    private static func sectionEnd(from headerIndex: Int, lines: [String], states: [LineState]) -> Int {
        for index in (headerIndex + 1) ..< lines.count where states[index].startsSection {
            return index
        }
        return lines.count
    }

    // MARK: - Line scanning

    /// What the scanner knows about a line before its text starts.
    struct LineState {
        /// The line opens a section while outside any string and at bracket depth zero.
        var startsSection = false
        /// The line begins inside a multiline string, so its text is not keys or headers.
        var isInMultilineString = false
    }

    /// Scans lines once, tracking multiline strings and array brackets.
    ///
    /// A line that starts with `[` inside an array or a string is a value, not a header,
    /// and a header line is a section only at bracket depth zero.
    static func lineStates(_ lines: [String]) -> [LineState] {
        var states: [LineState] = []
        var inMultilineBasic = false
        var inMultilineLiteral = false
        var bracketDepth = 0

        for line in lines {
            var state = LineState()
            state.isInMultilineString = inMultilineBasic || inMultilineLiteral
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            state.startsSection =
                !state.isInMultilineString && bracketDepth == 0 && trimmed.hasPrefix("[")
            states.append(state)

            // Walk the line, skipping string contents and comments.
            var index = line.startIndex
            var inBasic = false
            var inLiteral = false
            while index < line.endIndex {
                if inMultilineBasic {
                    if line[index...].hasPrefix("\"\"\"") {
                        inMultilineBasic = false
                        index = line.index(index, offsetBy: 3)
                    } else {
                        index = line.index(after: index)
                    }
                    continue
                }
                if inMultilineLiteral {
                    if line[index...].hasPrefix("'''") {
                        inMultilineLiteral = false
                        index = line.index(index, offsetBy: 3)
                    } else {
                        index = line.index(after: index)
                    }
                    continue
                }
                if inBasic {
                    if line[index] == "\\" {
                        index = line.index(index, offsetBy: min(2, line.distance(from: index, to: line.endIndex)))
                    } else {
                        if line[index] == "\"" { inBasic = false }
                        index = line.index(after: index)
                    }
                    continue
                }
                if inLiteral {
                    if line[index] == "'" { inLiteral = false }
                    index = line.index(after: index)
                    continue
                }
                // Not in any string.
                if line[index...].hasPrefix("\"\"\"") {
                    inMultilineBasic = true
                    index = line.index(index, offsetBy: 3)
                    continue
                }
                if line[index...].hasPrefix("'''") {
                    inMultilineLiteral = true
                    index = line.index(index, offsetBy: 3)
                    continue
                }
                switch line[index] {
                case "\"": inBasic = true
                case "'": inLiteral = true
                case "#":
                    index = line.endIndex
                    continue
                case "[": bracketDepth += 1
                case "]": bracketDepth = max(0, bracketDepth - 1)
                default: break
                }
                index = line.index(after: index)
            }
        }
        return states
    }

    // MARK: - String escaping

    /// A TOML basic string for `value`, with quotes, backslashes, and control characters escaped.
    static func escapedBasicString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}

/// A TOML document as a tree of values, decoded with swift-toml for checking edits.
///
/// Equality is a separate method so that two `nan` floats count as the same value.
enum DynamicTOMLValue: Decodable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case offsetDateTime(Date)
    case localDateTime(LocalDateTime)
    case localDate(LocalDate)
    case localTime(LocalTime)
    case array([DynamicTOMLValue])
    case table([String: DynamicTOMLValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: DynamicTOMLValue].self) {
            self = .table(value)
        } else if let value = try? container.decode([DynamicTOMLValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .float(value)
        } else if let value = try? container.decode(Date.self) {
            self = .offsetDateTime(value)
        } else if let value = try? container.decode(LocalDateTime.self) {
            self = .localDateTime(value)
        } else if let value = try? container.decode(LocalDate.self) {
            self = .localDate(value)
        } else if let value = try? container.decode(LocalTime.self) {
            self = .localTime(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported TOML value")
        }
    }

    func isEquivalent(to other: DynamicTOMLValue) -> Bool {
        switch (self, other) {
        case (.string(let a), .string(let b)): a == b
        case (.integer(let a), .integer(let b)): a == b
        case (.float(let a), .float(let b)): a == b || (a.isNaN && b.isNaN)
        case (.boolean(let a), .boolean(let b)): a == b
        case (.offsetDateTime(let a), .offsetDateTime(let b)): a == b
        case (.localDateTime(let a), .localDateTime(let b)): a == b
        case (.localDate(let a), .localDate(let b)): a == b
        case (.localTime(let a), .localTime(let b)): a == b
        case (.array(let a), .array(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.isEquivalent(to: $1) }
        case (.table(let a), .table(let b)):
            a.count == b.count
                && a.allSatisfy { key, value in
                    guard let otherValue = b[key] else { return false }
                    return value.isEquivalent(to: otherValue)
                }
        default: false
        }
    }
}
