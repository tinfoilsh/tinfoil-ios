//
//  ConnectorDetailView.swift
//  TinfoilChat
//

import SwiftUI

private enum ConnectorDetailLayout {
    static let rowSpacing: CGFloat = 12
    static let titleSpacing: CGFloat = 2
    static let summaryLineLimit = 3
    static let tagHorizontalPadding: CGFloat = 6
    static let tagVerticalPadding: CGFloat = 2
    static let tagFillOpacity = 0.12
}

/// One of the account's connectors: whether chats use it, its sign-in, and
/// what each of its tools may do.
struct ConnectorDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ConnectorStore
    let connectorId: String

    /// A change the user asks the chat service for.
    private enum Action: Equatable {
        case enable
        case signIn
        case permit(tool: String)
        case refreshTools
        case remove
    }

    /// The change being made, during which no other starts.
    @State private var busy: Action?
    @State private var actionError: String?
    @State private var confirmsRemoval = false

    private var connector: Connector? {
        store.connectors.first { $0.id == connectorId }
    }

    var body: some View {
        Group {
            if let connector {
                content(connector)
            } else {
                Color.settingsBackground(for: colorScheme)
                    .ignoresSafeArea()
            }
        }
        .onChange(of: connector == nil, initial: true) { _, gone in
            if gone { dismiss() }
        }
        .alert("Couldn't Update Connector", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func content(_ connector: Connector) -> some View {
        List {
            statusSection(connector)
            toolsSection(connector)
            actionsSection(connector)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle(connector.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(connector.name)?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                run(.remove) { try await store.remove(connectorId) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Chats will no longer use its tools. What it signs in with is deleted.")
        }
    }

    private func statusSection(_ connector: Connector) -> some View {
        Section {
            HStack {
                Toggle("Use in chats", isOn: Binding(
                    get: { connector.enabled },
                    set: { enabled in
                        run(.enable) { try await store.update(connectorId, enabled: enabled) }
                    }
                ))
                .tint(Color.accentPrimary)
                .disabled(busy != nil)
                if isBusy(.enable) {
                    ProgressView()
                }
            }

            HStack {
                Text("Status")
                Spacer()
                Text(connector.connected ? "Connected" : "Sign in needed")
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)

            if !connector.connected {
                actionButton("Sign In", .signIn) {
                    try await store.signIn(connectorId)
                }
            } else if connector.signIn {
                actionButton("Sign In Again", .signIn) {
                    try await store.signIn(connectorId)
                }
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private func toolsSection(_ connector: Connector) -> some View {
        Section {
            if connector.tools.isEmpty {
                Text(connector.connected
                     ? "This server offers no tools."
                     : "Sign in to see the tools this server offers.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(connector.tools) { tool in
                    toolRow(tool)
                }
            }
        } header: {
            Text("Tools")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private func toolRow(_ tool: ConnectorTool) -> some View {
        HStack(spacing: ConnectorDetailLayout.rowSpacing) {
            VStack(alignment: .leading, spacing: ConnectorDetailLayout.titleSpacing) {
                Text(tool.displayName)
                    .font(.body)
                if let summary = tool.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(ConnectorDetailLayout.summaryLineLimit)
                }
                if tool.readOnly {
                    Text("Read-only")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, ConnectorDetailLayout.tagHorizontalPadding)
                        .padding(.vertical, ConnectorDetailLayout.tagVerticalPadding)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(ConnectorDetailLayout.tagFillOpacity))
                        )
                }
            }
            Spacer(minLength: 0)
            if isBusy(.permit(tool: tool.name)) {
                ProgressView()
                    .controlSize(.small)
            }
            Picker("Permission for \(tool.displayName)", selection: Binding(
                get: { tool.permission },
                set: { permission in
                    guard permission != tool.permission else { return }
                    run(.permit(tool: tool.name)) {
                        try await store.update(connectorId, tools: [tool.name: permission])
                    }
                }
            )) {
                ForEach(ConnectorToolPermission.allCases) { permission in
                    Text(permission.label).tag(permission)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(busy != nil)
            .accessibilityLabel("Permission for \(tool.displayName)")
        }
    }

    private func actionsSection(_ connector: Connector) -> some View {
        Section {
            actionButton("Refresh Tools", .refreshTools, isEnabled: connector.connected) {
                try await store.refreshTools(connectorId)
            }

            Button(role: .destructive) {
                confirmsRemoval = true
            } label: {
                HStack {
                    Text("Remove Connector")
                    Spacer()
                    if isBusy(.remove) {
                        ProgressView()
                    }
                }
            }
            .disabled(busy != nil)
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    /// A row that asks for a change, with a spinner while it is made.
    private func actionButton(
        _ title: String,
        _ action: Action,
        isEnabled: Bool = true,
        change: @escaping () async throws -> Void
    ) -> some View {
        Button {
            run(action, change)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if isBusy(action) {
                    ProgressView()
                }
            }
        }
        .disabled(busy != nil || !isEnabled)
    }

    private func isBusy(_ action: Action) -> Bool {
        busy == action
    }

    /// Asks the chat service for one change at a time, and tells the user
    /// why one failed.
    private func run(_ action: Action, _ change: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = action
        Task {
            do {
                try await change()
            } catch {
                if !(error is CancellationError) {
                    actionError = ConnectorStore.describe(error)
                }
            }
            busy = nil
        }
    }
}
