import Foundation

/// UsageProvider implementation for a stock ticker displaying real-time price and OpsOdds scores.
final class StockTickerProvider: UsageProvider {
    let ticker: String
    private let getDeviceId: () -> String?
    private let getBaseURL: () -> String

    var kind: ProviderKind { .stockTicker }
    var id: String { "ticker:\(ticker.uppercased())" }
    var displayName: String { ticker.uppercased() }
    var glyph: ProviderGlyph { .third }
    var isVisibleWhenAbsent: Bool { true }
    var skipsIdleRefresh: Bool { false }
    var customIconFilename: String? { nil }

    init(
        ticker: String,
        getDeviceId: @escaping () -> String? = { Preferences.storedOpsOddsDeviceId() },
        getBaseURL: @escaping () -> String = { Preferences.storedOpsOddsBaseURL() }
    ) {
        self.ticker = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.getDeviceId = getDeviceId
        self.getBaseURL = getBaseURL
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        try await fetchSnapshot(freshness: .standard)
    }

    func fetchSnapshot(freshness: UsageFreshness) async throws -> ProviderSnapshot {
        let score = await OpsOddsClient.shared.fetchTickerScore(
            ticker: ticker,
            deviceId: getDeviceId(),
            baseURL: getBaseURL()
        )

        let scoreVal = score.opsOdds ?? 5
        let bandOverride: UsageBand
        if scoreVal >= 7 {
            bandOverride = .ample // Green / Bullish / Favorable
        } else if scoreVal >= 4 {
            bandOverride = .watch // Amber / Neutral / Caution
        } else {
            bandOverride = .critical // Red / Caution / Avoid
        }

        let fraction = min(max(Double(scoreVal) / 10.0, 0.05), 1.0)
        let primaryWindow = LimitWindow(
            id: "primary",
            group: nil,
            label: ticker,
            usedFraction: fraction,
            remaining: nil,
            used: nil,
            usedText: score.formattedPrice,
            detail: score.decision,
            money: nil,
            resetsAt: nil,
            duration: nil,
            bandOverride: bandOverride,
            prefersUsedText: true
        )

        var snapshot = ProviderSnapshot(
            id: id,
            displayName: ticker,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [primaryWindow],
            headlineID: "primary",
            weeklyID: nil,
            block: nil,
            kind: .stockTicker
        )
        snapshot.opsOddsScore = score
        return snapshot
    }

    func account() -> ProviderAccount? {
        nil
    }

    var signInRoute: SignInRoute {
        .modal(name: "OpsOdds")
    }

    func signOut() async {}

    func presentSignIn() {}

    func presentAccountSwitch() {}

    func forgetCachedCredential() {}
}
