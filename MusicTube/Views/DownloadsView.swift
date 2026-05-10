import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadService = DownloadService.shared
    @State private var selectedFolderID: String?
    @State private var isShowingCreateFolderPrompt = false
    @State private var isShowingRenameFolderPrompt = false
    @State private var folderPendingDeletion: DownloadFolder?
    @State private var folderBeingRenamed: DownloadFolder?
    @State private var newFolderName = ""
    @State private var renamedFolderName = ""
    // Cached sorted list — recomputed only when downloads/folder selection change,
    // not on every progress tick from activeDownloads.
    @State private var cachedFilteredDownloads: [DownloadRecord] = []

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if downloadService.folders.isEmpty == false || downloadService.downloads.isEmpty == false {
                        foldersSection
                    }

                    if downloadService.activeDownloads.isEmpty == false {
                        activeSection
                    }

                    if cachedFilteredDownloads.isEmpty, downloadService.activeDownloads.isEmpty {
                        emptyState
                    } else if cachedFilteredDownloads.isEmpty {
                        emptyFolderState
                    } else {
                        downloadedSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.large)
            .background(AppTheme.screenBackground.ignoresSafeArea())
            .task {
                downloadService.refreshDownloadsFromDisk()
                recomputeFilteredDownloads()
            }
            .onReceive(downloadService.$folders) { _ in
                sanitizeSelections()
                recomputeFilteredDownloads()
            }
            .onReceive(downloadService.$downloads) { _ in
                sanitizeSelections()
                recomputeFilteredDownloads()
            }
            .onChange(of: selectedFolderID) { _, _ in
                recomputeFilteredDownloads()
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if downloadService.downloads.isEmpty == false {
                        Text(String(format: "%.1f MB", downloadService.totalDownloadedMB))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(AppTheme.controlFill))
                    }

                    Button {
                        isShowingCreateFolderPrompt = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(AppTheme.primaryText)
                    }
                }
            }
            .alert("Create Folder", isPresented: $isShowingCreateFolderPrompt) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    downloadService.createFolder(named: newFolderName)
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                }
            } message: {
                Text("Organize downloaded songs into folders.")
            }
            .alert("Rename Folder", isPresented: $isShowingRenameFolderPrompt) {
                TextField("Folder name", text: $renamedFolderName)
                Button("Save") {
                    if let folderBeingRenamed {
                        downloadService.renameFolder(folderBeingRenamed, to: renamedFolderName)
                    }
                    folderBeingRenamed = nil
                    renamedFolderName = ""
                }
                Button("Cancel", role: .cancel) {
                    folderBeingRenamed = nil
                    renamedFolderName = ""
                }
            } message: {
                Text("Give this folder a new name.")
            }
            .alert(
                "Delete Folder?",
                isPresented: Binding(
                    get: { folderPendingDeletion != nil },
                    set: { isPresented in
                        if isPresented == false {
                            folderPendingDeletion = nil
                        }
                    }
                ),
                presenting: folderPendingDeletion
            ) { folder in
                Button("Delete", role: .destructive) {
                    if selectedFolderID == folder.id {
                        selectedFolderID = nil
                    }
                    downloadService.deleteFolder(folder)
                    folderPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    folderPendingDeletion = nil
                }
            } message: { folder in
                Text("Deleting \"\(folder.name)\" will remove all downloaded songs inside it from this iPhone.")
            }
        }
    }

    private func recomputeFilteredDownloads() {
        let records: [DownloadRecord]
        if let selectedFolderID {
            records = downloadService.downloads(in: selectedFolderID)
        } else {
            records = downloadService.availableDownloads
        }
        if let sourceID = selectedFolder?.sourceID {
            cachedFilteredDownloads = records.sorted { lhs, rhs in
                let lhsIndex = lhs.source?.id == sourceID ? (lhs.sourceTrackIndex ?? Int.max) : Int.max
                let rhsIndex = rhs.source?.id == sourceID ? (rhs.sourceTrackIndex ?? Int.max) : Int.max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                return lhs.downloadedAt < rhs.downloadedAt
            }
        } else {
            cachedFilteredDownloads = Array(records.reversed())
        }
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Folders")

                Spacer()

                if let selectedFolder {
                    Menu {
                        Button {
                            folderBeingRenamed = selectedFolder
                            renamedFolderName = selectedFolder.name
                            isShowingRenameFolderPrompt = true
                        } label: {
                            Label("Rename Folder", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            folderPendingDeletion = selectedFolder
                        } label: {
                            Label("Delete Folder", systemImage: "trash")
                        }
                    } label: {
                        Label("Edit", systemImage: "ellipsis.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    folderChip(
                        title: "All",
                        count: downloadService.availableDownloads.count,
                        isSelected: selectedFolderID == nil
                    ) {
                        selectedFolderID = nil
                    }

                    ForEach(downloadService.folders) { folder in
                        folderChip(
                            title: folder.name,
                            count: downloadService.downloads(in: folder.id).count,
                            isSelected: selectedFolderID == folder.id
                        ) {
                            selectedFolderID = folder.id
                        }
                    }
                }
            }
        }
    }

    private func folderChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.25) : AppTheme.controlFill)
                    )
            }
            .foregroundStyle(isSelected ? AppTheme.inverseText : AppTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? AppTheme.inverseFill : AppTheme.controlFillStrong)
            )
        }
        .buttonStyle(.plain)
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Downloading")
                Spacer()
                Button {
                    downloadService.cancelAllDownloads()
                } label: {
                    Text("Stop All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(orderedActiveDownloads) { active in
                    ActiveRow(active: active) {
                        downloadService.cancelDownload(for: active.track)
                    }
                }
            }
            .background(rowBackground)
        }
    }

    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Downloaded")
            LazyVStack(spacing: 0) {
                ForEach(Array(cachedFilteredDownloads.enumerated()), id: \.element.id) { index, record in
                    CompactDownloadRow(record: record) {
                        let playbackQueue = downloadService.playbackQueue(from: cachedFilteredDownloads)
                        guard let selectedTrack = playbackQueue.first(where: {
                            ($0.youtubeVideoID ?? $0.id) == (record.track.youtubeVideoID ?? record.track.id)
                        }) else { return }
                        appState.play(track: selectedTrack, queue: playbackQueue)
                    } onDelete: {
                        withAnimation(.spring(response: 0.3)) {
                            downloadService.deleteDownload(record)
                        }
                    }
                    if index < cachedFilteredDownloads.count - 1 {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 58)
                    }
                }
            }
            .background(rowBackground)
        }
    }

    private var selectedFolder: DownloadFolder? {
        guard let selectedFolderID else { return nil }
        return downloadService.folders.first(where: { $0.id == selectedFolderID })
    }

    private var orderedActiveDownloads: [ActiveDownload] {
        downloadService.activeDownloads.values.sorted { lhs, rhs in
            if lhs.source?.id == rhs.source?.id,
               let lhsIndex = lhs.sourceTrackIndex,
               let rhsIndex = rhs.sourceTrackIndex,
               lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.queuePosition < rhs.queuePosition
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(AppTheme.tertiaryText)

            VStack(spacing: 6) {
                Text("No Downloads Yet")
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
                Text("Download songs anywhere in the app, then organize them into folders here.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyFolderState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.tertiaryText)
            Text("This folder is empty.")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Text("Download a playlist, album, or liked songs to create folders automatically, or move downloads here from the menu on any track.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 4)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(AppTheme.cardFillStrong)
    }

    private func sanitizeSelections() {
        if let selectedFolderID,
           downloadService.folders.contains(where: { $0.id == selectedFolderID }) == false {
            self.selectedFolderID = nil
        }
    }
}

private struct ActiveRow: View {
    let active: ActiveDownload
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: active.track.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(active.track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(active.track.artist)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)

                    if let source = active.source {
                        Text("· \(source.title)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }

                DownloadProgressBar(progress: active.progress)
                    .frame(height: 3)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.controlFillStrong))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct DownloadProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.progressTrack)
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: max(geo.size.width * progress, progress > 0 ? 6 : 0))
            }
        }
    }
}

