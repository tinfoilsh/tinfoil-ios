//
//  PromptLibraryView.swift
//  TinfoilChat
//
//  Prompt library UI: browse built-in presets, manage custom prompts, and
//  optionally pick an active preset for the current chat.
//

import SwiftUI

/// Strips the `<system>...</system>` wrapper used to store prompts.
func stripSystemTags(_ prompt: String) -> String {
    var result = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.hasPrefix("<system>") {
        result = String(result.dropFirst("<system>".count))
    }
    if result.hasSuffix("</system>") {
        result = String(result.dropLast("</system>".count))
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Wraps a prompt body in `<system>` tags unless already wrapped.
func ensureSystemTags(_ prompt: String) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    if trimmed.hasPrefix("<system>") && trimmed.hasSuffix("</system>") {
        return trimmed
    }
    return "<system>\n\(trimmed)\n</system>"
}

/// Compact grid of prompt presets shown directly above the chat input on the
/// welcome screen. Tapping a preset toggles it for the current chat; "More"
/// opens the full library.
struct PromptSuggestionsBar: View {
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @ObservedObject private var profileManager = ProfileManager.shared
    var onOpenLibrary: () -> Void

    private var activePresetId: String? {
        viewModel.currentChat?.promptPresetId
    }

    /// User-pinned favorites, with any remaining slots filled by the default
    /// built-in presets so the home screen always offers a full set.
    private var suggestions: [PromptPreset] {
        let target = Constants.PromptLibrary.homeSuggestionCount
        var result = profileManager.favoritePromptPresets
        let pinnedIds = Set(result.map { $0.id })
        for preset in PromptPreset.builtIns where result.count < target {
            if !pinnedIds.contains(preset.id) {
                result.append(preset)
            }
        }
        return Array(result.prefix(target))
    }

    var body: some View {
        let suggested = suggestions
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(suggested) { preset in
                let isActive = activePresetId == preset.id
                Button {
                    viewModel.setPromptPreset(isActive ? nil : preset.id)
                } label: {
                    pill(iconName: preset.iconName, title: preset.name, isActive: isActive)
                }
                .buttonStyle(.plain)
            }

            Button {
                onOpenLibrary()
            } label: {
                pill(iconName: "square.grid.2x2", title: "More", isActive: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func pill(iconName: String, title: String, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 13))
            Text(title)
                .font(.system(.footnote, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(isActive ? Color.adaptiveAccent : .secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.adaptiveAccent.opacity(0.12) : Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.adaptiveAccent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

struct PromptLibraryView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme

    /// When set, the library shows per-chat selection affordances and a
    /// checkmark next to the active preset.
    var activePresetId: String? = nil
    var onSelectPreset: ((String?) -> Void)? = nil

    /// When set, the detail screen offers "Start chat with this prompt".
    var viewModel: TinfoilChat.ChatViewModel? = nil
    /// Called after a chat is started so the presenter can dismiss itself.
    var onStarted: (() -> Void)? = nil

    @State private var editorTarget: PromptEditorTarget?
    @State private var presetPendingDelete: PromptPreset?

    private var customPresets: [PromptPreset] {
        profileManager.customPromptPresets.map { PromptPreset(from: $0) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(PromptPreset.builtIns) { preset in
                    presetRow(preset)
                }
            } header: {
                Text("Built-in")
            } footer: {
                Text("Pin up to \(Constants.PromptLibrary.maxFavorites) favorites to show them on the home screen.")
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            Section {
                if customPresets.isEmpty {
                    Text("No custom prompts yet. Tap + to create one.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(customPresets) { preset in
                        presetRow(preset)
                    }
                }
            } header: {
                HStack {
                    Text("Your Prompts")
                    Spacer()
                    Button {
                        editorTarget = .create
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New prompt")
                }
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editorTarget) { target in
            PromptEditorView(target: target)
        }
        .confirmationDialog(
            "Delete prompt?",
            isPresented: Binding(
                get: { presetPendingDelete != nil },
                set: { if !$0 { presetPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: presetPendingDelete
        ) { preset in
            Button("Delete \"\(preset.name)\"", role: .destructive) {
                if activePresetId == preset.id {
                    onSelectPreset?(nil)
                }
                profileManager.deletePromptPreset(id: preset.id)
                presetPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { presetPendingDelete = nil }
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: PromptPreset) -> some View {
        NavigationLink {
            PromptDetailView(
                presetId: preset.id,
                activePresetId: activePresetId,
                onSelectPreset: onSelectPreset,
                viewModel: viewModel,
                onStarted: onStarted,
                onEdit: { editorTarget = .edit(presetId: $0) },
                onRequestDelete: { presetPendingDelete = $0 }
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preset.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                    .alignmentGuide(.top) { $0[.top] - 2 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.body)
                    if !preset.description.isEmpty {
                        Text(preset.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if profileManager.isFavoritePreset(preset.id) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                        .accessibilityLabel("Favorite")
                }
                if activePresetId == preset.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                        .accessibilityLabel("Active")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let isFavorite = profileManager.isFavoritePreset(preset.id)
            Button {
                profileManager.toggleFavoritePreset(preset.id)
            } label: {
                Label(
                    isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            .tint(.yellow)
            .disabled(!profileManager.canToggleFavorite(preset.id))
        }
    }
}

// MARK: - Detail

struct PromptDetailView: View {
    let presetId: String
    var activePresetId: String?
    var onSelectPreset: ((String?) -> Void)?
    var viewModel: TinfoilChat.ChatViewModel?
    var onStarted: (() -> Void)?
    var onEdit: (String) -> Void
    var onRequestDelete: (PromptPreset) -> Void

    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var preset: PromptPreset? {
        profileManager.promptPreset(for: presetId)
    }

    var body: some View {
        Group {
            if let preset {
                content(preset)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func content(_ preset: PromptPreset) -> some View {
        let isActive = activePresetId == preset.id
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: preset.iconName)
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .frame(width: 28, alignment: .center)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(preset.name)
                            .font(.headline)
                        if !preset.description.isEmpty {
                            Text(preset.description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Text(preset.isBuiltIn ? "Built-in" : "Custom")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                    }
                    Spacer(minLength: 0)
                }

                if let viewModel {
                    Button {
                        let presetId = preset.id
                        let started = onStarted
                        // Dismiss first, then mutate the view model on the next
                        // runloop tick so we never publish changes to an observed
                        // object while SwiftUI is processing the dismissal update.
                        dismiss()
                        DispatchQueue.main.async {
                            viewModel.startChat(withPresetId: presetId)
                            started?()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "plus.bubble")
                            Text("Start chat with this prompt")
                        }
                    }
                }

                if let onSelectPreset {
                    Button {
                        let newId = isActive ? nil : preset.id
                        dismiss()
                        DispatchQueue.main.async {
                            onSelectPreset(newId)
                        }
                    } label: {
                        HStack {
                            Image(systemName: isActive ? "xmark.circle" : "sparkles")
                            Text(isActive ? "Stop using" : "Use for this chat")
                        }
                    }
                }

                let isFavorite = profileManager.isFavoritePreset(preset.id)
                Button {
                    profileManager.toggleFavoritePreset(preset.id)
                } label: {
                    HStack {
                        Image(systemName: isFavorite ? "star.slash" : "star")
                        Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    }
                }
                .disabled(!profileManager.canToggleFavorite(preset.id))
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            Section {
                Text(preset.systemPrompt)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("System Prompt")
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            Section {
                Button {
                    let presetId = preset.id
                    dismiss()
                    DispatchQueue.main.async {
                        profileManager.duplicatePromptPreset(id: presetId)
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                if !preset.isBuiltIn {
                    Button {
                        onEdit(preset.id)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        let target = preset
                        dismiss()
                        DispatchQueue.main.async {
                            onRequestDelete(target)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle(preset.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Editor

enum PromptEditorTarget: Identifiable {
    case create
    case edit(presetId: String)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let presetId): return "edit:\(presetId)"
        }
    }
}

struct PromptEditorView: View {
    let target: PromptEditorTarget

    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. SQL Buddy", text: $name)
                } header: {
                    Text("Name")
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))

                Section {
                    TextField("What does this prompt do?", text: $description)
                } header: {
                    Text("Short Description")
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))

                Section {
                    TextEditor(text: $systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .accessibilityLabel("System prompt")
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("Placeholders supported: {USER_PREFERENCES}, {LANGUAGE}, {TIMEZONE}. The current time is always provided to the model automatically.")
                        .font(.caption)
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            }
            .scrollContentBackground(.hidden)
            .background(Color.settingsBackground(for: colorScheme))
            .navigationTitle(isEditing ? "Edit Prompt" : "New Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadExisting)
        }
    }

    private func loadExisting() {
        guard case .edit(let presetId) = target,
              let preset = profileManager.promptPreset(for: presetId) else { return }
        name = preset.name
        description = preset.description
        systemPrompt = stripSystemTags(preset.systemPrompt)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappedPrompt = ensureSystemTags(systemPrompt)
        guard !trimmedName.isEmpty, !wrappedPrompt.isEmpty else { return }

        switch target {
        case .create:
            profileManager.createPromptPreset(
                name: trimmedName,
                description: trimmedDescription,
                systemPrompt: wrappedPrompt
            )
        case .edit(let presetId):
            profileManager.updatePromptPreset(
                id: presetId,
                name: trimmedName,
                description: trimmedDescription,
                systemPrompt: wrappedPrompt
            )
        }
        dismiss()
    }
}
