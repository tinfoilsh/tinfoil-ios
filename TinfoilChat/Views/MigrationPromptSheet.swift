//
//  MigrationPromptSheet.swift
//  TinfoilChat
//

import SwiftUI
import UIKit

struct MigrationPromptSheet: View {
    var onDelete: () -> Void
    var onSync: () -> Void
    
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 24, weight: .semibold))
                Text("Cloud Sync Available")
                    .font(.headline)
            }

            Text("We found chats stored locally from an older version. You can delete them or sync them to your account so they’re available across devices.")
                .font(.subheadline)

            VStack(spacing: 12) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete Local Chats")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    onSync()
                } label: {
                    HStack {
                        Spacer()
                        Text("Sync My Chats")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tinfoilAccentLight)
            }
        }
        .padding(20)
        // Measure content height to fit the sheet to its content
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            // Add vertical padding (20 top + 20 bottom)
            contentHeight = height + 40
        }
        // Fit the sheet height to content (with a reasonable max)
        .presentationDetents([
            .height(min(UIScreen.main.bounds.height * 0.9, max(200, contentHeight)))
        ])
        .presentationDragIndicator(.visible)
        .ignoresSafeArea(.keyboard)
        .onAppear {
            // Dismiss any active keyboard when presenting the migration sheet
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

// Preference key to propagate measured content height
private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
