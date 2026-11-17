import Foundation

/// A project language, mapped to the JetBrains IDE that opens it.
enum ProjectKind: String, Sendable, CaseIterable {
    case go, php

    var appName: String {
        switch self {
        case .go: return "GoLand"
        case .php: return "PhpStorm"
        }
    }

    var marker: String {
        switch self {
        case .go: return "go.mod"
        case .php: return "composer.json"
        }
    }

    /// Kinds found at the repo root, falling back to its immediate subfolders
    /// (monorepos such as `backend/composer.json`), then to GoLand.
    static func detect(in dir: URL) -> [ProjectKind] {
        let fm = FileManager.default
        func kinds(at url: URL) -> [ProjectKind] {
            allCases.filter { fm.fileExists(atPath: url.appendingPathComponent($0.marker).path) }
        }
        let atRoot = kinds(at: dir)
        if !atRoot.isEmpty { return atRoot }

        var found = Set<ProjectKind>()
        for sub in RepoScanner.directories(in: dir) {
            found.formUnion(kinds(at: sub))
        }
        return found.isEmpty ? [.go] : allCases.filter(found.contains)
    }

    func open(_ dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", appName, dir.path]
        try? p.run()
    }
}

struct Vendor: Identifiable, Sendable, Hashable {
    let name: String
    let repoCount: Int
    var id: String { name }
}

struct Repo: Identifiable, Sendable, Hashable {
    let vendor: String
    let name: String
    let url: URL
    var id: String { "\(vendor)/\(name)" }
}

enum Outcome: Sendable {
    /// `rebased` when local commits were replayed on top of the pulled ones.
    case updated(commits: Int, rebased: Bool)
    case current
    /// Left untouched: on another branch, or has local changes.
    case skipped(reason: String)
    case failed(message: String)
    case noRemote
}

struct RepoResult: Identifiable, Sendable {
    let repo: Repo
    let outcome: Outcome
    let branch: String?
    /// First-parent commits on the remote branch that this checkout lacks.
    let behind: Int
    /// Date of the oldest of those commits: how long the checkout has been behind.
    let behindSince: Date?
    let kinds: [ProjectKind]

    var id: String { repo.id }

    /// A repo the sync left alone that has been behind for longer than `days`.
    func isStale(days: Int, now: Date = Date()) -> Bool {
        switch outcome {
        case .skipped, .failed:
            guard let behindSince else { return false }
            return now.timeIntervalSince(behindSince) > Double(days) * 86_400
        default:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = outcome { return true }
        return false
    }

    var note: String {
        switch outcome {
        case .updated(let n, let rebased):
            return "pulled \(n) commit\(n == 1 ? "" : "s")" + (rebased ? ", rebased local commits" : "")
        case .current: return "up to date"
        case .skipped(let reason): return reason
        case .failed(let message): return message
        case .noRemote: return "no origin remote"
        }
    }
}

struct UpdateEntry: Identifiable, Sendable {
    let id = UUID()
    let repoID: String
    let commits: Int
    let rebased: Bool
    let date: Date
}

enum RepoScanner {
    /// Subdirectories of `url`, following symlinks, ignoring hidden entries.
    static func directories(in url: URL) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Every `<root>/<vendor>` holding at least one git repo, plus the repos of the enabled vendors.
    static func scan(root: URL, enabled: Set<String>) -> (vendors: [Vendor], repos: [Repo]) {
        let fm = FileManager.default
        var vendors: [Vendor] = []
        var repos: [Repo] = []
        for vendorDir in directories(in: root) {
            let name = vendorDir.lastPathComponent
            let repoDirs = directories(in: vendorDir).filter {
                fm.fileExists(atPath: $0.appendingPathComponent(".git").path)
            }
            guard !repoDirs.isEmpty else { continue }
            vendors.append(Vendor(name: name, repoCount: repoDirs.count))
            if enabled.contains(name) {
                repos += repoDirs.map { Repo(vendor: name, name: $0.lastPathComponent, url: $0) }
            }
        }
        return (vendors, repos)
    }
}
