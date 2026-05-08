import SwiftUI

/// Wraps a track row and adds a long-press context menu with recommendation actions.
struct TrackSwipeActionsView<Content: View>: View {
    let onMore: () -> Void
    let onLess: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .contextMenu {
                Button(action: onMore) {
                    Label("More Like This", systemImage: "sparkles")
                }
                Button(action: onLess) {
                    Label("Less Like This", systemImage: "hand.thumbsdown")
                }
            }
    }
}
