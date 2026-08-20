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

        let request = try #require(function.range(of: "try await projectStorage.deleteAllProjects(requestProgress: requestProgress)"))
        let clearProjects = try #require(function.range(of: "projects = []"))
        #expect(request.lowerBound < clearProjects.lowerBound)
        #expect(function.contains("projectListLoadGeneration += 1"))
        #expect(function.contains("projectLoadGeneration += 1"))
        #expect(function.contains("projectDocuments = []"))
        #expect(function.contains("activeStorageTab = .cloud"))
        #expect(function.contains("createNewChat(isLocalOnly: false"))
    }

    @Test("Bulk project deletion distinguishes cancellation around dispatch")
    func bulkProjectDeletionDistinguishesCancellationAroundDispatch() throws {
        let viewModelSource = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let settingsSource = try sourceFile("TinfoilChat/Views/SettingsView.swift")
        let deletion = try functionBody(named: "func deleteAllProjects()", in: viewModelSource)
        let confirmation = try functionBody(named: "private func confirmBulkDelete", in: settingsSource)

        let cancellation = try #require(deletion.range(of: "await cancelAndAwaitProjectUploads()"))
        let request = try #require(deletion.range(of: "try await projectStorage.deleteAllProjects(requestProgress: requestProgress)"))
        let beforeRequest = deletion[cancellation.upperBound..<request.lowerBound]
        #expect(beforeRequest.contains("throw CancellationError()"))
        #expect(deletion.contains("guard await requestProgress.requestStarted else { throw CancellationError() }"))
        #expect(deletion.contains("return .accountChanged"))
        #expect(deletion.contains("return .refreshRequired"))
        #expect(deletion.contains("currentUserId == accountUserId"))
        #expect(confirmation.contains("catch is CancellationError"))
        #expect(confirmation.contains("Deletion may have completed. Refresh to confirm."))
        #expect(confirmation.contains("case .accountChanged:"))
    }

    @Test("Bulk chat deletion uses the same request outcome distinction")
    func bulkChatDeletionDistinguishesCancellationAroundDispatch() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let deletion = try functionBody(named: "func deleteAllChats()", in: source)

        #expect(deletion.contains("guard let userId = currentUserId else { throw CancellationError() }"))
        #expect(deletion.contains("requestProgress: requestProgress"))
        #expect(deletion.contains("guard await requestProgress.requestStarted else { throw CancellationError() }"))
        #expect(deletion.contains("return .accountChanged"))
        #expect(deletion.contains("return .refreshRequired"))
        let cloudGuard = try #require(deletion.range(of: "guard shouldDeleteCloud else { return }", options: .backwards))
        let cancellation = try #require(deletion.range(of: "try Task.checkCancellation()", range: cloudGuard.upperBound..<deletion.endIndex))
        #expect(cloudGuard.lowerBound < cancellation.lowerBound)
    }

    @Test("Document picker captures account state before staging")
    func documentPickerCapturesAccountStateBeforeStaging() throws {
        let source = try sourceFile("TinfoilChat/Views/DocumentPickerView.swift")
        let callback = try functionBody(named: "func documentPicker(", in: source)
        let staging = try functionBody(named: "func stageDocument(at sourceURL", in: source)

        let capture = try #require(callback.range(of: "let accountLifecycleGeneration = accountLifecycleGeneration()"))
        let task = try #require(callback.range(of: "Task {"))
        #expect(capture.lowerBound < task.lowerBound)
        #expect(callback.contains("accountLifecycleGeneration: accountLifecycleGeneration"))
        #expect(!staging.contains("accountLifecycleGeneration()"))
    }

    @Test("Account teardown retry preserves failure until cleanup succeeds")
    func accountTeardownRetryPreservesFailureUntilCleanupSucceeds() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/AuthManager.swift")
        let retry = try functionBody(named: "func retryAccountTeardown()", in: source)

        let cleanup = try #require(retry.range(of: "await clearAuthState(for: trigger) else {"))
        let revenueCat = try #require(retry.range(of: "await RevenueCatManager.shared.logoutUser()"))
        let clerk = try #require(retry.range(
            of: "await initializeAuthState()",
            range: revenueCat.upperBound..<retry.endIndex
        ))
        #expect(cleanup.lowerBound < revenueCat.lowerBound)
        #expect(revenueCat.lowerBound < clerk.lowerBound)
    }

    @Test("Account teardown drains passive auth loss before destruction")
    func accountTeardownDrainsPassiveAuthLoss() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/AuthManager.swift")
        let teardown = try functionBody(named: "private func clearAuthState(for trigger:", in: source)

        let drain = try #require(teardown.range(of: "await passiveAuthLossTask.task.value"))
        let destruction = try #require(teardown.range(of: "try await self.performAccountTeardown"))
        #expect(drain.lowerBound < destruction.lowerBound)
    }

    @Test("Failed deletion restores only a live matching Clerk owner")
    func failedDeletionRequiresLiveOwner() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/AuthManager.swift")
        let restore = try functionBody(
            named: "private func restoreAccountDataAccessAfterFailedDeletion(",
            in: source
        )

        #expect(restore.contains("clerk?.user?.id == userId"))
        #expect(restore.contains("localUserId == userId"))
    }

    @Test("Attachment removal and sign-out cancel processing")
    func attachmentRemovalAndSignOutCancelProcessing() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let removal = try functionBody(named: "func removePendingAttachment", in: source)
        let clearing = try functionBody(named: "func clearPendingAttachments", in: source)
        let signOut = try functionBody(named: "func handleSignOut(ownerUserId:", in: source)

        #expect(removal.contains("attachmentProcessingTasks[id]"))
        #expect(removal.contains("task.cancel()"))
        #expect(clearing.contains("attachmentProcessingGeneration += 1"))
        #expect(clearing.contains("for task in tasks { task.cancel() }"))
        #expect(signOut.contains("try await destroyAttachmentDrafts()"))
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

    @Test("Photo loading validates the presentation account before publishing")
    func photoLoadingValidatesPresentationAccount() throws {
        let source = try sourceFile("TinfoilChat/Views/MessageInputView.swift")
        let presentation = try functionBody(named: "private func presentPhotoPicker()", in: source)
        let function = try functionBody(named: "private func processSelectedPhotos()", in: source)

        let capture = try #require(presentation.range(of: "photoPickerAccountGeneration = viewModel.accountLifecycleGeneration"))
        let present = try #require(presentation.range(of: "viewModel.showPhotoPicker = true"))
        let useCapture = try #require(function.range(of: "let accountGeneration = photoPickerAccountGeneration"))
        let load = try #require(function.range(of: "await item.loadTransferable(type: Data.self)"))
        let validation = try #require(function.range(of: "viewModel.isCurrentAccountLifecycle(accountGeneration)"))
        let publish = try #require(function.range(of: "viewModel.addImageAttachment"))
        #expect(capture.lowerBound < present.lowerBound)
        #expect(useCapture.lowerBound < load.lowerBound)
        #expect(load.lowerBound < validation.lowerBound)
        #expect(validation.lowerBound < publish.lowerBound)
        #expect(!function.contains("viewModel.accountLifecycleGeneration"))
    }

    @Test("Project document staging preserves its upload destination")
    func projectDocumentStagingPreservesDestination() throws {
        let pageSource = try sourceFile("TinfoilChat/Views/ProjectPage.swift")
        let viewModelSource = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let upload = try functionBody(named: "func uploadProjectDocument", in: viewModelSource)

        #expect(pageSource.contains("uploadDestination = viewModel.projectDocumentUploadDestination"))
        #expect(pageSource.contains("destination: uploadDestination"))
        #expect(upload.contains("isCurrentProjectAccount(destination.accountGeneration)"))
        #expect(upload.contains("activeProject?.id == destination.projectId"))
        #expect(upload.contains("let projectId = destination.projectId"))
        #expect(upload.contains("file.discard()"))
    }

    @Test("Share imports prefer file representations over in-memory data")
    func shareImportsPreferFileRepresentations() throws {
        let source = try sourceFile("TinfoilShareExtension/ShareViewController.swift")
        let addToTinfoil = try functionBody(named: "private func addToTinfoil()", in: source)

        let fileLoad = try #require(addToTinfoil.range(of: "provider.loadFileRepresentation"))
        let fallback = try #require(addToTinfoil.range(of: "loadDataFallback("))
        #expect(fileLoad.lowerBound < fallback.lowerBound)
    }

    @Test("Root selection is revalidated after project upload cancellation")
    func rootSelectionIsRevalidatedAfterProjectUploadCancellation() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let leaveProject = try functionBody(named: "func leaveProjectContext", in: source)
        let openSearchResult = try functionBody(named: "func openSearchResult", in: source)

        let cancellation = try #require(leaveProject.range(of: "await cancelAndAwaitProjectUploads()"))
        let validation = try #require(leaveProject.range(of: "guard validateOperation()"))
        #expect(cancellation.lowerBound < validation.lowerBound)
        #expect(openSearchResult.contains("leaveProjectContext(validateOperation:"))
        #expect(openSearchResult.contains("self.currentUserId == userId"))
        #expect(openSearchResult.contains("self.chatSelectionFence.accepts("))
    }

    @Test("Document cancellation waits for extraction before discard")
    func documentCancellationWaitsForExtractionBeforeDiscard() throws {
        let processingSource = try sourceFile("TinfoilChat/Services/DocumentProcessingService.swift")
        let viewModelSource = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let extraction = try functionBody(named: "func extractText(from url", in: processingSource)
        let attachment = try functionBody(named: "func startDocumentProcessing", in: viewModelSource)

        #expect(extraction.contains("withTaskCancellationHandler"))
        #expect(extraction.contains("extractionTask.cancel()"))
        #expect(extraction.contains("try await extractionTask.value"))
        #expect(extraction.contains("return try self.extractTextFromPDF(at: url)"))
        #expect(extraction.contains("return try self.readPlainText(at: url)"))
        let extractionCall = try #require(attachment.range(of: "extractText(from: file.url)"))
        let deferredCleanup = try #require(attachment.range(of: "defer {"))
        let cleanup = attachment[deferredCleanup.lowerBound..<extractionCall.lowerBound]
        #expect(cleanup.contains("file.discard()"))
        #expect(attachment.contains("processingGeneration == attachmentProcessingGeneration"))
    }

    @Test("Async attachment and upload tasks use token-aware registration")
    func asyncTasksUseTokenAwareRegistration() throws {
        let source = try sourceFile("TinfoilChat/ViewModels/ChatViewModel.swift")
        let projectUpload = try functionBody(named: "func uploadProjectDocument", in: source)
        let documentAttachment = try functionBody(named: "func startDocumentProcessing", in: source)
        let imageAttachment = try functionBody(named: "func addImageAttachment", in: source)

        assertTokenRegistration(
            in: projectUpload,
            registration: "projectUploadTokens[operationID] = operationToken",
            taskCreation: "let task = Task",
            pendingCheck: "if projectUploadTokens[operationID] == operationToken",
            taskStorage: "projectUploadTasks[operationID] = task"
        )
        for attachment in [documentAttachment, imageAttachment] {
            assertTokenRegistration(
                in: attachment,
                registration: "attachmentProcessingTokens[attachmentId] = operationToken",
                taskCreation: "let task = Task",
                pendingCheck: "if attachmentProcessingTokens[attachmentId] == operationToken",
                taskStorage: "attachmentProcessingTasks[attachmentId] = task"
            )
        }
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

    private func assertTokenRegistration(
        in function: Substring,
        registration: String,
        taskCreation: String,
        pendingCheck: String,
        taskStorage: String
    ) {
        guard let registrationRange = function.range(of: registration),
              let creationRange = function.range(of: taskCreation),
              let pendingRange = function.range(of: pendingCheck, options: .backwards),
              let storageRange = function.range(of: taskStorage, options: .backwards) else {
            Issue.record("Expected token-aware task registration")
            return
        }
        #expect(registrationRange.lowerBound < creationRange.lowerBound)
        #expect(creationRange.lowerBound < pendingRange.lowerBound)
        #expect(pendingRange.lowerBound < storageRange.lowerBound)
    }
}

private enum SourceTestError: Error {
    case functionNotFound
}
