//
//  ArtifactsListView.swift
//  TinfoilChat
//
//  The artifacts the replies in a project's chats drew, or in every stored
//  chat, each opening in the sheet its card in the chat opens.
//

import SwiftUI
import TinfoilIcons

struct ArtifactsListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel
    /// The project whose chats' artifacts are listed, or nil for those of
    /// every stored chat.
    let projectId: String?

    @StateObject private var list = ArtifactListController()
    @State private var openingArtifact: ArtifactKey?
    @State private var shownArtifact: ShownArtifact?
    @State private var openFailure: String?

    private struct ShownArtifact: Identifiable {
        let id: ArtifactKey
        let args: ArtifactPreviewWidget.Args
    }

    private static let unknownKindTitle = "Artifact"
    private static let unreadableMessage = "This artifact could not be read."

    /// The artifacts of the chats the account can open: a project's chats
    /// need a subscription, as they do in the chat list.
    private var shownArtifacts: [ListedArtifact] {
        list.artifacts.filter {
            PremiumProjectPolicy.includesChat(projectId: $0.projectId, hasPremiumAccess: viewModel.hasPremiumAccess)
        }
    }

    var body: some View {
        Form {
            if list.artifacts.isEmpty, list.isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            } else if shownArtifacts.isEmpty, let error = list.error {
                Section {
                    failureRow(error)
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            } else if shownArtifacts.isEmpty, !list.hasMore {
                Section {
                    Text(projectId == nil
                         ? "No artifacts yet. Artifacts created in your cloud chats are listed here."
                         : "No artifacts yet. Artifacts created in this project's chats are listed here.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            } else {
                Section {
                    ForEach(shownArtifacts, id: \.key) { artifact in
                        artifactRow(artifact)
                    }

                    if let error = list.error {
                        failureRow(error)
                    } else if list.hasMore {
                        // The row loads the next page as it shows, and again
                        // while it still shows after a page was listed.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task(id: list.artifacts.count) {
                                guard let loading = list.loadMore() else { return }
                                await loading.value
                            }
                    }
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: viewModel.account.map(ObjectIdentifier.init)) {
            await list.load(account: viewModel.account, projectId: projectId).value
        }
        .onDisappear {
            list.reset()
        }
        .refreshable {
            await list.load(account: viewModel.account, projectId: projectId).value
        }
        .sheet(item: $shownArtifact) { shown in
            ArtifactDetailSheet(args: shown.args, isDarkMode: colorScheme == .dark)
                .environmentObject(viewModel)
        }
        .alert("Artifact Error", isPresented: Binding(
            get: { openFailure != nil },
            set: { if !$0 { openFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openFailure ?? "An error occurred")
        }
    }

    private func artifactRow(_ artifact: ListedArtifact) -> some View {
        Button {
            open(artifact)
        } label: {
            HStack(spacing: 10) {
                Image(tinfoil: Self.icon(of: artifact.kind))
                    .foregroundColor(.secondary)
                    .frame(width: Constants.FilePreview.projectRowSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(of: artifact))
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(Self.kindName(of: artifact.kind)) · \(artifact.threadTitle.isEmpty ? Chat.defaultTitle : artifact.threadTitle)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let date = ChatAccessCache.date(of: artifact.createdAt) {
                        Text(date, format: .dateTime.month(.abbreviated).day().year())
                            .font(.caption)
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                }
                Spacer()
                if openingArtifact == artifact.key {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(tinfoil: .chevronRight)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .disabled(openingArtifact != nil)
        .accessibilityHint("Opens the artifact")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                openChat(of: artifact)
            } label: {
                Label("Open Chat", tinfoil: .chat)
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                openChat(of: artifact)
            } label: {
                Label("Open Chat", tinfoil: .chat)
            }
        }
    }

    private func failureRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Could not load artifacts.")
                .font(.subheadline)
                .fontWeight(.medium)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                list.retry()
            }
            .font(.subheadline)
        }
    }

    /// What an artifact is called: its title, or what its kind is called
    /// when its call gave none.
    private static func title(of artifact: ListedArtifact) -> String {
        artifact.title.isEmpty ? (artifact.kind?.label ?? unknownKindTitle) : artifact.title
    }

    private static func kindName(of kind: ArtifactPreviewWidget.SourceKind?) -> String {
        switch kind {
        case .url: return "Link"
        case .html: return "HTML"
        case .markdown: return "Markdown"
        case nil: return unknownKindTitle
        }
    }

    private static func icon(of kind: ArtifactPreviewWidget.SourceKind?) -> TinfoilIcon {
        switch kind {
        case .url: return .globe
        case .html: return .code
        case .markdown, nil: return .document
        }
    }

    /// Reads an artifact's source and shows it as its card in the chat
    /// does.
    private func open(_ artifact: ListedArtifact) {
        guard openingArtifact == nil, let account = viewModel.account else { return }
        guard artifact.kind != nil else { openChat(of: artifact); return }
        openingArtifact = artifact.key
        Task {
            defer { openingArtifact = nil }
            do {
                let opened = try await HarnessArtifacts.get(account, artifact)
                guard viewModel.account === account, !account.disposed else { return }
                let args = try JSONDecoder().decode(ArtifactPreviewWidget.Args.self, from: Data(opened.arguments.utf8))
                shownArtifact = ShownArtifact(id: artifact.key, args: args)
            } catch is CancellationError {
            } catch is DecodingError {
                if viewModel.account === account { openFailure = Self.unreadableMessage }
            } catch {
                if viewModel.account === account { openFailure = error.localizedDescription }
            }
        }
    }

    private func openChat(of artifact: ListedArtifact) {
        viewModel.openSummaryChat(id: artifact.threadId, projectId: artifact.projectId, isLocalOnly: false)
        viewModel.requestNavigation(to: .chat)
        dismiss()
    }
}
