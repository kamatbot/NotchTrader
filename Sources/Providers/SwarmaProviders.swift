import Foundation

/// How a `swarm_status` answer becomes cells. Pure, so the mapping can be
/// tested without a client, a store or a clock.
enum SwarmaCells {
    static let agentPrefix = "swarm:agent:"
    static let scopePrefix = "swarm:scope:"

    /// The cell that stands in for the whole service when nothing has ever been
    /// read from it, so "Swarmaa not running" has somewhere to show.
    static let serviceName = "swarma"

    static func agentID(_ name: String) -> String { agentPrefix + name }
    static func scopeID(_ scope: String) -> String { scopePrefix + scope }

    /// "project:demo" reads as "demo"; a scope without the prefix is left as it is.
    static func scopeLabel(_ scope: String) -> String {
        scope.hasPrefix("project:") ? String(scope.dropFirst("project:".count)) : scope
    }

    /// The agent's vendor mark, reusing the marks the app already draws for
    /// those vendors. `.third` is what an unknown vendor gets, as it is for
    /// stock tickers.
    static func glyph(forProvider provider: String?) -> ProviderGlyph {
        switch provider?.lowercased() {
        case "claude":                 return .claude
        case "codex":                  return .openai
        case "antigravity", "gemini":  return .antigravity
        case "grok":                   return .grok
        default:                       return .third
        }
    }

    /// Offline is red whatever the quota says. Below 15% left the app's own
    /// banding decides, which at its default thresholds is critical, and
    /// exhausted at zero; a quota with room, or none read, is ample — the cell
    /// is about the agent, not a verdict on a number nobody has.
    static func agentBand(headroom: Double?, live: Bool) -> UsageBand {
        guard live else { return .critical }
        guard let headroom, headroom < 15 else { return .ample }
        return UsageBand.band(for: usedFraction(headroom: headroom))
    }

    static func usedFraction(headroom: Double) -> Double {
        1 - min(max(headroom, 0), 100) / 100
    }

    // MARK: Agents

    static func agentSnapshot(name: String, in status: SwarmaStatus) -> ProviderSnapshot {
        guard let worker = status.workers.first(where: { $0.name == name }) else {
            return unavailable(id: agentID(name), name: name, glyph: .third, detail: L10n.t("offline"))
        }

        // The tightest quota among the worker's vendors is the one that stops
        // it, so that is the ring.
        let readings = status.usage.filter { worker.providers.contains($0.provider) && $0.ok && $0.headroom != nil }
        let tightest = readings.min { ($0.headroom ?? 100) < ($1.headroom ?? 100) }
        let headroom = tightest?.headroom
        let resetsAt = tightest?.windows.compactMap(\.resetsAt).min()
        let vendor = tightest?.provider ?? worker.providers.first

        var targets: [SwarmaCancelTarget] = []
        for task in worker.running {
            guard let row = status.recent.first(where: { $0.id == task.taskId }),
                  let version = row.version else { continue }
            targets.append(SwarmaCancelTarget(taskID: task.taskId, version: version,
                                              title: row.objective ?? task.taskId))
        }

        let detail: String
        if !worker.live {
            detail = L10n.t("offline")
        } else if let task = worker.running.first {
            detail = status.recent.first(where: { $0.id == task.taskId })?.objective
                ?? task.scope.map { L10n.t("running in \(scopeLabel($0))") }
                ?? L10n.t("running")
        } else {
            detail = L10n.t("idle")
        }

        let usedText: String
        if !worker.live {
            usedText = L10n.t("offline")
        } else if let headroom {
            usedText = L10n.t("\(Percent.halves(for: usedFraction(headroom: headroom)).left)% left")
        } else {
            usedText = L10n.t("no quota")
        }

        let window = LimitWindow(
            id: "primary",
            label: vendor.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? name,
            usedFraction: headroom.map { usedFraction(headroom: $0) },
            usedText: usedText,
            detail: detail,
            resetsAt: resetsAt,
            bandOverride: agentBand(headroom: headroom, live: worker.live),
            prefersUsedText: true
        )
        var snapshot = cell(id: agentID(name), name: name, glyph: glyph(forProvider: vendor), window: window)
        snapshot.swarmTasks = targets
        return snapshot
    }

    // MARK: Scopes

    /// A scope's band. A failure or a blocked task needs a person; queued work
    /// with nobody alive to take it is the quieter version of the same problem.
    static func scopeBand(_ scope: SwarmaStatus.Scope, hasLiveWorker: Bool) -> UsageBand {
        if scope.failed24h > 0 || scope.blocked > 0 { return .critical }
        if scope.queued > 0 && !hasLiveWorker { return .watch }
        return .ample
    }

    static func scopeSnapshot(scope name: String, in status: SwarmaStatus) -> ProviderSnapshot {
        let scope = status.scopes.first(where: { $0.scope == name })
            ?? SwarmaStatus.Scope(scope: name, queued: 0, running: 0, blocked: 0, completed24h: 0, failed24h: 0)
        let label = scopeLabel(name)

        var detail = L10n.t("\(scope.completed24h) done today")
        if scope.failed24h > 0 { detail += " · " + L10n.t("\(scope.failed24h) failed") }
        let counts = L10n.t("\(scope.running) running · \(scope.queued) queued")

        // The tooltip prints a count row's detail and not its text, so the
        // counts the cell reads get a row of their own beside the day's tally.
        let primary = LimitWindow(
            id: "primary",
            label: label,
            used: scope.completed24h,
            usedText: counts,
            detail: detail,
            bandOverride: scopeBand(scope, hasLiveWorker: status.workers.contains(where: \.live)),
            prefersUsedText: true
        )
        let now = LimitWindow(id: "now", label: L10n.t("Now"), used: scope.running, detail: counts)
        var snapshot = cell(id: scopeID(name), name: label, glyph: .third, window: primary)
        snapshot.windows.append(now)
        return snapshot
    }

