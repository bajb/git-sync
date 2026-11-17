import Foundation
import SwiftUI

@MainActor
final class SyncEngine: ObservableObject {
    static let staleDays = 7
    private static let maxConcurrentRepos = 12

    @Published private(set) var vendors: [Vendor] = []
    @Published private(set) var results: [String: RepoResult] = [:]
    @Published private(set) var recentUpdates: [UpdateEntry] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var lastRun: Date?

    @Published var enabledVendors: Set<String> {
        didSet {
            defaults.set(enabledVendors.sorted(), forKey: "enabledVendors")
            syncDue = true
        }
    }
    @Published var paused: Bool {
        didSet {
            defaults.set(paused, forKey: "paused")
            if paused { syncTask?.cancel() }
        }
    }
    @Published var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes") }
    }

    /// Branches that are fast-forwarded automatically. Override with
    /// `defaults write com.bajb.git-sync syncBranches -array main`.
    let syncBranches: [String]
    let codeRoot: URL

    private let defaults = UserDefaults.standard
    private var syncTask: Task<Void, Never>?
    private var syncDue = false

    init() {
        enabledVendors = Set(defaults.stringArray(forKey: "enabledVendors") ?? [])
        paused = defaults.bool(forKey: "paused")
        let interval = defaults.integer(forKey: "intervalMinutes")
        intervalMinutes = interval > 0 ? interval : 15
        syncBranches = defaults.stringArray(forKey: "syncBranches") ?? ["main", "master"]
        codeRoot = defaults.string(forKey: "codeRoot").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code")

        Task { [weak self] in
            await self?.refreshVendors()
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Derived state for the UI

    var visibleResults: [RepoResult] {
        results.values.filter { enabledVendors.contains($0.repo.vendor) }.sorted { $0.id < $1.id }
    }

    var staleResults: [RepoResult] {
        visibleResults.filter { $0.isStale(days: Self.staleDays) }
            .sorted { ($0.behindSince ?? .distantFuture) < ($1.behindSince ?? .distantFuture) }
    }

    var failedResults: [RepoResult] { visibleResults.filter(\.isFailed) }

    // MARK: - Actions

    func setVendor(_ name: String, enabled: Bool) {
        if enabled { enabledVendors.insert(name) } else { enabledVendors.remove(name) }
    }

    /// Repos listed as out of date or failed.
    var problemResults: [RepoResult] {
        visibleResults.filter { $0.isFailed || $0.isStale(days: Self.staleDays) }
    }

    func syncNow() {
        guard syncTask == nil, !enabledVendors.isEmpty else { return }
        syncDue = false
        syncTask = Task { [weak self] in
            await self?.runSync(only: nil)
            self?.syncTask = nil
        }
    }

    /// Re-syncs just the problem repos, e.g. after fixing them by hand.
    func recheckProblems() {
        let repos = problemResults.map(\.repo)
        guard syncTask == nil, !repos.isEmpty else { return }
        syncTask = Task { [weak self] in
            await self?.runSync(only: repos)
            self?.syncTask = nil
        }
    }

    func refreshVendors() async {
        let root = codeRoot
        vendors = await Task.detached { RepoScanner.scan(root: root, enabled: []).vendors }.value
    }

    // MARK: - Sync loop

    private func tick() {
        guard !paused, syncTask == nil else { return }
        let interval = TimeInterval(intervalMinutes * 60)
        if syncDue || lastRun.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
            syncNow()
        }
    }

    /// Syncs `subset`, or every repo of the enabled vendors when nil.
    private func runSync(only subset: [Repo]?) async {
        isSyncing = true
        defer { isSyncing = false }

        let branches = syncBranches
        let repos: [Repo]
        if let subset {
            repos = subset
        } else {
            let root = codeRoot, enabled = enabledVendors
            let scan = await Task.detached { RepoScanner.scan(root: root, enabled: enabled) }.value
            vendors = scan.vendors
            repos = scan.repos
        }
        progress = (0, repos.count)

        await withTaskGroup(of: RepoResult?.self) { group in
            var pending = repos.makeIterator()
            func startNext() {
                guard !Task.isCancelled, let repo = pending.next() else { return }
                group.addTask {
                    Task.isCancelled ? nil : await RepoSyncer.sync(repo, syncBranches: branches)
                }
            }
            for _ in 0..<Self.maxConcurrentRepos { startNext() }
            for await result in group {
                if let result { record(result) }
                startNext()
            }
        }

        guard !Task.isCancelled, subset == nil else { return }
        let scanned = Set(repos.map(\.id))
        results = results.filter { scanned.contains($0.key) }
        lastRun = Date()
    }

    private func record(_ result: RepoResult) {
        results[result.id] = result
        progress.done += 1
        if case .updated(let commits, let rebased) = result.outcome {
            recentUpdates.insert(
                UpdateEntry(repoID: result.id, commits: commits, rebased: rebased, date: Date()), at: 0)
            recentUpdates = Array(recentUpdates.prefix(25))
        }
    }
}
