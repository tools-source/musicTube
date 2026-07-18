import SwiftUI

// MARK: - PreferenceOnboardingView

struct PreferenceOnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedIDs: Set<String> = []
    @State private var customInput = ""
    @State private var customTags: [String] = []

    private var selectedTags: [UserPreferenceTag] {
        UserPreferenceCategory.allCases.flatMap { category in
            UserPreferenceProfile.defaultOptions[category, default: []].filter {
                selectedIDs.contains($0.id)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.screenBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        preferenceSections
                        customTagEditor
                        continueButton
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 30)
                    .padding(.bottom, 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        appState.completePreferenceOnboarding(selectedTags: [], customTags: [])
                    }
                    .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 52, height: 52)
                .background(AppTheme.accent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))

            Text("Tune MusicTube for you")
                .font(.largeTitle.bold())
                .foregroundStyle(AppTheme.primaryText)

            Text("Pick a few interests to start. MusicTube will keep learning from what you actually play, like, replay, and skip.")
                .font(.body)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preferenceSections: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(UserPreferenceCategory.allCases) { category in
                PreferenceCategorySection(
                    title: category.title,
                    options: UserPreferenceProfile.defaultOptions[category, default: []],
                    selectedIDs: $selectedIDs
                )
            }
        }
    }

    private var customTagEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your own")
                .font(.title3.bold())
                .foregroundStyle(AppTheme.primaryText)

            HStack(spacing: 10) {
                TextField("Oud, Gym, Coding, Sleep...", text: $customInput)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .appSurface(fill: AppTheme.inputFill)
                    .onSubmit(addCustomTag)

                Button(action: addCustomTag) {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(AppTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            if customTags.isEmpty == false {
                FlowLayout(spacing: 8) {
                    ForEach(customTags, id: \.self) { tag in
                        Button {
                            customTags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: 6) {
                                Text(tag)
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
                    }
                }
            }
        }
    }

    private var continueButton: some View {
        Button {
            appState.completePreferenceOnboarding(
                selectedTags: selectedTags,
                customTags: customTags
            )
        } label: {
            Text(selectedIDs.isEmpty && customTags.isEmpty ? "Start Listening" : "Personalize MusicTube")
        }
        .buttonStyle(AppPrimaryActionButtonStyle())
    }

    private func addCustomTag() {
        let trimmed = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let normalized = SearchTextNormalizer.normalized(trimmed)
        guard customTags.contains(where: { SearchTextNormalizer.normalized($0) == normalized }) == false else {
            customInput = ""
            return
        }
        customTags.append(trimmed)
        customInput = ""
    }
}

struct PreferenceCategorySection: View {
    let title: String
    let options: [UserPreferenceTag]
    @Binding var selectedIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.primaryText)

            FlowLayout(spacing: 8) {
                ForEach(options) { option in
                    PreferenceChip(
                        title: option.name,
                        isSelected: selectedIDs.contains(option.id)
                    ) {
                        if selectedIDs.contains(option.id) {
                            selectedIDs.remove(option.id)
                        } else {
                            selectedIDs.insert(option.id)
                        }
                    }
                }
            }
        }
    }
}

struct PreferenceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.inverseText : AppTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isSelected ? AppTheme.inverseFill : AppTheme.controlFill)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "\(title), selected" : title)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(in: proposal.width ?? 320, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let placements = layout(in: bounds.width, subviews: subviews).placements
        for placement in placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(
        in width: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, placements: [(index: Int, origin: CGPoint, size: CGSize)]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var placements: [(Int, CGPoint, CGSize)] = []

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            placements.append((index, CGPoint(x: x, y: y), size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (CGSize(width: width, height: y + lineHeight), placements)
    }
}
