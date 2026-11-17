import ServiceManagement
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: SyncEngine
    @State private var showVendors = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if engine.enabledVendors.isEmpty {
                        Text("Enable a vendor below to start syncing its repos.")
                            .foregroundStyle(.secondary)
                    } else {
                        summary
                        staleSection
                        failedSection
                        updatesSection
                    }
                    vendorSection
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 560)
        .onAppear {
            showVendors = engine.enabledVendors.isEmpty
            Task { await engine.refreshVendors() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Git Sync").font(.headline)
                statusLine.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                engine.syncNow()
            } label: {
                Label("Sync now", systemImage: "arrow.clockwise")
            }
            .disabled(engine.isSyncing || engine.enabledVendors.isEmpty)

            Button {
                engine.paused.toggle()
            } label: {
                Label(engine.paused ? "Run" : "Pause", systemImage: engine.paused ? "play.fill" : "pause.fill")
                    .frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.paused ? .green : .accentColor)
        }
        .padding(12)
    }

    @ViewBuilder private var statusLine: some View {
        if engine.isSyncing {
            Text("Syncing \(engine.progress.done) of \(engine.progress.total)…")
        } else if engine.paused {
            Text("Paused")
        } else if let lastRun = engine.lastRun {
            Text("Synced \(lastRun, format: .relative(presentation: .named)) · every \(engine.intervalMinutes) min")
        } else {
            Text("Waiting for first sync")
        }
    }

    // MARK: - Sections

    private var summary: some View {
        let all = engine.visibleResults
        func count(_ match: (Outcome) -> Bool) -> Int { all.filter { match($0.outcome) }.count }
        let updated = count { if case .updated = $0 { return true } else { return false } }
        let current = count { if case .current = $0 { return true } else { return false } }
        let skipped = count { if case .skipped = $0 { return true } else { return false } }
        let failed = count { if case .failed = $0 { return true } else { return false } }
        return Text("\(all.count) repos · \(updated) updated · \(current) current · \(skipped) left alone · \(failed) failed")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var staleSection: some View {
        let stale = engine.staleResults
        section("Out of date over \(SyncEngine.staleDays) days", count: stale.count) {
            if stale.isEmpty {
                Text("Nothing has drifted.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(stale) { RepoRow(result: $0) }
        }
    }

    @ViewBuilder private var failedSection: some View {
        let failed = engine.failedResults.filter { !$0.isStale(days: SyncEngine.staleDays) }
        if !failed.isEmpty {
            section("Failed", count: failed.count) {
                ForEach(failed) { RepoRow(result: $0) }
            }
        }
    }

    @ViewBuilder private var updatesSection: some View {
        if !engine.recentUpdates.isEmpty {
            section("Recently updated", count: nil) {
                ForEach(engine.recentUpdates) { entry in
                    HStack {
                        Text(entry.repoID).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(entry.commits) commit\(entry.commits == 1 ? "" : "s")\(entry.rebased ? " · rebased" : "") ·\(entry.date, format: .dateTime.hour().minute())")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var vendorSection: some View {
        DisclosureGroup(isExpanded: $showVendors) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(engine.vendors) { vendor in
                    Toggle(isOn: Binding(
                        get: { engine.enabledVendors.contains(vendor.name) },
                        set: { engine.setVendor(vendor.name, enabled: $0) })
                    ) {
                        HStack {
                            Text(vendor.name)
                            Spacer()
                            Text("\(vendor.repoCount)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Vendors (\(engine.enabledVendors.count) of \(engine.vendors.count) enabled)")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func section<Content: View>(
        _ title: String, count: Int?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.25), in: Capsule())
                    Spacer()
                    Button {
                        engine.recheckProblems()
                    } label: {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(engine.isSyncing)
                    .help("Re-sync only the out-of-date and failed repos")
                }
            }
            content()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Picker("Every", selection: $engine.intervalMinutes) {
                ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
            }
            .fixedSize()

            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { enable in
                    try? enable ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                .toggleStyle(.checkbox)

            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct RepoRow: View {
    let result: RepoResult

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.id).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            ForEach(result.kinds, id: \.self) { kind in
                Button(kind.appName) { kind.open(result.repo.url) }
            }
        }
        .controlSize(.small)
    }

    private var detail: String {
        var parts = [result.note]
        if result.behind > 0 { parts.append("\(result.behind) behind") }
        if let since = result.behindSince {
            parts.append("\(Int(Date().timeIntervalSince(since) / 86_400))d out of date")
        }
        return parts.joined(separator: " · ")
    }
}
