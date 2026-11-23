import Foundation

/// Written by two reader threads, read only after both finish (DispatchGroup orders it).
private final class OutputBuffer: @unchecked Sendable { var out = Data(); var err = Data() }

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
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/bd", "/opt/homebrew/bin/bd", "/usr/local/bin/bd", "\(home)/go/bin/bd"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v bd"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
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
            env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
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
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: buf.out)
                    } else {
                        let msg = String(decoding: buf.err.isEmpty ? buf.out : buf.err, as: UTF8.self)
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
        catch { throw BdError(message: "Unexpected bd output: \(error.localizedDescription)") }
    }

    // MARK: Reads

    func listAll() async throws -> [Issue] {
        try await decode([Issue].self, ["list", "--all", "-n", "0", "--flat"])
    }

    func readyIDs() async throws -> Set<String> {
        Set(try await decode([Issue].self, ["ready", "-n", "0"]).map(\.id))
    }

    func show(_ id: String) async throws -> Issue {
        guard let issue = try await decode([Issue].self, ["show", id]).first else { throw BdError(message: "Issue \(id) not found") }
        return issue
    }

    // MARK: Writes

    func create(title: String, type: String, priority: Int, description: String) async throws -> String {
        struct Created: Decodable { let id: String }
        var args = ["create", title, "-t", type, "-p", String(priority)]
        if !description.isEmpty { args += ["-d", description] }
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
