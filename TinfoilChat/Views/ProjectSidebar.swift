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

    @State private var settingsExpanded = false
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

            ScrollView {
                VStack(spacing: 12) {
                    settingsSection
                    documentsSection
                    chatsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .applyAlwaysBounceIfAvailable()

            Divider()
                .background(Color.gray.opacity(0.3))

            Button {
                viewModel.exitProject()
                withAnimation {
                    isOpen = false
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Exit Project")
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .background(Color.sidebarButtonBackground(for: colorScheme))
            .cornerRadius(8)
            .padding(16)
            .safeAreaPadding(.bottom)
        }
        .frame(width: 300)
        .background(colorScheme == .dark ? Color.sidebarBackground(for: colorScheme) : Color.white)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder")
                    .foregroundColor(.accentColor)
                Text(project?.name ?? "Loading...")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation {
                        isOpen = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
            }

            Text("Project context, documents, and chats")
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

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Project Params", systemImage: "slider.horizontal.3", isExpanded: $settingsExpanded)

            if settingsExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Project name", text: $editingName)
                        .textFieldStyle(.roundedBorder)

                    TextField("Description", text: $editingDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                    TextField("Instructions", text: $editingInstructions, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)

                    TextField("Memory", text: $editingMemory, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)

                    HStack {
                        Button("Save") {
                            Task {
                                await viewModel.updateActiveProject(
                                    name: editingName.trimmingCharacters(in: .whitespacesAndNewlines),
                                    description: editingDescription,
                                    systemInstructions: editingInstructions,
                                    memory: memoryFactsFromEditor()
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Delete", role: .destructive) {
                            showDeleteProjectAlert = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .sectionCard()
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Project Documents", systemImage: "doc.text", isExpanded: $documentsExpanded)

            if documentsExpanded {
                if viewModel.projectDocuments.isEmpty && !viewModel.isUploadingProjectDocument {
                    Text("No documents yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(viewModel.projectDocuments) { document in
                    HStack(spacing: 8) {
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
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                await viewModel.deleteProjectDocument(document.id)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground).opacity(0.35))
                    .cornerRadius(8)
                }

                if viewModel.isUploadingProjectDocument {
                    HStack {
                        ProgressView()
                        Text("Uploading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    showDocumentPicker = true
                } label: {
                    Label("Add document", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isUploadingProjectDocument)
            }
        }
        .sectionCard()
    }

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Project Chats", systemImage: "bubble.left.and.bubble.right", isExpanded: $chatsExpanded)

            if chatsExpanded {
                Button {
                    viewModel.createNewChat(isLocalOnly: false, projectId: project?.id)
                    withAnimation {
                        isOpen = false
                    }
                } label: {
                    Label("New project chat", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ForEach(viewModel.activeProjectChats) { chat in
                    ChatListItem(
                        chat: chat,
                        isSelected: viewModel.currentChat?.id == chat.id,
                        isEditing: editingChatId == chat.id,
                        editingTitle: $editingTitle,
                        timeString: relativeTimeString(from: chat.createdAt),
                        onSelect: {
                            viewModel.selectChat(chat)
                            withAnimation {
                                isOpen = false
                            }
                        },
                        onEdit: {
                            if editingChatId == chat.id {
                                viewModel.updateChatTitle(chat.id, newTitle: editingTitle)
                                editingChatId = nil
                            } else {
                                editingChatId = chat.id
                                editingTitle = chat.title
                            }
                        },
                        onDelete: {
                            deletingChatId = chat.id
                            showDeleteChatAlert = true
                        },
                        showEditDelete: true
                    )
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
            }
        }
        .sectionCard()
    }

    private func sectionHeader(title: String, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func syncEditingState() {
        guard let project else { return }
        editingName = project.name
        editingDescription = project.description
        editingInstructions = project.systemInstructions
        editingMemory = project.memory.map(\.fact).joined(separator: "\n\n")
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
    func applyAlwaysBounceIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollBounceBehavior(.always)
        } else {
            self
        }
    }

    func sectionCard() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemBackground).opacity(0.3))
            .cornerRadius(12)
    }
}
