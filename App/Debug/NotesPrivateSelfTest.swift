#if DEBUG
    import Foundation

    /// DEBUG-only live check of the private Notes tools against real NotesShared.
    /// Run with the launch argument `--notes-private-selftest`. It makes a throwaway folder named
    /// "iMCP test <timestamp>" with a few notes in it, exercises every private tool on them through
    /// the same code the tools use, prints each step as JSON, marks everything it made deleted
    /// through Notes' own call, and exits. It never touches a folder or note it did not create.
    ///
    /// The app must run under the real bundle ID so the saved Notes folder grant resolves.
    enum NotesPrivateSelfTest {
        /// Called from `App.init()`. Runs the check on a background task while the main run loop is
        /// pumped (Core Data work can hop to the main queue), prints the report, and exits.
        static func runAndExitIfRequested() {
            guard CommandLine.arguments.contains("--notes-private-selftest") else { return }
            Task.detached {
                let report = await run()
                print("NPSELFTEST-BEGIN\n\(report)\nNPSELFTEST-END")
                fflush(stdout)
                exit(0)
            }
            while true { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        }

        static func run() async -> String {
            let suite = UserDefaults(suiteName: "NotesPrivateSelfTest")!
            suite.set(true, forKey: NotesPrivate.settingKey)
            suite.set(true, forKey: NotesWriteTools.settingKey)
            let off = UserDefaults(suiteName: "NotesPrivateSelfTestOff")!
            off.removePersistentDomain(forName: "NotesPrivateSelfTestOff")
            let readOnly = UserDefaults(suiteName: "NotesPrivateSelfTestReadOnly")!
            readOnly.set(true, forKey: NotesPrivate.settingKey)
            readOnly.set(false, forKey: NotesWriteTools.settingKey)

            let stamp: String = {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd-HHmmss"
                return f.string(from: Date())
            }()
            let folderName = "iMCP test \(stamp)"
            var steps: [[String: Any]] = []

            func record(_ name: String, _ result: Result<[String: Any], Error>, expectFailure: Bool = false) {
                switch result {
                case .success(let r):
                    var entry: [String: Any] = ["step": name, "ok": !expectFailure]
                    if let v = r["verified"] as? Bool { entry["verified"] = v }
                    entry["detail"] = r
                    steps.append(entry)
                case .failure(let e):
                    steps.append(["step": name, "ok": expectFailure, "detail": "\(e)"])
                }
            }

            @discardableResult
            func call(
                _ name: String,
                tool: String,
                _ args: [String: Any],
                defaults: UserDefaults? = nil,
                expectFailure: Bool = false
            ) async -> [String: Any]? {
                do {
                    let r = try await NotesPrivate.run(tool: tool, arguments: args, defaults: defaults ?? suite)
                    record(name, .success(r), expectFailure: expectFailure)
                    return r
                } catch {
                    record(name, .failure(error), expectFailure: expectFailure)
                    return nil
                }
            }

            @discardableResult
            func raw(_ name: String, _ action: String, _ args: [String: Any]) async -> [String: Any]? {
                do {
                    let r = try await NotesPrivate.perform(.init(action: action, args: args))
                    record(name, .success(r))
                    return r
                } catch {
                    record(name, .failure(error))
                    return nil
                }
            }

            func check(_ name: String, _ ok: Bool, _ detail: Any = "") {
                steps.append(["step": name, "ok": ok, "detail": detail])
            }

            guard let status = await raw("status", "status", [:]) else { return output(steps, folderName) }
            check("no missing selectors", (status["missingSelectors"] as? [String])?.isEmpty ?? false, status["missingSelectors"] ?? "?")
            guard await raw("create throwaway folder", "debug.create_folder", ["title": folderName]) != nil else {
                return output(steps, folderName)
            }
            let a = await raw("create note A", "debug.create_note", ["folder": folderName, "text": "A \(stamp)\nfirst body line"])
            let b = await raw("create note B", "debug.create_note", ["folder": folderName, "text": "B \(stamp)\nlink target"])
            if let aID = a?["id"] as? String, let bID = b?["id"] as? String {
                // The Notes-app id from scripting must be the id the bridge reads.
                if let ids = await scriptingIDs(folder: folderName) {
                    check("scripting ids match the bridge ids", ids.contains(aID) && ids.contains(bID), ["bridge": [aID, bID], "scripting": ids])
                } else {
                    check("scripting ids match the bridge ids", false, "AppleScript listing failed or timed out")
                }
                await call("id by UUID works", tool: "notes_structure", ["id": a?["identifier"] as? String ?? ""])
                await call("structure (fresh note)", tool: "notes_structure", ["id": aID, "blocks": true])

                // Gates.
                await call("refused while private features are off", tool: "notes_structure", ["id": aID], defaults: off, expectFailure: true)
                await call("write refused while changes are off", tool: "notes_pin", ["id": aID, "pinned": true], defaults: readOnly, expectFailure: true)
                await call("read allowed while changes are off", tool: "notes_structure", ["id": aID], defaults: readOnly)
                await call("bad id refused", tool: "notes_pin", ["id": "not-an-id", "pinned": true], expectFailure: true)
                await call("missing note refused", tool: "notes_pin", ["id": "x-coredata://00000000-0000-0000-0000-000000000000/ICNote/p999999", "pinned": true], expectFailure: true)

                // Pin.
                await call("pin on", tool: "notes_pin", ["id": aID, "pinned": true])
                await call("pin stale expectation refused", tool: "notes_pin", ["id": aID, "pinned": false, "expected_pinned": false], expectFailure: true)
                await call("pin off", tool: "notes_pin", ["id": aID, "pinned": false, "expected_pinned": true])

                // Tags.
                await call("tags add", tool: "notes_tags", ["action": "add", "id": aID, "tags": ["iMCPtestOne", "#iMCPtestTwo"]])
                await call("tags add again (no change)", tool: "notes_tags", ["action": "add", "id": aID, "tags": ["imcptestone"]])
                await call("tags list note", tool: "notes_tags", ["action": "list", "id": aID])
                await call("tags list folder", tool: "notes_tags", ["action": "list", "folder": folderName])
                await call("tags inventory", tool: "notes_tags", ["action": "list"])
                await call("tags add on B", tool: "notes_tags", ["action": "add", "id": bID, "tags": ["iMCPtestOne"]])
                await call("tags replace", tool: "notes_tags", ["action": "replace", "ids": [aID, bID], "old": "iMCPtestOne", "new": "iMCPtestThree"])
                await call("tags remove", tool: "notes_tags", ["action": "remove", "id": aID, "tags": ["iMCPtestTwo", "iMCPtestThree"]])
                await call("tags list note after remove", tool: "notes_tags", ["action": "list", "id": aID])
                await call("tags remove B", tool: "notes_tags", ["action": "remove", "id": bID, "tags": ["iMCPtestThree"]])

                // Checklist.
                await call("checklist add", tool: "notes_checklist", ["action": "add", "id": aID, "items": ["Buy milk", "Call dentist", "Pack bag"]])
                await call("checklist get", tool: "notes_checklist", ["action": "get", "id": aID])
                await call("checklist set done by index", tool: "notes_checklist", ["action": "set", "id": aID, "index": 1, "done": true])
                await call("checklist set done by text", tool: "notes_checklist", ["action": "set", "id": aID, "text": "Pack bag", "done": true])
                await call("checklist set undone", tool: "notes_checklist", ["action": "set", "id": aID, "index": 1, "done": false])
                await call("checklist add done item", tool: "notes_checklist", ["action": "add", "id": aID, "items": ["Already done"], "done": true])
                await call("checklist get after", tool: "notes_checklist", ["action": "get", "id": aID])

                // Table.
                await call("table create", tool: "notes_table", ["action": "create", "id": aID, "rows": [["Name", "Qty", "Note"], ["Apples", "3", "red"], ["Pears", "5", ""]]])
                await call("table get", tool: "notes_table", ["action": "get", "id": aID])
                await call("table create (tab refused)", tool: "notes_table", ["action": "create", "id": aID, "rows": [["a\tb"]]], expectFailure: true)

                // Links.
                await call("link get", tool: "notes_link", ["action": "get", "id": bID])
                await call("link insert", tool: "notes_link", ["action": "insert", "id": aID, "target": bID])
                await call("link insert with label", tool: "notes_link", ["action": "insert", "id": aID, "target": bID, "label": "see B"])
                await call("link insert to self refused", tool: "notes_link", ["action": "insert", "id": aID, "target": aID], expectFailure: true)
                await call("link list", tool: "notes_link", ["action": "list", "id": aID])

                // Rich append.
                await call("append plaintext", tool: "notes_append_rich", ["id": aID, "content": "Appended plain line"])
                await call("append markdown", tool: "notes_append_rich", ["id": aID, "content": "## Appended heading\n\n- [ ] md todo\n\n**bold** and *italic*", "format": "markdown"])
                if let s = await call("structure after everything", tool: "notes_structure", ["id": aID, "blocks": true]) {
                    let objects = (s["objects"] as? [[String: Any]]) ?? []
                    let kinds = Set(objects.compactMap { $0["kind"] as? String })
                    check("old objects survived the appends (table and links present)", kinds.contains("table") && kinds.contains("note_link"), Array(kinds))
                    let cl = (s["checklist"] as? [String: Any])?["total"] as? Int ?? 0
                    check("checklist items survived (4 earlier + 1 markdown)", cl == 5, cl)
                }

                // Native Markdown creation.
                await call("create markdown note", tool: "notes_create_markdown", [
                    "markdown": "# MD note \(stamp)\n\nIntro with **bold**.\n\n- [ ] first todo\n- [x] second todo\n\n## Section\n\nText",
                    "folder": folderName,
                ])
                await call("create markdown note with title", tool: "notes_create_markdown", ["markdown": "just a paragraph", "title": "Titled \(stamp)", "folder": folderName])
                await call("create markdown in missing folder refused", tool: "notes_create_markdown", ["markdown": "x", "folder": "iMCP test nonexistent \(stamp)"], expectFailure: true)
                await raw("fresh text of A", "debug.fresh_text", ["id": aID])
            }

            // Cleanup: only what was created above.
            if let cleaned = await raw("cleanup throwaway folder", "debug.cleanup", ["prefix": folderName]) {
                check("nothing left live", (cleaned["liveRemaining"] as? Int) == 0, cleaned)
            }
            return output(steps, folderName)
        }

        /// The ids Notes' own scripting gives the notes in the throwaway folder, or nil on failure or timeout.
        private static func scriptingIDs(folder: String) async -> [String]? {
            await withTaskGroup(of: [String]?.self) { group in
                group.addTask {
                    do {
                        let fields = try await AppleNotesScriptRunner().run(
                            NotesOrganizeScripts.source,
                            calling: NotesOrganizeScripts.listNotes(account: nil, folder: NotesFolderPath(components: [folder]))
                        )
                        return try NotesScriptSummary.list(from: fields).map(\.id)
                    } catch { return nil }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }

        private static func output(_ steps: [[String: Any]], _ folderName: String) -> String {
            let report: [String: Any] = [
                "bundleID": Bundle.main.bundleIdentifier ?? "?",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "folderName": folderName,
                "steps": steps,
            ]
            let data =
                (try? JSONSerialization.data(
                    withJSONObject: report,
                    options: [.prettyPrinted, .sortedKeys]
                )) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
#endif
