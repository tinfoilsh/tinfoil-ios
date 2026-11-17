//
//  ConnectorsSettingsView.swift
//  TinfoilChat
//

import SwiftUI
import TinfoilIcons

private enum ConnectorsSettingsLayout {
    static let rowSpacing: CGFloat = 12
    static let titleSpacing: CGFloat = 2
    static let errorSpacing: CGFloat = 12
    /// The most listed servers a search shows, which keeps the list light.
    static let maxSearchResults = 100
}

/// The account's connectors, and the servers it can connect.
struct ConnectorsSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ConnectorStore
    @ObservedObject var viewModel: TinfoilChat.ChatViewModel

    @State private var catalog: [ConnectorCatalogEntry] = []
    @State private var searchText = ""
    @State private var connectingId: String?
    @State private var actionError: String?
    @State private var showCustomConnector = false

    /// The listed servers shown: the first of them, or those a search finds.
    private var shownCatalog: [ConnectorCatalogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return Array(catalog.prefix(Constants.Connectors.catalogPreview))
        }
        let found = catalog.filter { $0.matches(query) }
        return Array(found.prefix(ConnectorsSettingsLayout.maxSearchResults))
    }

    var body: some View {
        List {
            if viewModel.account?.cloud != true {
                notice("Connectors work in chats saved to the cloud. Turn on Cloud Sync to use them.")
            } else if viewModel.account?.keyLocked == true {
                notice("Unlock your encryption key in Cloud Sync to manage connectors.")
            } else if viewModel.account?.keyReady != true {
                // The account's key is still loading, and its connectors
                // with it.
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))
            } else {
                connectorsSection
                catalogSection
                customSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .refreshable { await store.refresh() }
        .navigationTitle(Constants.Connectors.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if catalog.isEmpty {
                catalog = (try? ConnectorCatalog.load()) ?? []
            }
            await store.refresh()
        }
        .alert("Couldn't Connect", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(actionError ?? "")
        }
        .sheet(isPresented: $showCustomConnector) {
            CustomConnectorSheet(store: store)
        }
    }

    private func notice(_ text: String) -> some View {
        Section {
            Text(text)
                .foregroundColor(.secondary)
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var connectorsSection: some View {
        Section {
            if !store.listed && store.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: ConnectorsSettingsLayout.errorSpacing) {
                    Text(error)
                    Button("Try Again") {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isLoading)
                }
            }
            ForEach(store.connectors) { connector in
                NavigationLink {
                    ConnectorDetailView(store: store, connectorId: connector.id)
                } label: {
                    connectorRow(connector)
                }
            }
            if store.listed && store.errorMessage == nil && store.connectors.isEmpty {
                Text("No connectors yet.")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Your Connectors")
        } footer: {
            Text("Connectors let replies use tools from the apps you connect. What they sign in with stays inside the secure enclave.")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private func connectorRow(_ connector: Connector) -> some View {
        let status = connector.connected ? "Connected" : "Sign in needed"
        return HStack(spacing: ConnectorsSettingsLayout.rowSpacing) {
            FaviconView(url: connector.url, isDarkMode: colorScheme == .dark)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ConnectorsSettingsLayout.titleSpacing) {
                Text(connector.name)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(status) · \(connector.host)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !connector.enabled {
                Text("Off")
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var catalogSection: some View {
        let shown = shownCatalog
        return Section {
            HStack(spacing: ConnectorsSettingsLayout.rowSpacing) {
                Image(tinfoil: .magnifyingGlass)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                TextField("Search", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            ForEach(shown) { entry in
                catalogRow(entry)
            }
            if shown.isEmpty && !catalog.isEmpty {
                Text("No matching connectors.")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Add a Connector")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private func catalogRow(_ entry: ConnectorCatalogEntry) -> some View {
        let added = store.connectors.contains { $0.url == entry.url }
        return HStack(spacing: ConnectorsSettingsLayout.rowSpacing) {
            VStack(alignment: .leading, spacing: ConnectorsSettingsLayout.titleSpacing) {
                Text(entry.name)
                    .font(.body)
                    .foregroundColor(.primary)
                if let subtitle = detail(of: entry) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if added {
                Text("Added")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if connectingId == entry.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting \(entry.name)")
            } else {
                Button("Connect") {
                    connect(entry)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(connectingId != nil || !store.usable)
                .accessibilityLabel("Connect \(entry.name)")
            }
        }
    }

    /// What tells a listed server from the others of its name: who makes
    /// it, or else what it is for.
    private func detail(of entry: ConnectorCatalogEntry) -> String? {
        if !entry.vendor.isEmpty, entry.vendor != entry.name {
            return entry.vendor
        }
        return entry.categories.first
    }

    private var customSection: some View {
        Section {
            Button {
                showCustomConnector = true
            } label: {
                Label("Add Custom Connector", tinfoil: .plus)
                    .foregroundColor(.primary)
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    /// Connects a listed server, one at a time, under its name cut to the
    /// longest the chat service takes.
    private func connect(_ entry: ConnectorCatalogEntry) {
        guard connectingId == nil else { return }
        connectingId = entry.id
        let name = String(entry.name.prefix(Constants.Connectors.maxNameLength))
        Task {
            do {
                try await store.add(name: name, url: entry.url)
            } catch {
                if !(error is CancellationError) {
                    actionError = ConnectorStore.describe(error)
                }
            }
            connectingId = nil
        }
    }
}

/// The form that connects a server the app does not list, by its address.
private struct CustomConnectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ConnectorStore

    @State private var name = ""
    @State private var address = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTooLong: Bool {
        trimmedName.count > Constants.Connectors.maxNameLength
    }

    private var canAdd: Bool {
        !isAdding
            && store.usable
            && !trimmedName.isEmpty
            && !trimmedAddress.isEmpty
            && !nameIsTooLong
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .disabled(isAdding)
                    TextField("MCP server URL (HTTPS)", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isAdding)
                } footer: {
                    if nameIsTooLong {
                        Text("Use a name of \(Constants.Connectors.maxNameLength) characters or fewer.")
                    }
                }
                .listRowBackground(Color.cardSurface(for: colorScheme))

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .listRowBackground(Color.cardSurface(for: colorScheme))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.settingsBackground(for: colorScheme))
            .navigationTitle("Custom Connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isAdding)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: ConnectorsSettingsLayout.rowSpacing) {
                        if isAdding {
                            ProgressView()
                        }
                        Button("Add") {
                            add()
                        }
                        .fontWeight(.semibold)
                        .disabled(!canAdd)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isAdding)
    }

    private func add() {
        guard canAdd else { return }
        let connectorName = trimmedName
        let url = trimmedAddress
        isAdding = true
        errorMessage = nil
        Task {
            do {
                try await store.add(name: connectorName, url: url)
                isAdding = false
                dismiss()
            } catch {
                isAdding = false
                if !(error is CancellationError) {
                    errorMessage = ConnectorStore.describe(error)
                }
            }
        }
    }
}
