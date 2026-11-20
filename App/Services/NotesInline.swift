import Foundation
import TopoText

// This file holds the parts of the Notes service that shape tags, links between notes,
// and smart folders for tool output. They take TopoText's plain values, not a database,
// so that tests can build the values.

/// Returns the result of a read of tags or links, or `nil` if the database's schema doesn't support the read.
///
/// TopoText throws ``NotesError/unsupportedSchema`` from these reads when the database
/// has no column that marks locked notes. The note or page is still readable then,
/// so the caller leaves out the fields that the read supplies instead of failing.
/// Every other error, including cancellation, propagates.
func readIfSupported<T>(_ read: () throws -> T) throws -> T? {
    do {
        return try read()
    } catch NotesError.unsupportedSchema {
        return nil
    }
}

/// The tags of a note as the note's `keywords`: `#name`, in the order the database lists them.
func keywordValues(_ tags: [TopoText.Note.Tag]) -> Value {
    .array(tags.map { .string($0.text) })
}

/// What a lookup found of the note at the other end of a link.
enum LinkedNote: Sendable, Equatable {
    /// Notes lists the note, with this title.
    case found(title: String)
    /// Notes doesn't list the note.
    case missing
    /// Nobody looked for the note, or the lookup failed for another reason.
    case unknown

    /// Looks up the note at the other end of a link.
    ///
    /// - Parameter lookup: Returns the title of the note, or throws if the lookup fails.
    ///
    /// Only ``NotesError/noteNotFound(_:)`` makes the note missing.
    /// Cancellation and ``NotesError/connectionClosed`` propagate,
    /// and any other error leaves the note unknown, so an existing note is never reported as missing.
    init(lookingUp lookup: () throws -> String) throws {
        do {
            self = .found(title: try lookup())
        } catch NotesError.noteNotFound {
            self = .missing
        } catch let error as CancellationError {
            throw error
        } catch NotesError.connectionClosed {
            throw NotesError.connectionClosed
        } catch {
            self = .unknown
        }
    }
}

/// A link between notes as an object for the note's `linkedNotes` or `linkedFrom`.
///
/// - Parameters:
///   - link: The link.
///   - direction: Whether the link leaves the note (`outgoing`) or arrives at it (`incoming`).
///   - other: What a lookup found of the note at the other end.
func linkValue(_ link: TopoText.Note.Link, direction: LinkDirection, other: LinkedNote) -> Value {
    let otherID = direction == .outgoing ? link.targetID : link.sourceID
    var object: [String: Value] = ["@id": .string(otherID.description)]
    if case .found(let title) = other, !title.isEmpty {
        object["name"] = .string(title)
    } else if let label = link.label {
        object["name"] = .string(label)
    }
    // The label can differ from the title, because it is the text of the link, which doesn't follow renames.
    if let label = link.label, label != object["name"]?.stringValue {
        object["linkText"] = .string(label)
    }
    if other == .missing {
        object["isMissing"] = true
    }
    return .object(object)
}

enum LinkDirection: Sendable {
    case outgoing
    case incoming
}

/// A smart folder as an object for tool output, with its rules read from the stored query.
/// - Parameter folderNames: The names of the folders, by identifier, for the name of the parent folder.
func smartFolderValue(_ folder: TopoText.SmartFolder, folderNames: [TopoText.Folder.ID: String]) -> Value {
    var object: [String: Value] = [
        "@id": .string(folder.id.description),
        "@type": "SmartFolder",
        "name": .string(folder.name),
    ]
    if let accountName = folder.account?.name {
        object["account"] = .string(accountName)
    }
    if let parentID = folder.parentID {
        var parent: [String: Value] = ["@id": .string(parentID.description)]
        if let name = folderNames[parentID] {
            parent["name"] = .string(name)
        }
        object["parentFolder"] = .object(parent)
    }
    let query = SmartFolderQuery(folder.query)
    if let rules = query.rules {
        object["rules"] = rules
    }
    if query.includesRecentlyDeleted == true {
        object["includesRecentlyDeleted"] = true
    }
    // The stored text stays available, because rules that this server doesn't know are not explained.
    object["query"] = .string(folder.query)
    return .object(object)
}

/// The query that Notes stores for a smart folder.
///
/// On macOS 27.0.1, Notes stores this query for a smart folder with one tag rule:
///
/// ```json
/// {"type":{"and":[{"deleted":false},{"and":[{"and":[{"deleted":false},{"and":[{"tag":"SMART"}]}]}]}]},"entity":"note"}
/// ```
///
/// Notes stores the tag in capitals, without its `#`.
/// The rules are the value of `type`, with its conjunctions simplified:
/// an `and` with one clause becomes that clause,
/// and a clause that is exactly `{"deleted": <Bool>}` in an `and`, at any depth of nested `and` clauses,
/// is the filter for Recently Deleted, so it moves to ``includesRecentlyDeleted``.
/// For the query above, the rules are `{"tag":"SMART"}`.
/// Notes doesn't document the format, and other kinds of rules have not been observed,
/// so everything else, such as `or` clauses and unknown keys, is passed through as stored.
/// If two `deleted` clauses disagree, only those in the outer `and` are removed.
/// JSON without `type` is kept whole as the rules.
struct SmartFolderQuery: Sendable, Equatable {
    /// The rules of the folder as JSON, or `nil` if the text is not JSON.
    private(set) var rules: Value?
    /// Whether the folder includes Recently Deleted, if the query says so without contradiction.
    private(set) var includesRecentlyDeleted: Bool?

    init(_ text: String) {
        guard let value = try? JSONDecoder().decode(Value.self, from: Data(text.utf8)) else { return }
        guard let type = value.objectValue?["type"] else {
            rules = value
            return
        }
        var deleted: Set<Bool> = []
        let simplified = Self.simplified(type, deleted: &deleted, isNested: true)
        if deleted.count > 1 {
            var outer: Set<Bool> = []
            rules = Self.simplified(type, deleted: &outer, isNested: false)
        } else {
            rules = simplified
            includesRecentlyDeleted = deleted.first
        }
    }

    /// Simplifies a conjunction, and collects the values of the `deleted` clauses that it removes.
    /// - Parameter isNested: Whether to simplify the `and` clauses inside the conjunction too.
    private static func simplified(_ value: Value, deleted: inout Set<Bool>, isNested: Bool) -> Value {
        guard let object = value.objectValue, object.count == 1, let clauses = object["and"]?.arrayValue else {
            return value
        }
        var rest: [Value] = []
        for clause in clauses {
            if let object = clause.objectValue, object.count == 1, let flag = object["deleted"]?.boolValue {
                deleted.insert(flag)
            } else {
                rest.append(isNested ? simplified(clause, deleted: &deleted, isNested: true) : clause)
            }
        }
        return rest.count == 1 ? rest[0] : .object(["and": .array(rest)])
    }
}
