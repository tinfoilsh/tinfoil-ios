//
//  ConnectorTogglesView.swift
//  TinfoilChat
//

import SwiftUI

private enum ConnectorTogglesLayout {
    static let rowSpacing: CGFloat = 10
    static let titleSpacing: CGFloat = 2
}

/// How many of the account's connectors the open chat's replies can call,
/// as the composer's sheet shows it on the row that opens them.
struct ConnectorsRowValue: View {
    @ObservedObject var store: ConnectorStore
    /// Whether the open chat's replies can call connectors.
    let available: Bool

    var body: some View {
        let count = available ? store.callable.count : 0
        Text(count == 0 ? "None" : "\(count) on")
            .foregroundColor(.secondary)
            .lineLimit(1)
    }
}

/// The account's connectors in the composer's sheet, where each one that is
/// signed in is turned on or off for chats.
struct ConnectorTogglesView: View {
    @ObservedObject var store: ConnectorStore
    /// Whether the open chat's replies can call connectors.
    let available: Bool
    let isDarkMode: Bool

    /// The connectors whose change is being saved.
    @State private var updating: Set<String> = []
    @State private var updateError: String?

    private var rowBackground: Color {
        Color.cardSurface(for: isDarkMode ? .dark : .light)
    }

    var body: some View {
        List {
            if !available {
                Section {
                    Text(Constants.Connectors.unavailableOnDevice)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .listRowBackground(rowBackground)
            }

            Section {
                if !store.connectors.isEmpty {
                    ForEach(store.connectors) { connector in
                        row(connector)
                    }
                } else if !store.listed && store.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let error = store.errorMessage {
                    Text(error)
                        .foregroundColor(.secondary)
                } else {
                    Text("Connect apps in Settings to use them here.")
                        .foregroundColor(.secondary)
                }
            } footer: {
                if let updateError {
                    Text(updateError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .listRowBackground(rowBackground)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.sheetBackground(isDarkMode: isDarkMode))
        .navigationTitle(Constants.Connectors.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
    }

    @ViewBuilder
    private func row(_ connector: Connector) -> some View {
        if connector.connected {
            Toggle(isOn: Binding(
                get: { connector.enabled },
                set: { setEnabled(connector.id, $0) }
            )) {
                HStack(spacing: ConnectorTogglesLayout.rowSpacing) {
                    FaviconView(url: connector.url, isDarkMode: isDarkMode)
                        .accessibilityHidden(true)
                    Text(connector.name)
                        .lineLimit(1)
                }
            }
            .tint(.green)
            .disabled(!available || updating.contains(connector.id))
        } else {
            HStack(spacing: ConnectorTogglesLayout.rowSpacing) {
                FaviconView(url: connector.url, isDarkMode: isDarkMode)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ConnectorTogglesLayout.titleSpacing) {
                    Text(connector.name)
                        .lineLimit(1)
                    Text("Sign in needed in Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Turns a connector on or off for chats, one change of it at a time.
    private func setEnabled(_ id: String, _ enabled: Bool) {
        guard !updating.contains(id) else { return }
        updating.insert(id)
        updateError = nil
        Task {
            do {
                try await store.update(id, enabled: enabled)
            } catch {
                if !(error is CancellationError) {
                    updateError = ConnectorStore.describe(error)
                }
            }
            updating.remove(id)
        }
    }
}