    // MARK: Failure

    /// The cell when the service cannot be read. No ring and no number: what the
    /// last answer said is exactly what can no longer be vouched for.
    static func unavailable(id: String, name: String, glyph: ProviderGlyph, detail: String) -> ProviderSnapshot {
        let window = LimitWindow(id: "primary", label: name, usedText: L10n.t("offline"), detail: detail,
                                 bandOverride: .critical, prefersUsedText: true)
        var snapshot = cell(id: id, name: name, glyph: glyph, window: window)
        snapshot.status = .error(detail)
        return snapshot
    }

    private static func cell(id: String, name: String, glyph: ProviderGlyph, window: LimitWindow) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official, status: .ok,
                         windows: [window], headlineID: "primary", weeklyID: nil, block: nil, kind: .swarm)
    }
}

/// One cell per Swarma worker. Never throws: a service that is down is a cell
/// that says so, not a failed fetch for the store to make its own call about.
final class SwarmAgentProvider: UsageProvider {
    let name: String
    private let client: SwarmaClient

    var kind: ProviderKind { .swarm }
    var id: String { SwarmaCells.agentID(name) }
    var displayName: String { name }
    var glyph: ProviderGlyph { .third }

    init(name: String, client: SwarmaClient = .shared) {
        self.name = name
        self.client = client
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        do {
            return SwarmaCells.agentSnapshot(name: name, in: try await client.status())
        } catch {
            let failure = error as? SwarmaClient.Failure ?? .unreachable
            return SwarmaCells.unavailable(id: id, name: name, glyph: .third, detail: failure.message)
        }
    }

}

/// One cell per Swarma project scope.
final class SwarmScopeProvider: UsageProvider {
    let scope: String
    private let client: SwarmaClient

    var kind: ProviderKind { .swarm }
    var id: String { SwarmaCells.scopeID(scope) }
    var displayName: String { SwarmaCells.scopeLabel(scope) }
    var glyph: ProviderGlyph { .third }

    init(scope: String, client: SwarmaClient = .shared) {
        self.scope = scope
        self.client = client
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        do {
            return SwarmaCells.scopeSnapshot(scope: scope, in: try await client.status())
        } catch {
            let failure = error as? SwarmaClient.Failure ?? .unreachable
            return SwarmaCells.unavailable(id: id, name: displayName, glyph: .third, detail: failure.message)
        }
    }

}

/// Decides which Swarma cells exist, the way the configured list does for
/// tickers — except that the list is whatever the service reports, so it is
/// asked on a timer and the store is told when the set changes.
@MainActor
final class SwarmaDirectory {
    private let client: SwarmaClient
    private weak var store: UsageStore?
    private let interval: TimeInterval
    private var timer: Timer?
    private var registered: [String] = []
    private var syncing = false

    private(set) var isEnabled = false

    init(client: SwarmaClient = .shared, store: UsageStore, interval: TimeInterval = 15) {
        self.client = client
        self.store = store
        self.interval = interval
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        timer?.invalidate()
        timer = nil
        guard enabled else {
            registered = []
            store?.registerSwarmProviders([])
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sync()
    }

    /// Ask the service, then register or refresh. Cells already on screen are
    /// kept when the service goes quiet; they flip to offline by refreshing.
    func sync() {
        guard isEnabled, !syncing else { return }
        syncing = true
        Task { [weak self] in
            guard let self else { return }
            let result: Result<SwarmaStatus, Error>
            do { result = .success(try await client.status()) } catch { result = .failure(error) }
            finishSync(result)
        }
    }

    private func finishSync(_ result: Result<SwarmaStatus, Error>) {
        syncing = false
        guard isEnabled, let store else { return }
        let providers: [UsageProvider]?
        switch result {
        case .success(let status):
            providers = Self.providers(for: status, client: client)
        case .failure:
            // Nothing has ever answered: one cell, so the notch says it.
            // Otherwise the cells already up flip to offline on refresh.
            providers = registered.isEmpty ? [SwarmAgentProvider(name: SwarmaCells.serviceName, client: client)] : nil
        }
        if let providers, providers.map(\.id) != registered {
            registered = providers.map(\.id)
            store.registerSwarmProviders(providers)
        } else {
            store.refreshSwarm()
        }
    }

    nonisolated static func providers(for status: SwarmaStatus, client: SwarmaClient) -> [UsageProvider] {
        status.workers.map(\.name).sorted().map { SwarmAgentProvider(name: $0, client: client) }
            + status.scopes.map(\.scope).sorted().map { SwarmScopeProvider(scope: $0, client: client) }
    }

    /// Cancel a task from a cell's menu, then look again so the cell shows it.
    func cancel(_ target: SwarmaCancelTarget) async {
        do {
            try await client.cancelTask(id: target.taskID, expectedVersion: target.version)
        } catch {
            let message = (error as? SwarmaClient.Failure)?.message ?? "unknown error"
            Log.usage.error("swarma cancel failed: \(message, privacy: .public)")
        }
        sync()
    }
}
