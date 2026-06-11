import SwiftUI

// MARK: - The locked component system
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference. Do not invent ad-hoc cards.

public enum WarbFitMetrics {
    public static let cardRadius: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let gap: CGFloat = 12          // gap between cards
    public static let sectionGap: CGFloat = 28   // gap between sections
    public static let screenPadding: CGFloat = 24
    public static let tileHeight: CGFloat = 104  // every metric tile is this tall
    public static let chartHeight: CGFloat = 220
}

// MARK: - Surface

/// The one card surface. All cards use this — same radius, border, fill.
public struct WarbFitCard<Content: View>: View {
    private let padding: CGFloat
    @ViewBuilder private let content: () -> Content
    @State private var hover = false
    public init(padding: CGFloat = WarbFitMetrics.cardPadding, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.content = content
    }
    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: WarbFitMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WarbFitMetrics.cardRadius, style: .continuous)
                .strokeBorder(hover ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(hover ? 0.25 : 0), radius: 10, y: 4)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.16), value: hover)
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    let overline: String?; let title: String; let trailing: String?
    public init(_ title: String, overline: String? = nil, trailing: String? = nil) {
        self.title = title; self.overline = overline; self.trailing = trailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let overline { Text(overline.uppercased()).strandOverline() }
                Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

// MARK: - Metric tile (UNIFORM fixed height)

public struct StatTile: View {
    let label: String, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent

    public init(label: String, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
    }

    public var body: some View {
        WarbFitCard(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased()).strandOverline()
                Spacer(minLength: 4)
                Text(value).font(StrandFont.number(26)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6)
                if let sparkline, sparkline.count > 1 {
                    Sparkline(values: sparkline).frame(height: 22).padding(.top, 4)
                }
                HStack(spacing: 6) {
                    if let caption { Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let delta { Text(delta).font(StrandFont.captionNumber).foregroundStyle(deltaColor) }
                }
                .padding(.top, 2)
            }
        }
        .frame(height: WarbFitMetrics.tileHeight)
    }
}

// MARK: - Chart card (UNIFORM: header + fixed chart body + footer)

public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = WarbFitMetrics.chartHeight
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: String, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = WarbFitMetrics.chartHeight,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.chart = chart; self.footer = footer
    }

    public var body: some View {
        WarbFitCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.uppercased()).strandOverline()
                        if let subtitle { Text(subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    Spacer()
                    if let trailing { Text(trailing).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary) }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    Divider().overlay(StrandPalette.hairline)
                    f
                }
            }
        }
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(String, String)]
    public init(_ items: [(String, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0.uppercased()).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: String, status: String, detail: String
    var statusColor: Color = StrandPalette.accent
    public init(category: String, status: String, detail: String, statusColor: Color = StrandPalette.accent) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor
    }
    public var body: some View {
        WarbFitCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(category.uppercased()).strandOverline()
                Text(status).font(StrandFont.title1).foregroundStyle(statusColor)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Range control (the ONE segmented pill control, used everywhere)

public struct SegmentedPillControl<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    @Binding var selection: T
    public init(_ items: [T], selection: Binding<T>, label: @escaping (T) -> String) {
        self.items = items; self._selection = selection; self.label = label
    }
    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let sel = item == selection
                Button { withAnimation(StrandMotion.interactive) { selection = item } } label: {
                    Text(label(item))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(sel ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                        .frame(minWidth: 32)
                        .padding(.vertical, 6).padding(.horizontal, 11)
                        .background(Capsule(style: .continuous).fill(sel ? StrandPalette.accent : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: String; var tint: Color = StrandPalette.accent
    public init(_ text: String, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 1))
    }
}
