import Foundation
import Testing

@Suite("Data Lifecycle Source Tests")
struct DataLifecycleSourceTests {
    @Test("Both recovery flows confirm before starting fresh")
    func recoveryFlowsConfirmBeforeStartingFresh() throws {
        let onboarding = try sourceFile("TinfoilChat/Views/CloudSyncOnboardingView.swift")
        let passkey = try sourceFile("TinfoilChat/Views/PasskeyRecoveryChoiceView.swift")

        for source in [onboarding, passkey] {
            #expect(source.contains("You will lose your conversations"))
            #expect(source.contains("role: .destructive"))
            #expect(source.contains("Yes, start fresh"))
        }
    }

    @Test("Bulk project deletion uses the atomic endpoint")
    func bulkProjectDeletionUsesAtomicEndpoint() throws {
        let source = try sourceFile("TinfoilChat/Services/SyncEnclave/SyncEnclaveAPI.swift")

        #expect(source.contains("/v1/sync/delete-all-projects"))
        #expect(source.contains("EnclaveDeleteAllProjectsRequest"))
        #expect(source.contains("EnclaveDeleteAllProjectsResponse"))
    }

    @Test("Bulk deletion resets project state after the request")
    func bulkDeletionResetsProjectStateAfterRequest() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let function = try functionBody(named: "func deleteAllProjects()", in: source)

        let request = try #require(function.range(of: "try await projectStorage.deleteAllProjects()"))
        let clearProjects = try #require(function.range(of: "projects = []"))
        #expect(request.lowerBound < clearProjects.lowerBound)
        #expect(function.contains("projectListLoadGeneration += 1"))
        #expect(function.contains("projectLoadGeneration += 1"))
        #expect(function.contains("projectDocuments = []"))
        #expect(function.contains("activeStorageTab = .cloud"))
        #expect(function.contains("createNewChat(isLocalOnly: false"))
    }

    @Test("Attachment removal and sign-out cancel processing")
    func attachmentRemovalAndSignOutCancelProcessing() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let removal = try functionBody(named: "func removePendingAttachment", in: source)
        let clearing = try functionBody(named: "func clearPendingAttachments", in: source)
        let signOut = try functionBody(named: "func handleSignOut()", in: source)

        #expect(removal.contains("attachmentProcessingTasks[id]"))
        #expect(removal.contains("task.cancel()"))
        #expect(clearing.contains("attachmentProcessingGeneration += 1"))
        #expect(clearing.contains("for task in tasks { task.cancel() }"))
        #expect(signOut.contains("clearPendingAttachments()"))
        #expect(signOut.contains("discardMessageQueue(chatId: chatId)"))
        #expect(signOut.contains("SharedImportCoordinator.shared.discardAllPending()"))
        #expect(signOut.contains("await task.value"))
    }

    @Test("Project uploads are canceled before context changes")
    func projectUploadsAreCanceledBeforeContextChanges() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let bulkDelete = try functionBody(named: "func deleteAllProjects()", in: source)
        let singleDelete = try functionBody(named: "func deleteActiveProject()", in: source)
        let leaveProject = try functionBody(named: "func leaveProjectContext()", in: source)
        let upload = try functionBody(named: "func uploadProjectDocument", in: source)

        #expect(bulkDelete.contains("await cancelAndAwaitProjectUploads()"))
        #expect(singleDelete.contains("await cancelAndAwaitProjectUploads()"))
        #expect(leaveProject.contains("await cancelAndAwaitProjectUploads()"))
        #expect(upload.contains("projectUploadBarrierCount == 0"))
        #expect(upload.contains("activeProject?.id == projectId"))
        #expect(upload.contains("isCurrentProjectAccount(accountGeneration)"))
        #expect(upload.contains("file.discard()"))
    }

    @Test("Document cancellation waits for extraction before discard")
    func documentCancellationWaitsForExtractionBeforeDiscard() throws {
        let processingSource = try sourceFile("TinfoilChat/Services/DocumentProcessingService.swift")
        let viewModelSource = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let extraction = try functionBody(named: "func extractText(from url", in: processingSource)
        let attachment = try functionBody(named: "func addDocumentAttachment", in: viewModelSource)

        #expect(extraction.contains("withTaskCancellationHandler"))
        #expect(extraction.contains("extractionTask.cancel()"))
        #expect(extraction.contains("try await extractionTask.value"))
        let extractionCall = try #require(attachment.range(of: "extractText(from: file.url)"))
        let deferredCleanup = try #require(attachment.range(of: "defer {"))
        let cleanup = attachment[deferredCleanup.lowerBound..<extractionCall.lowerBound]
        #expect(cleanup.contains("file.discard()"))
        #expect(attachment.contains("processingGeneration == attachmentProcessingGeneration"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func functionBody(named signature: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: signature)?.lowerBound)
        var depth = 0
        var foundOpeningBrace = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                foundOpeningBrace = true
                depth += 1
            } else if character == "}" && foundOpeningBrace {
                depth -= 1
                if depth == 0 {
                    return source[start...index]
                }
            }
            index = source.index(after: index)
        }
        throw SourceTestError.functionNotFound
    }
}

private enum SourceTestError: Error {
    case functionNotFound
}
