import SwiftUI
import AppKit

/// Rich tooltip card displayed when hovering over a stock ticker on the notch.
/// Renders live Schwab real-time quotes, OpsOdds scores (1-10), trade decision,
/// entry/invalidation/target levels, and instructions in a spacious, highly legible window.
struct OpsOddsCard: View {
    let snapshot: ProviderSnapshot
    let now: Date

    private var score: OpsOddsScore? {
        snapshot.opsOddsScore
    }

    private var ticker: String {
        score?.ticker ?? snapshot.displayName
    }

    private var scoreVal: Int {
        score?.opsOdds ?? 5
    }

    private var scoreColor: Color {
        if scoreVal >= 7 {
            return Color(hex: 0x10B981) // Green / Favorable
        } else if scoreVal >= 4 {
            return Color(hex: 0xF59E0B) // Amber / Caution
        } else {
            return Color(hex: 0xEF4444) // Red / Unfavorable
        }
    }

    private var priceChangeColor: Color {
        guard let change = score?.priceChange else { return Palette.textSecondary }
        return change >= 0 ? Color(hex: 0x10B981) : Color(hex: 0xEF4444)
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Ticker, Source Badge, Company Name, Price, Change
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 7) {
                        Text(ticker)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.textPrimary)

                        Text(score?.quoteSource ?? "Schwab Real-Time")
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                            .foregroundStyle(Palette.textSecondary)
                    }

                    if let company = score?.companyName {
                        Text(company)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Price and Change
                VStack(alignment: .trailing, spacing: 3) {
                    Text(score?.formattedPrice ?? snapshot.headlineText)
                        .font(.system(size: 23, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary)

                    if let changeText = score?.formattedChange, !changeText.isEmpty {
                        Text(changeText)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(priceChangeColor)
                    }
                }
            }

            Rectangle()
                .fill(Palette.ringTrack)
                .frame(height: NotchLayout.hairline)

            // OpsOdds Score & Trade Decision Banner
            HStack(alignment: .center, spacing: 12) {
                // Large Score Badge
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(scoreVal)")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(scoreColor)
                    Text("/ 10")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(scoreColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(score?.bandBadge ?? "SCORE")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(scoreColor)

                        Circle()
                            .fill(scoreColor)
                            .frame(width: 5, height: 5)

                        Text(score?.isFresh == true ? "Live Signals" : "Cached Analysis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                    }

                    Text(score?.decision ?? "Analyzing setup...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            // Actionable Trade Levels in a 2x2 Grid
            if let levels = score?.levels {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRADE LEVELS")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(Palette.textSecondary)

                    LazyVGrid(columns: gridColumns, spacing: 7) {
                        if let entry = levels.entryZoneText {
                            LevelPill(title: "Entry Zone", value: entry, color: Color(hex: 0x3B82F6))
                        }
                        if let inv = levels.invalidationText {
                            LevelPill(title: "Invalidation", value: inv, color: Color(hex: 0xEF4444))
                        }
                        if let t1 = levels.target1Text {
                            LevelPill(title: "Target 1", value: t1, color: Color(hex: 0x10B981))
                        }
                        if let t2 = levels.target2Text {
                            LevelPill(title: "Target 2", value: t2, color: Color(hex: 0x059669))
                        }
                    }
                }
            }

            // Instruction Banner
            if let instruction = score?.instruction, !instruction.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(scoreColor)
                        .padding(.top, 1)

                    Text(instruction)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            }

            // Technical / Market Signals
            if let signals = score?.signals, !signals.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TECHNICAL SIGNALS")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(Palette.textSecondary)

                    ForEach(signals.prefix(2)) { sig in
                        HStack(spacing: 7) {
                            Image(systemName: sig.isSupportive ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(sig.isSupportive ? Color(hex: 0x10B981) : Color(hex: 0xF59E0B))

                            Text("\(sig.label):")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.textSecondary)

                            Text(sig.text)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Footer: Direct Fidelity Buy/Sell and OpsOdds Chart
            HStack(alignment: .center, spacing: 8) {
                // Fidelity Trade Button (Direct link to buy / sell ticker)
                Button {
                    let fidelityURL = "https://digital.fidelity.com/prgw/digital/research/quote/dashboard/summary?symbol=\(ticker)"
                    if let url = URL(string: fidelityURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Trade on Fidelity")
                            .font(.system(size: 11.5, weight: .bold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Color(hex: 0x10B981).opacity(0.18))
                    .foregroundStyle(Color(hex: 0x10B981))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color(hex: 0x10B981).opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                // OpsOdds Chart Link
                Button {
                    if let url = URL(string: "https://www.opsodds.com/chart/\(ticker)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("OpsOdds Chart")
                            .font(.system(size: 11.5, weight: .bold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: 0x3B82F6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LevelPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(color)

            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}
