import SwiftUI

struct HistoryDetailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isShowingClearConfirmation = false

    var body: some View {
        content
        .premiumScreenBackground()
        .navigationTitle("Recently Played")
        .toolbar {
            if !appState.historyTracks.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
        }
        .alert(
            "Clear recently played?",
            isPresented: $isShowingClearConfirmation
        ) {
            Button("Clear History", role: .destructive) {
                appState.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your listening history from this device.")
        }
    }
    
    @ViewBuilder
    private var content: some View {
        if appState.historyTracks.isEmpty {
            emptyState
        } else {
            historyList
        }
    }
    
    private var emptyState: some View {
        ScrollView(showsIndicators: false) {
            Text("No history yet.")
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .appSurface()
                .padding(.horizontal, 20)
                .padding(.top, 12)
        }
    }
    
    private var historyList: some View {
        List {
            ForEach(appState.historyTracks, id: \.id) { track in
                TrackRowView(
                    track: track,
                    showsDownloadButton: true
                ) {
                    appState.play(track: track, queue: appState.historyTracks)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        appState.removeHistoryTrack(track)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.visible)
                .listRowSeparatorTint(AppTheme.divider)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            
            Color.clear
                .frame(height: appState.nowPlaying == nil ? 108 : 174)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.top, 4)
        .task(id: appState.historyTracks.prefix(10).map(\.playbackKey)) {
            appState.prefetchPlayback(for: Array(appState.historyTracks.prefix(10)))
        }
    }
}
