import SwiftUI
import AppKit

/// Settings pane for configuring stock tickers, Schwab real-time quotes, and OpsOdds pairing.
struct TickersSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var newTickerText: String = ""
    @State private var isPairingLoading: Bool = false
    @State private var pairingState: OpsOddsPairingState?
    @State private var pairingError: String?
    @State private var pairingSuccessMessage: String?

    var body: some View {
        Form {
            // MARK: - Markets On Mode Section
            Section("Markets On") {
                Toggle("Enable Markets On mode", isOn: $preferences.marketsOnEnabled)

                Text("Automatically activates when US stock markets are open (Mon–Fri, 9:30 AM – 4:00 PM ET). Hides AI usage circles to display more stock tickers on the notch, and speeds up quote refreshes to every 5 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Current Status") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(preferences.isMarketsOnActive ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 8, height: 8)
                        Text(preferences.isMarketsOnActive ? "Active (5s Refreshes · Tickers Only)" : "Standby")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(preferences.isMarketsOnActive ? Color.green : Color.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(preferences.isMarketsOnActive ? Color.green.opacity(0.12) : Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }

                LabeledContent("US Market Hours") {
                    Text(USMarketHours.statusDescription())
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(USMarketHours.isMarketOpen() ? Color.green : Color.primary)
                }

                Toggle("Force Active for Testing (Bypass US Market Hours)", isOn: $preferences.marketsOnForceActive)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Active Stock Tickers Section
            Section("Active Stock Tickers") {
                Text("Configure which equities and ETFs show live prices and OpsOdds scores on your notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.configuredTickers.isEmpty {
                    Text("No tickers configured. Add one below to get started.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.configuredTickers, id: \.self) { ticker in
                        HStack {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)

                            Text(ticker)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.bold)

                            Spacer()

                            Button {
                                removeTicker(ticker)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(SettingsIconButtonStyle())
                            .help("Remove \(ticker)")
                        }
                    }
                }

                // Add Custom Ticker
                HStack {
                    TextField("Enter symbol (e.g. SPY, NVDA, AAPL)", text: $newTickerText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addTicker(newTickerText)
                        }

                    Button("Add Ticker") {
                        addTicker(newTickerText)
                    }
                    .disabled(newTickerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Quick Add Chips
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Add:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
                        ForEach(preferences.quickAddTickers, id: \.self) { sym in
                            let isAdded = preferences.configuredTickers.contains(sym)
                            Button {
                                if isAdded {
                                    removeTicker(sym)
                                } else {
                                    addTicker(sym)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(sym)
                                        .font(.system(.caption, design: .monospaced))
                                        .fontWeight(.semibold)
                                    Image(systemName: isAdded ? "checkmark" : "plus")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isAdded ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.06))
                                .foregroundStyle(isAdded ? Color.accentColor : Color.primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - OpsOdds Integration Section
            Section("OpsOdds Integration") {
                Text("Connect your browser pairing to stream proprietary OpsOdds scores (1–10) and trade levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Status") {
                    if !preferences.opsOddsDeviceId.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text("Connected")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("Unpaired")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("OpsOdds Server") {
                    TextField("https://www.opsodds.com", text: $preferences.opsOddsBaseURL)
                        .textFieldStyle(.roundedBorder)
                }

                if !preferences.opsOddsDeviceId.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device ID: \(preferences.opsOddsDeviceId.prefix(16))...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Schwab real-time quotes and OpsOdds signals active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Disconnect Device") {
                        preferences.opsOddsDeviceId = ""
                        pairingState = nil
                        pairingSuccessMessage = nil
                    }
                } else {
                    if let pairing = pairingState, let code = pairing.pairingCode {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PAIRING CODE")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text(code)
                                    .font(.system(size: 24, weight: .black, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                Spacer()

                                if let approvalUrl = pairing.approvalUrl, let url = URL(string: approvalUrl) {
                                    Button("Open Approval in Browser") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }

                            Text("Sign into OpsOdds in your browser and approve this pairing code.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button("Check Approval Status") {
                                    checkApproval()
                                }
                                .disabled(isPairingLoading)

                                if isPairingLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Button("Cancel") {
                                    pairingState = nil
                                }
                            }
                        }
                    } else {
                        HStack {
                            Button("Pair with OpsOdds") {
                                startPairing()
                            }
                            .disabled(isPairingLoading)

                            if isPairingLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                if let err = pairingError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }

                if let success = pairingSuccessMessage {
                    Text(success)
                        .font(.caption)
                        .foregroundStyle(Color.green)
                }
            }

            // MARK: - Market Data Feed Section
            Section("Market Data Feed & Schwab Integration") {
                Picker("Quote Refresh Interval", selection: $preferences.opsOddsRefreshInterval) {
                    Text("5 seconds (Fast)").tag(5.0)
                    Text("15 seconds (Standard)").tag(15.0)
                    Text("30 seconds (Balanced)").tag(30.0)
                    Text("60 seconds (Conserve)").tag(60.0)
                }

                Text("Schwab Real-Time REST data streams quotes directly into the notch. Hovering any ticker displays the OpsOdds trade intelligence card with direct link to Fidelity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func addTicker(_ text: String) {
        let sym = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !sym.isEmpty else { return }
        if !preferences.quickAddTickers.contains(sym) {
            preferences.quickAddTickers.append(sym)
        }
        if !preferences.configuredTickers.contains(sym) {
            preferences.configuredTickers.append(sym)
            preferences.setConnected(true, for: "ticker:\(sym)")
        }
        newTickerText = ""
    }

    private func removeTicker(_ ticker: String) {
        preferences.configuredTickers.removeAll { $0 == ticker }
    }

    private func startPairing() {
        isPairingLoading = true
        pairingError = nil
        Task {
            do {
                let state = try await OpsOddsClient.shared.startPairing(baseURL: preferences.opsOddsBaseURL)
                await MainActor.run {
                    self.pairingState = state
                    self.isPairingLoading = false
                }
            } catch {
                await MainActor.run {
                    self.pairingError = error.localizedDescription
                    self.isPairingLoading = false
                }
            }
        }
    }

    private func checkApproval() {
        guard let current = pairingState else { return }
        isPairingLoading = true
        pairingError = nil
        Task {
            do {
                let activated = try await OpsOddsClient.shared.checkAndActivatePairing(
                    pairing: current,
                    baseURL: preferences.opsOddsBaseURL
                )
                await MainActor.run {
                    self.isPairingLoading = false
                    if let devId = activated.deviceId {
                        self.preferences.opsOddsDeviceId = devId
                        self.pairingState = nil
                        self.pairingSuccessMessage = "Successfully paired with OpsOdds!"
                    } else {
                        self.pairingError = "Pairing code not approved yet. Please approve in your browser first."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isPairingLoading = false
                    self.pairingError = error.localizedDescription
                }
            }
        }
    }
}
