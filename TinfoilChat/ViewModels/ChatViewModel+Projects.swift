import Foundation
import UniformTypeIdentifiers

extension ChatViewModel {
    // MARK: - Projects

    /// Projects belong to the account's stored chats: they need a
    /// subscription and cloud sync.
    private var canUseProjects: Bool {
        hasPremiumAccess && session?.account.cloud == true && session?.account.keyReady == true
    }

    func clearProjectState() {
        projectListLoadGeneration += 1
        projects = []
        leaveProjectContext()
    }

    func leaveProjectContext() {
        activeProject = nil
        projectDocuments = []
        projectError = nil
        isViewingProjectChat = false
    }

    func loadProjects() async {
        guard let session else { return }
        projectListLoadGeneration += 1
        let generation = projectListLoadGeneration
        guard canUseProjects else {
            projects = []
            projectError = nil
            isLoadingProjects = false
            return
        }
        isLoadingProjects = true
        projectError = nil
        defer { if generation == projectListLoadGeneration { isLoadingProjects = false } }
        do {
            let listed = try await HarnessProjects.list(session.account)
            guard generation == projectListLoadGeneration, self.session === session else { return }
            projects = listed.map(Project.init)
            if let active = activeProject, let current = projects.first(where: { $0.id == active.id }) {
                activeProject = current
            } else if activeProject != nil {
                leaveProjectContext()
            }
        } catch {
            guard generation == projectListLoadGeneration, !(error is CancellationError) else { return }
            projectError = error.localizedDescription
        }
    }

    @discardableResult
    func createProject(name: String? = nil, color: String? = nil) async -> Project? {
        guard let session, canUseProjects else { return nil }
        projectError = nil
        do {
            let created = Project(try await HarnessProjects.create(
                session.account,
                name: name ?? "My Project #\(projects.count + 1)",
                description: "",
                systemInstructions: "",
                color: color
            ))
            guard self.session === session else { return nil }
            projects.insert(created, at: 0)
            return created
        } catch {
            projectError = error.localizedDescription
            return nil
        }
    }

    func enterProject(projectId: String) async {
        guard canUseProjects, await loadActiveProject(projectId: projectId) else { return }
        createNewChat(isLocalOnly: false, projectId: projectId, focusInput: false)
    }

    /// Loads a project and its documents, and makes it the active context,
    /// which shows the project's page. A newer load supersedes one in
    /// flight, which neither changes the context nor reports success.
    @discardableResult
    func loadActiveProject(projectId: String) async -> Bool {
        guard let session, canUseProjects else { return false }
        projectLoadGeneration += 1
        let generation = projectLoadGeneration
        isLoadingProject = true
        projectError = nil
        defer { if generation == projectLoadGeneration { isLoadingProject = false } }
        do {
            let loaded = try await HarnessProjects.get(session.account, id: projectId)
            guard generation == projectLoadGeneration, self.session === session, canUseProjects else { return false }
            let project = Project(loaded)
            projects = projects.map { $0.id == project.id ? project : $0 }
            if !projects.contains(where: { $0.id == project.id }) { projects.insert(project, at: 0) }
            isViewingProjectChat = false
            activeProject = project
            projectDocuments = (loaded.documents ?? []).map(ProjectDocument.init)
            return true
        } catch {
            guard generation == projectLoadGeneration, !(error is CancellationError) else { return false }
            projectError = error.localizedDescription
            return false
        }
    }

    func exitProject() {
        leaveProjectContext()
        shouldExpandProjectsInSidebar = true
        createNewChat(isLocalOnly: false, focusInput: false)
    }

    func returnToProjectLanding() {
        guard hasPremiumAccess, let projectId = activeProject?.id else { return }
        isViewingProjectChat = false
        createNewChat(isLocalOnly: false, projectId: projectId, focusInput: false)
    }

    func openProjectChat(_ chat: ChatListSummary) {
        guard hasPremiumAccess, chat.projectId != nil else { return }
        _ = selectChat(id: chat.id, isLocalOnly: false)
        isViewingProjectChat = true
    }

    func startNewProjectChat() {
        guard hasPremiumAccess, let projectId = activeProject?.id else { return }
        createNewChat(isLocalOnly: false, projectId: projectId)
        isViewingProjectChat = true
    }

    /// The stored chats of the active project, the latest active first.
    var activeProjectChats: [ChatListSummary] {
        guard let projectId = activeProject?.id else { return [] }
        return cloudSidebarSummaries.filter { $0.projectId == projectId && !$0.isTemporary && !$0.isBlankChat }
    }

