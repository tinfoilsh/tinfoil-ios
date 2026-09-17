import SwiftUI

struct SafeguardsSettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: SafeguardsStore
    let onOpenChat: () -> Void

    private var signedInUserId: String? {
        authManager.isAuthenticated ? authManager.localUserId : nil
    }

    private var canShowFlags: Bool {
        signedInUserId != nil && store.userId == signedInUserId
    }

    var body: some View {
        Group {
            if canShowFlags {
                List {
                    privacySection
                    #if DEBUG
                    Section {
                        Toggle("Show example flags", isOn: Binding(
                            get: { store.usesExamples },
                            set: { store.setUsesExamples($0) }
                        ))
                    } header: {
                        Text("Development")
                    } footer: {
                        Text("Example flags are sample data, not flags on your account. Turn this off to load your account's flags.")
                    }
                    .listRowBackground(Color.cardSurface(for: colorScheme))
                    #endif
                    flagsSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.settingsBackground(for: colorScheme))
                .refreshable { await store.refresh() }
            }
        }
        .navigationTitle("Safeguards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canShowFlags {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                    .accessibilityLabel("Refresh flagged chats")
                }
            }
        }
        .task(id: signedInUserId) {
            guard canShowFlags else { return }
            await store.refresh()
        }
        .onChange(of: signedInUserId) { _, userId in
            if userId == nil { dismiss() }
        }
        #if DEBUG
        .task(id: store.usesExamples) {
            guard canShowFlags else { return }
            await store.refresh()
        }
        #endif
    }

    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Constants.Safeguards.contentSpacing) {
                Label("Your conversations stay private.", systemImage: "lock.shield")
                    .font(.headline)
                Text("Automated safeguards check model responses in the context of the conversation—not user prompts for wrongdoing. These checks run entirely inside secure enclaves at inference time, applying our narrow hard-no policy on child endangerment, mass violence and terrorism, and encouraging self-harm.")
                Text("Only a flag linked to your account and the chat ID leaves the enclaves. Tinfoil cannot see the conversation or the flagged category, and there is no human review of your private chats. Your stored backups remain end-to-end encrypted. Safeguards do not scan stored chat data; checks happen only at inference time inside the enclaves.")
            }
            .font(.subheadline)
            Link(destination: Constants.Safeguards.infoURL) {
                Label("Learn how safeguards work", systemImage: "arrow.up.right.square")
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    @ViewBuilder
    private var flagsSection: some View {
        Section {
            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: Constants.Safeguards.contentSpacing) {
                    Text(error)
                    if store.report != nil {
                        Text("Showing the last loaded flags.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Try Again") {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isLoading)
                }
            }

            if let report = store.report {
                if report.inWindow == 0 {
                    Text("No flagged chats in the last \(report.windowDescription).")
                        .foregroundStyle(.secondary)
                }
                if !report.flags.isEmpty || report.inWindow > 0 {
                    suspensionProgress(report)
                    ForEach(report.flags) { flag in
                        flagRow(flag, report: report)
                    }
                }
                if store.isLoading {
                    ProgressView("Refreshing flagged chats…")
                }
            } else if store.errorMessage == nil {
                ProgressView("Loading flagged chats…")
            }
        } header: {
            Text(store.usesExamples ? "Example Flagged Chats" : "Flagged Chats")
        } footer: {
            if let report = store.report, !report.flags.isEmpty || report.inWindow > 0 {
                Text("These flags identify chats containing model responses flagged by safeguards. Repeated flags within the counting window can lead to automatic account suspension. Flags count for \(report.windowDescription); older flags no longer count toward suspension.")
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private func suspensionProgress(_ report: SafeguardFlagsReport) -> some View {
        VStack(alignment: .leading, spacing: Constants.Safeguards.contentSpacing) {
            Text("\(report.inWindow) of \(report.banThreshold) flags in the last \(report.windowDescription)")
                .font(.subheadline.weight(.medium))
            ProgressView(value: report.progress)
                .progressViewStyle(.linear)
                .tint(Color(hex: Constants.Safeguards.suspensionColorHex))
                .accessibilityLabel("Flags toward account suspension")
                .accessibilityValue("\(report.inWindow) of \(report.banThreshold)")
            Text(report.remaining == 0
                 ? "Suspension limit reached"
                 : "\(report.remaining) more before account suspension")
                .font(.caption)
                .foregroundStyle(report.inWindow >= report.warnThreshold ? Color.red : Color.secondary)
        }
    }

    private func flagRow(_ flag: SafeguardFlag, report: SafeguardFlagsReport) -> some View {
        let summary = localSummary(for: flag)
        let isInWindow = report.isInWindow(flag, now: Date())
        return Button {
            guard canShowFlags, !store.usesExamples else { return }
            if let summary {
                chatViewModel.openSummaryChat(
                    id: summary.id,
                    projectId: summary.projectId,
                    isLocalOnly: summary.isLocalOnly
                )
                chatViewModel.requestNavigation(to: .chat)
                onOpenChat()
            } else if let url = flag.chatURL {
                openURL(url)
            }
        } label: {
            HStack(spacing: Constants.Safeguards.contentSpacing) {
                Image(systemName: "flag.fill")
                    .foregroundStyle(isInWindow ? Color.red : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(store.usesExamples ? "Example chat" : (summary?.title ?? "Flagged chat"))
                        .foregroundStyle(isInWindow ? Color.primary : Color.secondary)
                        .lineLimit(2)
                    Text(flag.createdAt, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isInWindow {
                        Text("No longer counts toward suspension")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if flag.conversationId.isEmpty {
                        Text("Chat ID unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !store.usesExamples && flag.chatURL != nil {
                    Image(systemName: summary == nil ? "arrow.up.right.square" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(store.usesExamples || flag.chatURL == nil)
        .accessibilityHint(store.usesExamples || flag.chatURL == nil
                           ? ""
                           : (summary == nil ? "Opens the chat in the web app" : "Opens the conversation"))
    }

    private func localSummary(for flag: SafeguardFlag) -> ChatListSummary? {
        guard !store.usesExamples else { return nil }
        return (chatViewModel.localSidebarSummaries + chatViewModel.cloudSidebarSummaries)
            .first {
                $0.id == flag.conversationId
                    && !$0.decryptionFailed
                    && !$0.dataCorrupted
                    && ($0.isLocalOnly || !DeletedChatsTracker.shared.isDeleted($0.id))
                    && PremiumProjectPolicy.includesChat(
                        projectId: $0.projectId,
                        hasPremiumAccess: chatViewModel.hasPremiumAccess
                    )
            }
    }
}
