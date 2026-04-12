import SwiftUI

struct SignalSidebar: View {
    @Bindable var state: ViewerState

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
        if let document = state.document {
            SignalOutlineView(
                document: document,
                filterText: state.filterText,
                // Reading `state.visibleSignalIDs` here subscribes this view to the
                // property through the Observation framework. Without that access,
                // menu commands (Show All / Hide All) that mutate visibleSignalIDs
                // would never cause the sidebar to re-render and refresh checkboxes.
                visibleSignalIDs: state.visibleSignalIDs,
                state: state
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No file open")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
