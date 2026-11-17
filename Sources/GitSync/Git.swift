import Foundation

struct GitOutput: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }
    var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    var lines: [String] { stdout.split(whereSeparator: \.isNewline).map(String.init) }

    /// Last line git printed on stderr, which is normally the actual error.
    var errorSummary: String {
        let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)"
        return String(last.prefix(140))
    }
}

enum Git {
    static let executable: String = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/usr/bin/git"
    }()

    static func run(_ args: [String], in dir: URL, timeout: TimeInterval = 30) async -> GitOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(args, in: dir, timeout: timeout))
            }
        }
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    private static func runBlocking(_ args: [String], in dir: URL, timeout: TimeInterval) -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = dir

        // A menu bar app has no terminal: fail fast instead of waiting on a credential prompt.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["LC_ALL"] = "C"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return GitOutput(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain both pipes concurrently so a chatty stderr can't block the child.
        let errBox = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        return GitOutput(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self))
    }
}

enum RepoSyncer {
    /// Fetches `origin`, then brings the checkout up to date when it is on one of
    /// `syncBranches` with a clean working tree: a fast-forward, or a rebase of
    /// local commits when that applies without conflicts. Anything else is only measured.
    static func sync(_ repo: Repo, syncBranches: [String]) async -> RepoResult {
        let dir = repo.url
        let kinds = ProjectKind.detect(in: dir)

        func result(_ outcome: Outcome, branch: String? = nil, behind: Int = 0, since: Date? = nil) -> RepoResult {
            RepoResult(repo: repo, outcome: outcome, branch: branch, behind: behind, behindSince: since, kinds: kinds)
        }

        let remotes = await Git.run(["remote"], in: dir)
        guard remotes.ok, remotes.lines.contains("origin") else { return result(.noRemote) }

        let fetch = await Git.run(["fetch", "--quiet", "origin"], in: dir, timeout: 120)
        guard fetch.ok else { return result(.failed(message: "fetch failed: \(fetch.errorSummary)")) }

        let head = await Git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: dir)
        let branch = head.ok ? head.trimmed : nil

        let status = await Git.run(["status", "--porcelain"], in: dir)
        guard status.ok else { return result(.failed(message: "status failed: \(status.errorSummary)"), branch: branch) }
        let dirty = !status.trimmed.isEmpty

        if let branch, syncBranches.contains(branch) {
            let remoteRef = "origin/\(branch)"
            guard await refExists(remoteRef, in: dir) else {
                return result(.skipped(reason: "no \(remoteRef)"), branch: branch)
            }
            let (behind, since) = await behindInfo(of: remoteRef, in: dir)
            if behind == 0 { return result(.current, branch: branch) }
            if dirty {
                return result(.skipped(reason: "local changes on \(branch)"), branch: branch, behind: behind, since: since)
            }
            let merge = await Git.run(["merge", "--ff-only", "--quiet", remoteRef], in: dir, timeout: 120)
            if merge.ok { return result(.updated(commits: behind, rebased: false), branch: branch) }

            // Local commits on the branch: replay them on top of the remote.
            let rebase = await Git.run(["rebase", "--quiet", remoteRef], in: dir, timeout: 120)
            if rebase.ok { return result(.updated(commits: behind, rebased: true), branch: branch) }

            // A stopped rebase leaves the checkout mid-replay; abort restores the original branch tip.
            let abort = await Git.run(["rebase", "--abort"], in: dir, timeout: 60)
            let stuck = await rebaseInProgress(in: dir)
            let message = abort.ok || !stuck
                ?"local commits on \(branch) conflict with \(remoteRef)"
                : "rebase onto \(remoteRef) stopped and could not be aborted — fix by hand"
            return result(.failed(message: message), branch: branch, behind: behind, since: since)
        }

        let reason = branch.map { "on \($0)" } ?? "detached HEAD"
        guard let defaultRef = await defaultRemoteRef(in: dir, candidates: syncBranches) else {
            return result(.skipped(reason: reason), branch: branch)
        }
        let (behind, since) = await behindInfo(of: defaultRef, in: dir)
        return result(.skipped(reason: reason), branch: branch, behind: behind, since: since)
    }

    private static func rebaseInProgress(in dir: URL) async -> Bool {
        let fm = FileManager.default
        for name in ["rebase-merge", "rebase-apply"] {
            let path = await Git.run(["rev-parse", "--git-path", name], in: dir)
            if path.ok, fm.fileExists(atPath: URL(fileURLWithPath: path.trimmed, relativeTo: dir).path) {
                return true
            }
        }
        return false
    }

    private static func refExists(_ ref: String, in dir: URL) async -> Bool {
        await Git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/\(ref)"], in: dir).ok
    }

    /// `origin/HEAD` when the clone recorded it, otherwise the first sync branch that exists on origin.
    private static func defaultRemoteRef(in dir: URL, candidates: [String]) async -> String? {
        let head = await Git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: dir)
        if head.ok, !head.trimmed.isEmpty { return head.trimmed }
        for branch in candidates where await refExists("origin/\(branch)", in: dir) {
            return "origin/\(branch)"
        }
        return nil
    }

    /// Commits on `ref`'s first-parent line missing from HEAD, and the date of the oldest.
    /// First-parent dates are when work landed on the branch, so an old feature branch
    /// merged yesterday counts as one day behind.
    private static func behindInfo(of ref: String, in dir: URL) async -> (Int, Date?) {
        let log = await Git.run(["log", "--first-parent", "--format=%ct", "HEAD..\(ref)"], in: dir)
        guard log.ok else { return (0, nil) }
        let stamps = log.lines.compactMap(TimeInterval.init)
        return (stamps.count, stamps.min().map(Date.init(timeIntervalSince1970:)))
    }
}
