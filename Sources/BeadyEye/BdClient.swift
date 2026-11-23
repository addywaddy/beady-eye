import Foundation

/// Written by two reader threads, read only after both finish (DispatchGroup orders it).
private final class OutputBuffer: @unchecked Sendable { var out = Data(); var err = Data() }

/// Appends one line per bd call (writes only, not the 4-second polling) to ~/Library/Logs/BeadyEye/bd.log,
/// so "I clicked and nothing happened" can be answered from facts.
enum CallLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BeadyEye")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bd.log")
    }()
    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: .now)
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
    static let readOnly: Set<String> = ["list", "ready", "show"]
}

struct BdError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin wrapper over the `bd` CLI. All state lives in bd/Dolt; we only parse `--json`.
actor BdClient {
    let workspace: URL
    private var bdPath: String?

    init(workspace: URL) { self.workspace = workspace }

    // MARK: Locating bd (GUI apps don't inherit the shell PATH)

    static func locateBd() -> String? {
        // Prefer whatever the user's login shell runs, so the app and the terminal agree
        // (there can be several installs, e.g. an old ~/.local/bin/bd next to Homebrew's).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v bd"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: out) { return out }
        }
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/bd", "/usr/local/bin/bd", "\(home)/.local/bin/bd", "\(home)/go/bin/bd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Running

    @discardableResult
    func run(_ args: [String]) async throws -> Data {
        if bdPath == nil { bdPath = Self.locateBd() }
        guard let bd = bdPath else { throw BdError(message: "Could not find the `bd` executable. Install beads or put it in ~/.local/bin.") }
        let dir = workspace
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bd)
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\((bd as NSString).deletingLastPathComponent):/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            env["NO_COLOR"] = "1"
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            // Drain both pipes concurrently to avoid blocking on large output.
            let buf = OutputBuffer()
            let group = DispatchGroup()
            group.enter(); group.enter()
            DispatchQueue.global().async { buf.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            DispatchQueue.global().async { buf.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            p.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    if !CallLog.readOnly.contains(args.first ?? "") {
                        let tail = String(decoding: buf.err.isEmpty ? buf.out : buf.err, as: UTF8.self)
                            .split(separator: "\n").filter { !$0.hasPrefix("Warning:") }.prefix(2).joined(separator: " / ")
                        CallLog.write("bd \(args.joined(separator: " ")) -> exit \(proc.terminationStatus) \(tail)")
                    }
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: buf.out)
                    } else {
                        let raw = String(decoding: buf.err.isEmpty ? buf.out : buf.err, as: UTF8.self)
                        let lines = raw.split(separator: "\n").map(String.init)
                        let real = lines.filter { !$0.hasPrefix("Warning:") }   // e.g. "permissions 0750" noise
                        let msg = (real.isEmpty ? lines : real).joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(throwing: BdError(message: msg.isEmpty ? "bd exited with status \(proc.terminationStatus)" : msg))
                    }
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ args: [String]) async throws -> T {
        let data = try await run(args + ["--json"])
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch let e as DecodingError {
            let path = { (c: [CodingKey]) in c.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined() }
            let detail: String
            switch e {
            case .keyNotFound(let k, let ctx): detail = "missing key '\(k.stringValue)' at \(path(ctx.codingPath))"
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx): detail = "\(ctx.debugDescription) at \(path(ctx.codingPath))"
            @unknown default: detail = e.localizedDescription
            }
            throw BdError(message: "Unexpected output from `bd \(args.first ?? "")`: \(detail)")
        }
    }

    // MARK: Reads

    func listAll() async throws -> [Issue] {
        try await decode([Issue].self, ["list", "--all", "-n", "0", "--flat"])
    }

    func readyIDs() async throws -> Set<String> {
        Set(try await decode([Issue].self, ["ready", "-n", "0"]).map(\.id))
    }

    /// The issue's state at each commit that touched the database, newest first (`limit` 0 = all).
    func history(_ id: String, limit: Int) async throws -> [HistoryEntry] {
        try await decode([HistoryEntry].self, ["history", id, "--limit", String(limit)])
    }

    /// Audit events (created / updated / closed …) with the actor who did them.
    func events(_ id: String) async throws -> [AuditEvent] {
        try await decode([AuditEvent].self, ["history", id, "--events"])
    }

    func show(_ id: String) async throws -> Issue {
        guard let issue = try await decode([Issue].self, ["show", id]).first else { throw BdError(message: "Issue \(id) not found") }
        return issue
    }

    /// Who `bd` thinks you are: the name by its documented order ($BEADS_ACTOR, git user.name, $USER) and
    /// the email it records as an issue's `owner` (git user.email). Resolved in a login shell inside the
    /// project so it matches what the terminal does.
    func currentIdentity() async -> (name: String, email: String?) {
        let dir = workspace
        let fallback = NSUserName()
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", #"printf '%s\n%s' "${BEADS_ACTOR:-$(git config user.name 2>/dev/null)}" "$(git config user.email 2>/dev/null)""#]
                p.currentDirectoryURL = dir
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return cont.resume(returning: (fallback, nil)) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                let name = (lines.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let email = (lines.count > 1 ? lines[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (name.isEmpty ? fallback : name, email.isEmpty ? nil : email))
            }
        }
    }

    // MARK: Writes

    func create(title: String, type: String, priority: Int, description: String,
                assignee: String = "", due: String? = nil, parent: String? = nil) async throws -> String {
        struct Created: Decodable { let id: String }
        var args = ["create", title, "-t", type, "-p", String(priority)]
        if !description.isEmpty { args += ["-d", description] }
        if !assignee.isEmpty { args += ["-a", assignee] }
        if let due { args += ["--due", due] }
        if let parent, !parent.isEmpty { args += ["--parent", parent] }
        return try await decode(Created.self, args).id
    }

    func update(_ id: String, _ flags: [String]) async throws { try await run(["update", id] + flags + ["--json"]) }
    func setStatus(_ id: String, _ status: String) async throws { try await update(id, ["-s", status]) }
    func close(_ id: String, reason: String?) async throws {
        var a = ["close", id]
        if let reason, !reason.isEmpty { a += ["-r", reason] }
        try await run(a + ["--json"])
    }
    func reopen(_ id: String) async throws { try await run(["reopen", id, "--json"]) }
    func comment(_ id: String, text: String) async throws { try await run(["comment", id, text, "--json"]) }
    func addLabel(_ id: String, _ label: String) async throws { try await run(["label", "add", id, label, "--json"]) }
    func removeLabel(_ id: String, _ label: String) async throws { try await run(["label", "remove", id, label, "--json"]) }
    func addDependency(_ id: String, dependsOn other: String) async throws { try await run(["dep", "add", id, other, "--json"]) }
}