private struct CompactDownloadRow: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var downloadService = DownloadService.shared
    let record: DownloadRecord
    let onPlay: () -> Void
    let onDelete: () -> Void

    private var assignedFolder: DownloadFolder? {
        downloadService.folder(for: record)
    }

    private var accentColor: Color {
        Color(red: 1, green: 0.24, blue: 0.43)
    }

    private var isCurrentTrack: Bool {
        appState.nowPlaying?.playbackKey == record.track.playbackKey
    }

    private var isCurrentlyPlaying: Bool {
        isCurrentTrack && appState.isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                AsyncArtworkView(url: record.track.artworkURL, cornerRadius: 10)
                    .frame(width: 52, height: 52)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isCurrentTrack ? accentColor.opacity(0.45) : Color.clear,
                                lineWidth: 1.5
                            )
                    )
            }
            .buttonStyle(.plain)

            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCurrentTrack ? accentColor : AppTheme.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if isCurrentlyPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(accentColor)

                            Text("Playing")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accentColor)
                                .fixedSize(horizontal: true, vertical: false)
                        } else if isCurrentTrack {
                            Image(systemName: "speaker.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(accentColor.opacity(0.7))

                            Text("Paused")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accentColor.opacity(0.7))
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Text(record.track.artist)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)

                        if let source = record.source {
                            Text("· \(source.title)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.tertiaryText)
                                .lineLimit(1)
                        }

                        if let folder = assignedFolder,
                           folder.sourceID != record.source?.id {
                            Text("· \(folder.name)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.tertiaryText)
                                .lineLimit(1)
                        }

                        if let duration = record.track.formattedDuration {
                            Text("· \(duration)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize()
                        }

                        if let views = record.track.formattedViewCount {
                            Text("· \(views)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize()
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            TrackActionsButton(track: record.localTrack, size: 32)

            DownloadFolderMenu(record: record)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.controlFill))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrentTrack ? accentColor.opacity(0.07) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isCurrentTrack ? accentColor.opacity(0.38) : Color.clear,
                            lineWidth: 1.5
                        )
                )
        )
        .padding(.horizontal, 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isCurrentTrack)
    }
}

private struct DownloadFolderMenu: View {
    @StateObject private var downloadService = DownloadService.shared
    let record: DownloadRecord

    var body: some View {
        Menu {
            Button {
                downloadService.moveDownload(record, to: nil)
            } label: {
                Label("No Folder", systemImage: record.folderID == nil ? "checkmark" : "folder.badge.minus")
            }

            ForEach(downloadService.folders) { folder in
                Button {
                    downloadService.moveDownload(record, to: folder.id)
                } label: {
                    Label(folder.name, systemImage: record.folderID == folder.id ? "checkmark" : "folder")
                }
            }
        } label: {
            Image(systemName: "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(AppTheme.controlFill))
        }
        .buttonStyle(.plain)
    }
}
