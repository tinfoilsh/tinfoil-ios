//
//  ProjectSidebar.swift
//  TinfoilChat
//
//  Sidebar shown while a project is active.
//

import SwiftUI

struct ProjectSidebar: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var isOpen: Bool
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel

    @State private var documentsExpanded = true
    @State private var chatsExpanded = true
    @State private var showDocumentPicker = false
    @State private var editingName = ""
    @State private var editingDescription = ""
    @State private var editingInstructions = ""
    @State private var editingMemory = ""
    @State private var editingChatId: String?
    @State private var editingTitle = ""
    @State private var deletingChatId: String?
    @State private var showDeleteChatAlert = false
    @State private var showDeleteProjectAlert = false
    @State private var hasPendingChanges = false

    private var project: Project? {
        viewModel.activeProject
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error = viewModel.projectError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            List {
                detailsSection
                documentsSection
                chatsSection
                deleteSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.settingsBackground(for: colorScheme))
            .scrollDismissesKeyboardIfAvailable()

            Divider()
                .background(Color.gray.opacity(0.3))

            exitButton
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .safeAreaPadding(.bottom)
        }
        .frame(width: 300)
        .background(Color.settingsBackground(for: colorScheme))
        .ignoresSafeArea(edges: .bottom)
        .onAppear(perform: syncEditingState)
        .onChange(of: project?.id) { _, _ in syncEditingState() }
        .onChange(of: project?.name) { _, _ in syncEditingState() }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { url, fileName in
                Task {
                    await viewModel.uploadProjectDocument(url: url, filename: fileName)
                }
            }
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
        .alert("Delete Project", isPresented: $showDeleteProjectAlert) {
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                Text(project?.name ?? "Project")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }

            Text("Context, documents, and chats")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(
            Divider().background(Color.gray.opacity(0.3)),
            alignment: .bottom
        )
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Name", text: $editingName)
                .submitLabel(.done)
                .onChange(of: editingName) { _, _ in hasPendingChanges = true }

            TextField("Description", text: $editingDescription, axis: .vertical)
                .lineLimit(2...4)
                .onChange(of: editingDescription) { _, _ in hasPendingChanges = true }

            TextField("Instructions", text: $editingInstructions, axis: .vertical)
                .lineLimit(3...8)
                .onChange(of: editingInstructions) { _, _ in hasPendingChanges = true }

            TextField("Memory (one fact per line)", text: $editingMemory, axis: .vertical)
                .lineLimit(3...8)
                .onChange(of: editingMemory) { _, _ in hasPendingChanges = true }

            Button {
                Task {
                    await viewModel.updateActiveProject(
                        name: editingName.trimmingCharacters(in: .whitespacesAndNewlines),
                        description: editingDescription,
                        systemInstructions: editingInstructions,
                        memory: memoryFactsFromEditor()
                    )
                    hasPendingChanges = false
                }
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Save changes")
                    Spacer()
                }
            }
            .disabled(!hasPendingChanges || project == nil)
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var documentsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $documentsExpanded) {
                if viewModel.projectDocuments.isEmpty && !viewModel.isUploadingProjectDocument {
                    Text("No documents yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

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

                Button {
                    showDocumentPicker = true
                } label: {
                    Label("Add document", systemImage: "plus.circle.fill")
                }
                .disabled(viewModel.isUploadingProjectDocument)
            } label: {
                Label("Documents", systemImage: "doc.text")
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
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

    private var chatsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $chatsExpanded) {
                Button {
                    viewModel.createNewChat(isLocalOnly: false, projectId: project?.id)
                    withAnimation {
                        isOpen = false
                    }
                } label: {
                    Label("New project chat", systemImage: "square.and.pencil")
                }

                if viewModel.activeProjectChats.isEmpty {
                    Text("No project chats yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.activeProjectChats) { chat in
                        chatRow(chat)
                    }
                }
            } label: {
                Label("Chats", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private func chatRow(_ chat: Chat) -> some View {
        Button {
            viewModel.selectChat(chat)
            withAnimation {
                isOpen = false
            }
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
                if viewModel.currentChat?.id == chat.id {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
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

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteProjectAlert = true
            } label: {
                Label("Delete project", systemImage: "trash")
            }
            .disabled(project == nil)
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var exitButton: some View {
        Button {
            viewModel.exitProject()
            withAnimation {
                isOpen = false
            }
        } label: {
            HStack {
                Image(systemName: "arrow.left")
                Text("Exit Project")
                    .fontWeight(.medium)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(Color.sidebarButtonBackground(for: colorScheme))
            .foregroundColor(colorScheme == .dark ? .white : .black)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.gray.opacity(0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func syncEditingState() {
        guard let project else { return }
        editingName = project.name
        editingDescription = project.description
        editingInstructions = project.systemInstructions
        editingMemory = project.memory.map(\.fact).joined(separator: "\n\n")
        hasPendingChanges = false
    }

    private func memoryFactsFromEditor() -> [MemoryFact] {
        let existing = Dictionary(uniqueKeysWithValues: (project?.memory ?? []).map { ($0.fact, $0) })
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

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
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

private extension View {
    @ViewBuilder
    func scrollDismissesKeyboardIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}
