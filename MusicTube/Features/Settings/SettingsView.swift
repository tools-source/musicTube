import StoreKit
import SwiftUI

private struct LibrarySectionView<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var showsDragHandle = false
    var isHighlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 12)

                if showsDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(isHighlighted ? 0.14 : 0.08) : Color.black.opacity(isHighlighted ? 0.10 : 0.05))
                        )
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.38))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark
                                    ? Color.white.opacity(isHighlighted ? 0.16 : 0.06)
                                    : Color.black.opacity(isHighlighted ? 0.16 : 0.07),
                                lineWidth: 1
                            )
                    }
                    .overlay {
                        if isHighlighted {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(Color(red: 1, green: 0.23, blue: 0.42).opacity(0.42), lineWidth: 2)
                        }
                    }
            )
            .scaleEffect(isHighlighted ? 1.01 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isHighlighted)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isShowingDeleteDataConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    AccountSectionView(
                        authentication: viewModel.authentication,
                        isShowingDeleteDataConfirmation: $isShowingDeleteDataConfirmation
                    )
                        .appearTransition(delay: 0.04)
                    PreferenceManagementSectionView(viewModel: viewModel)
                        .appearTransition(delay: 0.10)
                    DataUsageSectionView()
                        .appearTransition(delay: 0.16)
                    LegalAndSupportSectionView()
                        .appearTransition(delay: 0.20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle(viewModel.authentication.isConnected ? "Account" : "Settings")
            .navigationBarTitleDisplayMode(.large)
            .auroraScreenBackground()
            .alert(
                "Delete MusicTube Data from This iPhone?",
                isPresented: $isShowingDeleteDataConfirmation
            ) {
                Button("Delete Data", role: .destructive) {
                    Task {
                        await viewModel.authentication.deleteLocalData()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes your local library, playlists, downloads, likes, and listening history from this iPhone. Your Google and YouTube accounts are not affected.")
            }
        }
    }

    private var bottomSpacing: CGFloat {
        viewModel.hasNowPlaying ? 174 : 108
    }
}

// MARK: - AccountSectionView

private struct AccountSectionView: View {
    @ObservedObject var authentication: AuthenticationViewModel
    @Binding var isShowingDeleteDataConfirmation: Bool

