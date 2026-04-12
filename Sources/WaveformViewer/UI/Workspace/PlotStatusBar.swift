import SwiftUI

/// Compact status bar shown at the bottom of the plot detail pane. Left side
/// reports the cursor's time at higher precision than the axis labels use;
/// right side reports the current viewport span so users can gauge zoom level.
struct PlotStatusBar: View {
    let cursorTime: Double?
    let viewport: ClosedRange<Double>?
    let fullSpan: ClosedRange<Double>?

    var body: some View {
        HStack(spacing: 18) {
            cursorSection
            Spacer(minLength: 0)
            viewportSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 22)
        .background(.thinMaterial)
    }

    @ViewBuilder private var cursorSection: some View {
        if let t = cursorTime {
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tint)
                Text("t =")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 9 significant digits on the status bar so the user sees the full
                // Float32 precision of the underlying TR0 sample times, not the
                // 3-sig-fig axis-tick rounding.
                Text(EngFormat.format(t, unit: "s", significantDigits: 9))
                    .font(.caption.monospacedDigit())
            }
        } else {
            Text("Click the plot to place a cursor · ⌘G to jump to a time")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var viewportSection: some View {
        let visibleSpan = viewport.map { $0.upperBound - $0.lowerBound }
            ?? (fullSpan.map { $0.upperBound - $0.lowerBound })
        if let span = visibleSpan {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(EngFormat.format(span, unit: "s", significantDigits: 4))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
