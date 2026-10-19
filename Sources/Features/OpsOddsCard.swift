import SwiftUI
import AppKit

/// Rich tooltip card displayed when hovering over a stock ticker on the notch.
/// Renders live Schwab real-time quotes, OpsOdds scores (1-10), trade decision,
/// entry/invalidation/target levels, and instructions.
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

    var body: some View {
        VStack(alignment: .leading, spacing: Design.px(10)) {
            // Header: Ticker, Name, Price, Change
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Design.px(2)) {
                    HStack(alignment: .center, spacing: Design.px(6)) {
                        Text(ticker)
                            .font(.system(size: Design.px(17), weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.textPrimary)

                        Text(score?.quoteSource ?? "Schwab Real-Time")
                            .font(.system(size: Design.px(9), weight: .bold))
                            .padding(.horizontal, Design.px(5))
                            .padding(.vertical, Design.px(2))
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                            .foregroundStyle(Palette.textSecondary)
                    }

                    if let company = score?.companyName {
                        Text(company)
                            .font(.system(size: Design.px(11), weight: .regular))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Price and Change
                VStack(alignment: .trailing, spacing: Design.px(2)) {
                    Text(score?.formattedPrice ?? snapshot.headlineText)
                        .font(.system(size: Design.px(18), weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary)

                    if let changeText = score?.formattedChange, !changeText.isEmpty {
                        Text(changeText)
                            .font(.system(size: Design.px(11), weight: .semibold, design: .monospaced))
                            .foregroundStyle(priceChangeColor)
                    }
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.12))

            // OpsOdds Score & Trade Decision Banner
            HStack(spacing: Design.px(12)) {
                // Circular / Pill Score Meter
                HStack(alignment: .firstTextBaseline, spacing: Design.px(2)) {
                    Text("\(scoreVal)")
                        .font(.system(size: Design.px(26), weight: .black, design: .rounded))
                        .foregroundStyle(scoreColor)
                    Text("/ 10")
                        .font(.system(size: Design.px(12), weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, Design.px(10))
                .padding(.vertical, Design.px(4))
                .background(scoreColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: Design.px(8)))

                VStack(alignment: .leading, spacing: Design.px(2)) {
                    HStack(spacing: Design.px(6)) {
                        Text(score?.bandBadge ?? "SCORE")
                            .font(.system(size: Design.px(10), weight: .heavy))
                            .foregroundStyle(scoreColor)

                        Circle()
                            .fill(scoreColor)
                            .frame(width: Design.px(4), height: Design.px(4))

                        Text(score?.isFresh == true ? "Live Signals" : "Cached Analysis")
                            .font(.system(size: Design.px(10), weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                    }

                    Text(score?.decision ?? "Analyzing setup...")
                        .font(.system(size: Design.px(14), weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }

                Spacer()
            }

            // Actionable Trade Levels
            if let levels = score?.levels {
                VStack(alignment: .leading, spacing: Design.px(5)) {
                    Text("TRADE LEVELS")
                        .font(.system(size: Design.px(9), weight: .bold))
                        .foregroundStyle(Palette.textSecondary)

                    HStack(spacing: Design.px(6)) {
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
                HStack(alignment: .top, spacing: Design.px(8)) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: Design.px(12)))
                        .foregroundStyle(scoreColor)
                        .padding(.top, Design.px(1))

                    Text(instruction)
                        .font(.system(size: Design.px(11), weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Design.px(8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: Design.px(6)))
            }

            // Technical / Market Signals
            if let signals = score?.signals, !signals.isEmpty {
                VStack(alignment: .leading, spacing: Design.px(4)) {
                    ForEach(signals.prefix(2)) { sig in
                        HStack(spacing: Design.px(6)) {
                            Image(systemName: sig.isSupportive ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: Design.px(9), weight: .bold))
                                .foregroundStyle(sig.isSupportive ? Color(hex: 0x10B981) : Color(hex: 0xF59E0B))

                            Text("\(sig.label):")
                                .font(.system(size: Design.px(10), weight: .bold))
                                .foregroundStyle(Palette.textSecondary)

                            Text(sig.text)
                                .font(.system(size: Design.px(10), weight: .regular))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Footer: Timestamp and Open in OpsOdds
            HStack {
                Text("Schwab Real-Time API · OpsOdds Intelligence")
                    .font(.system(size: Design.px(9), weight: .regular))
                    .foregroundStyle(Palette.textSecondary.opacity(0.7))

                Spacer()

                Button {
                    if let url = URL(string: "https://www.opsodds.com/chart/\(ticker)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: Design.px(3)) {
                        Text("OpsOdds")
                            .font(.system(size: Design.px(10), weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: Design.px(8)))
                    }
                    .foregroundStyle(Color(hex: 0x3B82F6))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, Design.px(2))
        }
        .padding(Design.px(14))
    }
}

private struct LevelPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Design.px(1)) {
            Text(title.uppercased())
                .font(.system(size: Design.px(8), weight: .bold))
                .foregroundStyle(color)

            Text(value)
                .font(.system(size: Design.px(10), weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, Design.px(7))
        .padding(.vertical, Design.px(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Design.px(6)))
        .overlay(
            RoundedRectangle(cornerRadius: Design.px(6))
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
    }
}
