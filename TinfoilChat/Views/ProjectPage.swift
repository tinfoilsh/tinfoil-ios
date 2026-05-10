//
//  ProjectPage.swift
//  TinfoilChat
//
//  Full-screen project landing page shown when a project is active and no
//  project chat is currently selected.
//

import SwiftUI

struct ProjectPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel

    @State private var deletingChatId: String?
    @State private var showDeleteChatAlert = false
    @State private var editingName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    private var project: Project? {
        viewModel.activeProject
    }

    var body: some View {
        Form {
                if let project {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Project name", text: $editingName)
                                    .font(.headline)
                                    .textFieldStyle(.plain)
                                    .submitLabel(.done)
                                    .focused($isNameFieldFocused)
                                    .onSubmit { commitName() }
                                    .onChange(of: isNameFieldFocused) { _, focused in
                                        if !focused { commitName() }
                                    }
                                if !project.description.isEmpty {
                                    Text(project.description)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.cardSurface(for: colorScheme))
                }

                Section {
                    NavigationLink {
                        ProjectDetailsView(viewModel: viewModel)
                    } label: {
                        Label("Details", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        ProjectDocumentsView(viewModel: viewModel)
                    } label: {
                        HStack {
                            Label("Documents", systemImage: "doc.text")
                            Spacer()
                            if !viewModel.projectDocuments.isEmpty {
                                Text("\(viewModel.projectDocuments.count)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        ProjectSettingsView(viewModel: viewModel)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))

                Section {
                    Button {
                        viewModel.startNewProjectChat()
                    } label: {
                        Label("New project chat", systemImage: "square.and.pencil")
                    }
                    .disabled(project == nil)

                    if viewModel.activeProjectChats.isEmpty {
                        Text("No project chats yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.activeProjectChats) { chat in
                            chatRow(chat)
                        }
                    }
                } header: {
                    Text("Project chats")
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .onAppear { syncEditingName() }
        .onChange(of: project?.id) { _, _ in syncEditingName() }
        .onChange(of: project?.name) { _, _ in
            if !isNameFieldFocused { syncEditingName() }
        }
        .alert("Delete Chat", isPresented: $showDeleteChatAlert) {
            Button("Cancel", role: .cancel) {
                deletingChatId = nil
            }
            Button("Delete", role: .destructive) {
                if let deletingChatId {
                    viewModel.deleteChat(deletingChatId)
                }
                deletingChatId = nil
            }
        }
    }

    private func syncEditingName() {
        editingName = project?.name ?? ""
    }

    private func commitName() {
        guard let project else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else {
            editingName = project.name
            return
        }
        Task {
            await viewModel.updateActiveProject(name: trimmed)
        }
    }

    private func chatRow(_ chat: Chat) -> some View {
        Button {
            viewModel.openProjectChat(chat)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !chat.isBlankChat {
                        Text(relativeTimeString(from: chat.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deletingChatId = chat.id
                showDeleteChatAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task {
                    await viewModel.removeChatFromProject(chatId: chat.id)
                }
            } label: {
                Label("Remove", systemImage: "arrow.uturn.left")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                Task {
                    await viewModel.removeChatFromProject(chatId: chat.id)
                }
            } label: {
                Label("Remove from Project", systemImage: "arrow.uturn.left")
            }

            ForEach(viewModel.projects.filter { $0.id != project?.id }) { destination in
                Button {
                    Task {
                        await viewModel.moveChatToProject(chatId: chat.id, projectId: destination.id)
                    }
                } label: {
                    Label("Move to \(destination.name)", systemImage: "folder")
                }
            }
        }
    }

    private func relativeTimeString(from date: Date) -> String {
        let difference = Date().timeIntervalSince(date)
        if difference < 60 {
            return "Just now"
        } else if difference < 3600 {
            return "\(Int(difference / 60))m ago"
        } else if difference < 86400 {
            return "\(Int(difference / 3600))h ago"
        } else if difference < 604800 {
            return "\(Int(difference / 86400))d ago"
        } else {
            return "\(Int(difference / 604800))w ago"
        }
    }
}

// MARK: - Project Details Page

struct ProjectDetailsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel

    @State private var editingDescription = ""
    @State private var editingInstructions = ""
    @State private var editingMemory = ""
    @State private var hasPendingChanges = false
    @State private var isSaving = false

    private var project: Project? {
        viewModel.activeProject
    }

    var body: some View {
        Form {
            Section("Description") {
                TextField("What is this project about?", text: $editingDescription, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: editingDescription) { _, _ in hasPendingChanges = true }
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            Section("Instructions") {
                TextField("How should Tin behave in this project?", text: $editingInstructions, axis: .vertical)
                    .lineLimit(5...15)
                    .onChange(of: editingInstructions) { _, _ in hasPendingChanges = true }
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))

            Section {
                TextField("One fact per line", text: $editingMemory, axis: .vertical)
                    .lineLimit(5...15)
                    .onChange(of: editingMemory) { _, _ in hasPendingChanges = true }
            } header: {
                Text("Memory")
            } footer: {
                Text("Each line becomes a memory fact stored with the project.")
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    saveChanges()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(!hasPendingChanges || project == nil || isSaving)
            }
        }
        .onAppear(perform: syncEditingState)
        .onChange(of: project?.id) { _, _ in syncEditingState() }
    }

    private func saveChanges() {
        Task {
            isSaving = true
            viewModel.projectError = nil
            await viewModel.updateActiveProject(
                description: editingDescription,
                systemInstructions: editingInstructions,
                memory: memoryFactsFromEditor()
            )
            if viewModel.projectError == nil {
                hasPendingChanges = false
            }
            isSaving = false
        }
    }

    private func syncEditingState() {
        guard let project else { return }
        editingDescription = project.description
        editingInstructions = project.systemInstructions
        editingMemory = project.memory.map(\.fact).joined(separator: "\n")
        hasPendingChanges = false
    }

    private func memoryFactsFromEditor() -> [MemoryFact] {
        let existing = Dictionary((project?.memory ?? []).map { ($0.fact, $0) }, uniquingKeysWith: { first, _ in first })
        return editingMemory
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                existing[line] ?? MemoryFact(
                    id: UUID().uuidString.lowercased(),
                    fact: line,
                    date: ISO8601DateFormatter().string(from: Date()),
                    category: "other",
                    confidence: 1
                )
            }
    }
}

// MARK: - Project Documents Page

struct ProjectDocumentsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @State private var showDocumentPicker = false

    var body: some View {
        Form {
            if viewModel.projectDocuments.isEmpty && !viewModel.isUploadingProjectDocument {
                Section {
                    Text("No documents yet. Add files to use as context for this project.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            } else {
                Section {
                    ForEach(viewModel.projectDocuments) { document in
                        documentRow(document)
                    }

                    if viewModel.isUploadingProjectDocument {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Uploading…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showDocumentPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.isUploadingProjectDocument)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { url, fileName in
                Task {
                    await viewModel.uploadProjectDocument(url: url, filename: fileName)
                }
            }
        }
    }

    private func documentRow(_ document: ProjectDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.filename.isEmpty ? "Encrypted" : document.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(formatFileSize(document.sizeBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task {
                    await viewModel.deleteProjectDocument(document.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}

// MARK: - Project Settings Page

struct ProjectSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    @State private var showDeleteAlert = false

    private var project: Project? {
        viewModel.activeProject
    }

    var body: some View {
        Form {
            if let project {
                Section("Project info") {
                    LabeledContent("Created", value: relativeDate(project.createdAt))
                    LabeledContent("Updated", value: relativeDate(project.updatedAt))
                    LabeledContent("Documents", value: "\(viewModel.projectDocuments.count)")
                    LabeledContent("Chats", value: "\(viewModel.activeProjectChats.count)")
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            }

            Section {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete project", systemImage: "trash")
                }
                .disabled(project == nil)
            } footer: {
                Text("Deletes the project, its context documents, and removes this project from all associated chats.")
            }
            .listRowBackground(Color.cardSurface(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Project", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteActiveProject()
                }
            }
        } message: {
            Text("This deletes the project and its project context documents.")
        }
    }

    private func relativeDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
        let style = RelativeDateTimeFormatter()
        style.unitsStyle = .abbreviated
        return style.localizedString(for: date, relativeTo: Date())
    }
}