    func updateActiveProject(name: String? = nil, color: String? = nil, description: String? = nil, systemInstructions: String? = nil) async {
        guard let session, canUseProjects, let project = activeProject else { return }
        projectError = nil
        do {
            let updated = Project(try await HarnessProjects.update(
                session.account,
                id: project.id,
                name: name,
                description: description,
                systemInstructions: systemInstructions,
                color: color.map(Nullable.value)
            ))
            guard self.session === session else { return }
            projects = projects.map { $0.id == updated.id ? updated : $0 }
            if activeProject?.id == updated.id { activeProject = updated }
        } catch {
            projectError = error.localizedDescription
        }
    }

    func deleteActiveProject() async {
        guard let session, canUseProjects, let project = activeProject else { return }
        projectError = nil
        do {
            try await HarnessProjects.delete(session.account, id: project.id)
            guard self.session === session else { return }
            projects.removeAll { $0.id == project.id }
            if activeProject?.id == project.id { exitProject() }
            session.list.reload()
        } catch {
            projectError = error.localizedDescription
        }
    }

    func deleteAllProjects() async throws {
        guard let session, canUseProjects else { return }
        try await HarnessProjects.deleteAll(session.account)
        guard self.session === session else { return }
        projects = []
        if activeProject != nil { exitProject() }
        session.list.reload()
    }

    /// Converts and stores each picked file as a document of the active
    /// project. The chat service reads documents' text and describes
    /// images; the files themselves are not stored.
    func uploadProjectDocuments(handles: [ManagedStagedFile], pickerFailures: [ManagedFileError] = []) async {
        guard let session, canUseProjects, let project = activeProject else {
            handles.forEach { $0.discard() }
            return
        }
        isUploadingProjectDocument = true
        projectError = nil
        defer { if self.session === session { isUploadingProjectDocument = false } }
        let result = await ManagedFileBatchProcessor.process(files: handles) { handle in
            let data = try Data(contentsOf: handle.url)
            let mimeType = handle.contentTypeIdentifier.flatMap { UTType($0)?.preferredMIMEType } ?? HarnessUploads.mimeType(for: handle.fileName)
            let document = try await HarnessProjects.uploadDocument(session.account, projectId: project.id, file: data, fileName: handle.fileName, mimeType: mimeType)
            return ProjectDocument(document)
        }
        guard self.session === session, activeProject?.id == project.id else { return }
        for document in result.successes where !projectDocuments.contains(where: { $0.id == document.id }) {
            projectDocuments.append(document)
        }
        projectError = ManagedFileBatchErrorMessage.projectUpload(successCount: result.successes.count, failures: pickerFailures + result.failures)
    }

    func deleteProjectDocument(_ documentId: String) async {
        guard let session, canUseProjects, let project = activeProject else { return }
        projectError = nil
        do {
            try await HarnessProjects.deleteDocument(session.account, projectId: project.id, documentId: documentId)
            guard self.session === session, activeProject?.id == project.id else { return }
            projectDocuments.removeAll { $0.id == documentId }
        } catch {
            projectError = error.localizedDescription
        }
    }

    func moveChatToProject(chatId: String, projectId: String) async {
        await updateChatProject(chatId: chatId, projectId: projectId)
    }

    func removeChatFromProject(chatId: String) async {
        await updateChatProject(chatId: chatId, projectId: nil)
    }

    /// A chat on this device moves to the cloud first, as a project's chats
    /// are stored; when the move into the project fails, it returns to the
    /// device as it was.
    private func updateChatProject(chatId: String, projectId: String?) async {
        guard let session, canUseProjects else { return }
        var original: DeviceChatCopy?
        do {
            if session.list.isOnDevice(chatId) {
                guard projectId != nil else { return }
                original = try await session.moveToCloud(chatId)
            }
            _ = try await session.update(chatId, ThreadPatch(projectId: Nullable(projectId)))
            if session.open.id == chatId {
                session.setProject(projectId)
                if let projectId, activeProject?.id != projectId {
                    _ = await loadActiveProject(projectId: projectId)
                    isViewingProjectChat = true
                } else if projectId == nil, activeProject != nil {
                    leaveProjectContext()
                }
            }
            session.list.reload()
        } catch {
            if let original {
                do {
                    try await session.moveToDevice(chatId, original: original)
                } catch {
                    Self.logger.error("Failed to return a chat to this device after it failed to join a project: \(error, privacy: .public)")
                }
            }
            reportActionFailure("Couldn't Move Chat", error)
        }
    }
}
