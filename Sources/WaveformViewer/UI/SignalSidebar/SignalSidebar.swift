import SwiftUI

struct SignalSidebar: View {
    @Bindable var state: WaveformAppState

    var body: some View {
        VStack(spacing: 0) {
            filterField
            Divider()
            content
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Filter signals…", text: $state.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !state.filterText.isEmpty {
                Button {
                    state.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var content: some View {
        if state.fileNodes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No files open")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("File → Open… (⌘O)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SignalOutlineView(
                fileNodes: state.fileNodes,
                filterText: state.filterText,
                // Reading the two collections here subscribes the sidebar to
                // them through the Observation framework so changes in either
                // drive updateNSView, which refreshes cell content.
                checkedSignals: state.checkedSignals,
                gateOff: state.gateOff,
                cursorTimeX: state.cursorTimeX,
                state: state
            )
        }
    }
}