    var body: some View {
        LibrarySectionView(title: authentication.isConnected ? "Account" : "Guest Mode") {
            VStack(alignment: .leading, spacing: 16) {
                if let user = authentication.user {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(user.name)
                            .font(.headline)
                            .foregroundStyle(Color.primary)

                        Text(user.email)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your library is local and ready to use.")
                            .font(.headline)
                            .foregroundStyle(Color.primary)

                        Text("Connect YouTube anytime to import your account library while keeping your MusicTube guest library and playlists on this device.")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                    .overlay(Color.secondary.opacity(0.2))

                if let libraryStatusMessage = authentication.statusMessage {
                    Text(libraryStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if authentication.isConnected {
                    Button {
                        Task { await authentication.switchAccount() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                            Text("Switch Account")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color(red: 1, green: 0.23, blue: 0.42))
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(authentication.isLoading)

                    Button("Disconnect YouTube", role: .destructive) {
                        Task {
                            await authentication.signOut()
                        }
                    }
                    .font(.headline)
                } else {
                    Button {
                        Task {
                            await authentication.signIn()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("Connect YouTube")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 1, green: 0.23, blue: 0.42))
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(authentication.isLoading)
                }

                Button("Delete MusicTube Data", role: .destructive) {
                    isShowingDeleteDataConfirmation = true
                }
                .font(.headline)
                .disabled(authentication.isDeletingData)

                if authentication.isDeletingData {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.primary)
                        Text("Deleting local MusicTube data...")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - PreferenceManagementSectionView

private struct PreferenceManagementSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var newPreferenceName = ""
    @State private var editingCustomPreference: UserPreferenceTag?

    private var selectedIDs: Set<String> {
        Set(viewModel.preferenceProfile.selectedTags.map(\.id))
    }

    private var customTags: [UserPreferenceTag] {
        viewModel.preferenceProfile.customTags.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        LibrarySectionView(title: "Personalization") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Interests help MusicTube start in the right direction. Your listening, likes, skips, and replays keep shaping recommendations over time.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                selectedInterests

                Menu {
                    ForEach(UserPreferenceCategory.allCases) { category in
                        let options = availableOptions(for: category)
                        if options.isEmpty == false {
                            Section(category.title) {
                                ForEach(options) { option in
                                    Button(option.name) {
                                        viewModel.addPreference(option)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Existing Interest")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(AppTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Divider().overlay(AppTheme.divider)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Add Custom Interest")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)

                    HStack(spacing: 10) {
                        TextField("Add an interest", text: $newPreferenceName)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(AppTheme.inputFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onSubmit(addPreference)

                        Button(action: addPreference) {
                            Image(systemName: "plus")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(AppTheme.accent)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    if customTags.isEmpty && selectedIDs.isEmpty {
                        Text("Add anything specific you want MusicTube to understand, like Oud, Gym, Coding, Sleep, or Turkish Music.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .sheet(item: $editingCustomPreference) { tag in
            CustomPreferenceEditSheet(tag: tag, viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var selectedInterests: some View {
        if selectedIDs.isEmpty && customTags.isEmpty {
            Text("No interests selected yet.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(UserPreferenceCategory.allCases) { category in
                    let tags = selectedTags(for: category)
                    if tags.isEmpty == false {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(category.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryText)

                            FlowLayout(spacing: 8) {
                                ForEach(tags) { tag in
                                    if tag.isCustom {
                                        CustomPreferenceChip(tag: tag) {
                                            editingCustomPreference = tag
                                        } onRemove: {
                                            viewModel.removePreference(tag.id)
                                        }
                                    } else {
                                        SelectedPreferenceChip(tag: tag) {
                                            viewModel.removePreference(tag.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func selectedTags(for category: UserPreferenceCategory) -> [UserPreferenceTag] {
        viewModel.preferenceProfile.selectedTags
            .filter { $0.category == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func availableOptions(for category: UserPreferenceCategory) -> [UserPreferenceTag] {
        UserPreferenceProfile.defaultOptions[category, default: []]
            .filter { selectedIDs.contains($0.id) == false }
    }

    private func addPreference() {
        let trimmed = newPreferenceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        viewModel.addCustomPreference(named: trimmed, category: .genres)
        newPreferenceName = ""
    }
}

private struct SelectedPreferenceChip: View {
    let tag: UserPreferenceTag
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 6) {
                Text(tag.name)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.caption2.bold())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.controlFill)
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(tag.name)")
    }
}

private struct CustomPreferenceChip: View {
    let tag: UserPreferenceTag
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onEdit) {
                HStack(spacing: 6) {
                    Text(tag.name)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.caption2.bold())
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(tag.name)")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(.leading, 2)
                    .padding(.trailing, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(tag.name)")
        }
        .background(AppTheme.controlFill)
        .clipShape(Capsule(style: .continuous))
    }
}

private struct CustomPreferenceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: SettingsViewModel
    let tag: UserPreferenceTag
    @State private var name: String
    @State private var category: UserPreferenceCategory

    init(tag: UserPreferenceTag, viewModel: SettingsViewModel) {
        self.tag = tag
        self.viewModel = viewModel
        _name = State(initialValue: tag.name)
        _category = State(initialValue: tag.category)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Interest name")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)

                    TextField("Interest", text: $name)
                        .textInputAutocapitalization(.words)
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(AppTheme.inputFill)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Category")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)

                    Picker("Category", selection: $category) {
                        ForEach(UserPreferenceCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AppTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(AppTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button(role: .destructive) {
                    viewModel.removePreference(tag.id)
                    dismiss()
                } label: {
                    Label("Delete Interest", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(Color.red.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(AppTheme.screenBackground.ignoresSafeArea())
            .navigationTitle("Edit Interest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.secondaryText)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.accent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(340), .medium])
    }

    private func save() {
        viewModel.updatePreference(tag.id, name: name, category: category)
    }
}

// MARK: - DataUsageSectionView

private struct DataUsageSectionView: View {
    @ObservedObject private var settings = DataUsageSettings.shared
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        LibrarySectionView(title: "Data Usage") {
            VStack(spacing: 0) {
                dataRow(
                    icon: "bolt.slash.fill",
                    iconColor: Color.orange,
                    title: "Data Saver Mode",
                    subtitle: "Reduces quality and disables non-essential requests",
                    isOn: $settings.dataSaverMode
                )
                divider
                dataRow(
                    icon: "antenna.radiowaves.left.and.right",
                    iconColor: AppTheme.accent,
                    title: "Stream on Cellular",
                    subtitle: "Allow audio playback over mobile data",
                    isOn: $settings.allowStreamOnCellular
                )
                .opacity(settings.dataSaverMode ? 0.4 : 1)
                .disabled(settings.dataSaverMode)
                divider
                dataRow(
                    icon: "arrow.down.circle.fill",
                    iconColor: Color(red: 0.3, green: 0.7, blue: 0.4),
                    title: "Download on Cellular",
                    subtitle: "Allow downloads over mobile data",
                    isOn: $settings.allowDownloadOnCellular
                )
                .opacity(settings.dataSaverMode ? 0.4 : 1)
                .disabled(settings.dataSaverMode)
                divider
                dataRow(
                    icon: "wifi",
                    iconColor: Color(red: 0.2, green: 0.6, blue: 1.0),
                    title: "High Quality on Wi-Fi Only",
                    subtitle: "Use lower quality audio when on cellular",
                    isOn: $settings.highQualityOnWiFiOnly
                )
                divider
                dataRow(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: Color(red: 0.5, green: 0.3, blue: 0.9),
                    title: "Auto Sync on Wi-Fi Only",
                    subtitle: "Defer library syncs until Wi-Fi is available",
                    isOn: $settings.autoSyncOnWiFiOnly
                )
                divider
                dataRow(
                    icon: "sparkles",
                    iconColor: Color(red: 0.65, green: 0.3, blue: 0.9),
                    title: "AI Recommendations",
                    subtitle: aiRecommendationSubtitle,
                    isOn: $settings.personalizedAICuration
                )
                .opacity(AppConfig.AICuration.endpointURL == nil ? 0.5 : 1)
                .disabled(AppConfig.AICuration.endpointURL == nil)

                if network.isLowDataMode {
                    Divider().overlay(Color.secondary.opacity(0.18)).padding(.vertical, 4)
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                        Text("Low Data Mode is on in iOS Settings — some features are automatically restricted.")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var divider: some View {
        Divider()
            .overlay(Color.secondary.opacity(0.18))
            .padding(.vertical, 2)
    }

    private var aiRecommendationSubtitle: String {
        if AppConfig.AICuration.endpointURL == nil {
            return "Unavailable in this build; recommendations stay on device"
        }
        return "Share recent searches and listening preferences with MusicTube's curation service"
    }

    private func dataRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.accent)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - LegalAndSupportSectionView

private struct LegalAndSupportSectionView: View {
    private let privacyURL = URL(string: "https://music-tube.me/PRIVACY_POLICY.html")!
    private let termsURL = URL(string: "https://music-tube.me/TERMS.html")!
    private let supportURL = URL(string: "https://music-tube.me/SUPPORT.html")!

    var body: some View {
        LibrarySectionView(title: "About & Privacy") {
            VStack(spacing: 0) {
                legalLink("Privacy Policy", systemImage: "hand.raised.fill", destination: privacyURL)
                divider
                legalLink("Terms of Service", systemImage: "doc.text.fill", destination: termsURL)
                divider
                legalLink("Support", systemImage: "questionmark.circle.fill", destination: supportURL)
                divider
                HStack {
                    Text("Version")
                    Spacer()
                    Text(versionText)
                        .foregroundStyle(Color.secondary)
                }
                .font(.subheadline)
                .padding(.vertical, 10)
            }
        }
    }

    private var divider: some View {
        Divider()
            .overlay(Color.secondary.opacity(0.18))
            .padding(.vertical, 2)
    }

    private func legalLink(_ title: String, systemImage: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 10)
        }
        .accessibilityHint("Opens in your browser")
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
