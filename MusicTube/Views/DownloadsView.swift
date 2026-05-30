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
    @State private var dropTargetFolderID: String?
    // Cached sorted list — recomputed only when downloads/folder selection change,
    // not on every progress tick from activeDownloads.
    @State private var cachedFilteredDownloads: [DownloadRecord] = []
    // Multi-select mode (entered via the "Select" toolbar button).
    @State private var isSelecting = false
    @State private var selectedRecordIDs: Set<String> = []
    @State private var isShowingMoveSheet = false
    @State private var isConfirmingBatchDelete = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if downloadService.downloads.isEmpty == false {
                        storageSummaryCard
                    }

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
            .onReceive(downloadService.$folders) { folders in
                sanitizeSelections()
                recomputeFilteredDownloads(folders: folders)
            }
            .onReceive(downloadService.$downloads) { downloads in
                sanitizeSelections()
                recomputeFilteredDownloads(downloads: downloads)
            }
            .onChange(of: selectedFolderID) { _, _ in
                recomputeFilteredDownloads()
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelecting {
                        Button("Done") {
                            exitSelectionMode()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    } else {
                        if downloadService.downloads.isEmpty == false {
                            Button("Select") {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    isSelecting = true
                                    selectedRecordIDs.removeAll()
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        }

                        Button {
                            isShowingCreateFolderPrompt = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(AppTheme.primaryText)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    selectionActionBar
                }
            }
            .confirmationDialog(
                "Move \(selectedRecordIDs.count) song\(selectedRecordIDs.count == 1 ? "" : "s") to…",
                isPresented: $isShowingMoveSheet,
                titleVisibility: .visible
            ) {
                Button("No Folder") { moveSelected(to: nil) }
                ForEach(downloadService.folders) { folder in
                    Button(folder.name) { moveSelected(to: folder.id) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete \(selectedRecordIDs.count) song\(selectedRecordIDs.count == 1 ? "" : "s")?", isPresented: $isConfirmingBatchDelete) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The selected downloads will be removed from this iPhone.")
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

    private var storageSummaryCard: some View {
        StorageSummaryCard(
            trackCount: downloadService.downloads.count,
            folderCount: userFolderCount,
            storageMB: downloadService.totalDownloadedMB
        )
    }

    /// Number of real user-visible folders. The "Unassigned" bucket is not a folder
    /// (it's the nil-folder catch-all), so `folders.count` already excludes it.
    private var userFolderCount: Int {
        downloadService.folders.count
    }

    private func recomputeFilteredDownloads(
        downloads recordsSnapshot: [DownloadRecord]? = nil,
        folders foldersSnapshot: [DownloadFolder]? = nil
    ) {
        let allDownloads = recordsSnapshot ?? downloadService.downloads
        let allFolders = foldersSnapshot ?? downloadService.folders
        let records: [DownloadRecord]
        if let selectedFolderID {
            records = allDownloads.filter { $0.folderID == selectedFolderID }
        } else {
            records = allDownloads.filter { $0.folderID == nil }
        }
        let selectedSourceID = selectedFolderID.flatMap { folderID in
            allFolders.first(where: { $0.id == folderID })?.sourceID
        }
        if let sourceID = selectedSourceID {
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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    folderChip(
                        title: "Unassigned",
                        count: downloadService.downloads(in: nil).count,
                        artworkURL: downloadService.artworkURL(for: nil),
                        isSelected: selectedFolderID == nil
                    ) {
                        selectedFolderID = nil
                    }

                    ForEach(downloadService.folders) { folder in
                        reorderableFolderChip(folder)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reorderableFolderChip(_ folder: DownloadFolder) -> some View {
        folderChip(
            title: folder.name,
            count: downloadService.downloads(in: folder.id).count,
            artworkURL: downloadService.artworkURL(for: folder.id),
            isSelected: selectedFolderID == folder.id
        ) {
            selectedFolderID = folder.id
        }
        .contentShape(Capsule())
        .opacity(dropTargetFolderID == folder.id ? 0.92 : 1)
        .contextMenu {
            Button {
                folderBeingRenamed = folder
                renamedFolderName = folder.name
                isShowingRenameFolderPrompt = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                selectedFolderID = folder.id
            } label: {
                Label("Open Folder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                folderPendingDeletion = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .draggable(folder.id)
        .dropDestination(for: String.self) { items, _ in
            guard let draggedFolderID = items.first,
                  downloadService.folders.contains(where: { $0.id == draggedFolderID }) else {
                dropTargetFolderID = nil
                return false
            }

            dropTargetFolderID = nil
            downloadService.moveFolder(id: draggedFolderID, to: folder.id)
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTargetFolderID = folder.id
            } else if dropTargetFolderID == folder.id {
                dropTargetFolderID = nil
            }
        }
    }

    private func folderChip(
        title: String,
        count: Int,
        artworkURL: URL?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let artworkURL {
                    AsyncArtworkView(url: artworkURL, cornerRadius: 8)
                        .frame(width: 30, height: 30)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

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
                        if active.isPaused {
                            downloadService.resumeDownload(for: active.track)
                        } else {
                            downloadService.pauseDownload(for: active.track)
                        }
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
                    CompactDownloadRow(
                        record: record,
                        assignedFolder: downloadService.folder(for: record),
                        downloadFolders: downloadService.folders,
                        isSelecting: isSelecting,
                        isSelected: selectedRecordIDs.contains(record.id),
                        onMove: { folderID in downloadService.moveDownload(record, to: folderID) },
                        onPlay: {
                            if isSelecting {
                                toggleSelection(record)
                                return
                            }
                            let playbackQueue = downloadService.playbackQueue(from: cachedFilteredDownloads)
                            guard let selectedTrack = playbackQueue.first(where: {
                                ($0.youtubeVideoID ?? $0.id) == (record.track.youtubeVideoID ?? record.track.id)
                            }) else { return }
                            appState.play(track: selectedTrack, queue: playbackQueue)
                        },
                        onDelete: {
                            withAnimation(.spring(response: 0.3)) {
                                downloadService.deleteDownload(record)
                            }
                        }
                    )
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
            Text(selectedFolderID == nil ? "Songs without a folder will show up here." : "Download a playlist, album, or liked songs to create folders automatically, or move downloads here from the menu on any track.")
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
        // Drop any selected IDs that no longer exist.
        if selectedRecordIDs.isEmpty == false {
            let existing = Set(downloadService.downloads.map(\.id))
            selectedRecordIDs.formIntersection(existing)
        }
    }

    // MARK: - Multi-select

    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Button {
                isShowingMoveSheet = true
            } label: {
                Label("Move", systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(AppTheme.controlFillStrong))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(selectedRecordIDs.isEmpty)

            Button {
                isConfirmingBatchDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color(red: 1, green: 0.23, blue: 0.42)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(selectedRecordIDs.isEmpty)
        }
        .opacity(selectedRecordIDs.isEmpty ? 0.55 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func toggleSelection(_ record: DownloadRecord) {
        if selectedRecordIDs.contains(record.id) {
            selectedRecordIDs.remove(record.id)
        } else {
            selectedRecordIDs.insert(record.id)
        }
    }

    private func exitSelectionMode() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isSelecting = false
            selectedRecordIDs.removeAll()
        }
    }

    private func moveSelected(to folderID: String?) {
        let targets = downloadService.downloads.filter { selectedRecordIDs.contains($0.id) }
        for record in targets {
            downloadService.moveDownload(record, to: folderID)
        }
        exitSelectionMode()
    }

    private func deleteSelected() {
        let targets = downloadService.downloads.filter { selectedRecordIDs.contains($0.id) }
        withAnimation(.spring(response: 0.3)) {
            for record in targets {
                downloadService.deleteDownload(record)
            }
        }
        exitSelectionMode()
    }
}

// MARK: - StorageSummaryCard

private struct StorageSummaryCard: View {
    let trackCount: Int
    let folderCount: Int
    let storageMB: Double

    var body: some View {
        HStack(spacing: 0) {
            statItem(
                icon: "music.note",
                value: "\(trackCount)",
                label: trackCount == 1 ? "Song" : "Songs"
            )

            Divider()
                .frame(height: 36)
                .overlay(AppTheme.divider)

            statItem(
                icon: "folder",
                value: "\(folderCount)",
                label: folderCount == 1 ? "Folder" : "Folders"
            )

            Divider()
                .frame(height: 36)
                .overlay(AppTheme.divider)

            statItem(
                icon: "internaldrive",
                value: formattedStorage,
                label: "Used"
            )
        }
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.cardFillStrong)
        )
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(AppTheme.primaryText)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedStorage: String {
        if storageMB >= 1024 {
            return String(format: "%.1f GB", storageMB / 1024)
        }
        return String(format: "%.0f MB", storageMB)
    }
}

private struct ActiveRow: View {
    let active: ActiveDownload
    /// Toggles pause/resume for this specific download.
    let onPauseResume: () -> Void

    private var accentColor: Color { Color(red: 1, green: 0.23, blue: 0.42) }

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: active.track.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)
                .opacity(active.isPaused ? 0.6 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(active.track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if active.isPaused {
                        Text("Paused")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    if let source = active.source {
                        Text(source.title)
                        .font(.caption)
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)
                    }
                }

                DownloadProgressBar(progress: active.progress)
                    .frame(height: 3)
                    .opacity(active.isPaused ? 0.5 : 1)
            }

            Button(action: onPauseResume) {
                Image(systemName: active.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(active.isPaused ? accentColor : AppTheme.secondaryText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.controlFillStrong))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active.isPaused ? "Resume download" : "Pause download")
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
    let record: DownloadRecord
    let assignedFolder: DownloadFolder?
    let downloadFolders: [DownloadFolder]
    var isSelecting: Bool = false
    var isSelected: Bool = false
    let onMove: (String?) -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

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
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? accentColor : AppTheme.tertiaryText)
                    .transition(.scale.combined(with: .opacity))
            }

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

                        if let source = record.source {
                            Text(source.title)
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
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if isSelecting == false {
                TrackActionsButton(track: record.localTrack, size: 32)

                DownloadFolderMenu(record: record, folders: downloadFolders, onMove: onMove)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(AppTheme.controlFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? accentColor.opacity(0.12) : (isCurrentTrack ? accentColor.opacity(0.07) : Color.clear))
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
    let record: DownloadRecord
    let folders: [DownloadFolder]
    let onMove: (String?) -> Void

    var body: some View {
        Menu {
            Button {
                onMove(nil)
            } label: {
                Label("No Folder", systemImage: record.folderID == nil ? "checkmark" : "folder.badge.minus")
            }

            ForEach(folders) { folder in
                Button {
                    onMove(folder.id)
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
