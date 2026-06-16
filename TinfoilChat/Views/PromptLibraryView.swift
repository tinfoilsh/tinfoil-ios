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

struct PromptLibraryView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme

    /// When set, the library shows per-chat selection affordances and a
    /// checkmark next to the active preset.
    var activePresetId: String? = nil
    var onSelectPreset: ((String?) -> Void)? = nil

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
                onEdit: { editorTarget = .edit(presetId: $0) },
                onRequestDelete: { presetPendingDelete = $0 }
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 24)
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
                if activePresetId == preset.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                        .accessibilityLabel("Active")
                }
            }
        }
    }
}

// MARK: - Detail

struct PromptDetailView: View {
    let presetId: String
    var activePresetId: String?
    var onSelectPreset: ((String?) -> Void)?
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
                HStack(spacing: 12) {
                    Image(systemName: preset.iconName)
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
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
                    Spacer()
                }

                if onSelectPreset != nil {
                    Button {
                        onSelectPreset?(isActive ? nil : preset.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: isActive ? "xmark.circle" : "sparkles")
                            Text(isActive ? "Stop using" : "Use for this chat")
                        }
                    }
                }
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
                    profileManager.duplicatePromptPreset(id: preset.id)
                    dismiss()
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
                        onRequestDelete(preset)
                        dismiss()
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
                    Text("Placeholders supported: {USER_PREFERENCES}, {LANGUAGE}, {CURRENT_DATETIME}, {TIMEZONE}.")
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
