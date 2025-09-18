//
//  PersonalizationView.swift
//  TinfoilChat
//
//  Created on 19/07/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI
import UIKit

// Trait selection view for personality traits
struct TraitSelectionView: View {
    let availableTraits: [String]
    @Binding var selectedTraits: [String]
    
    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(availableTraits, id: \.self) { trait in
                Button(action: {
                    toggleTrait(trait)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: selectedTraits.contains(trait) ? "checkmark" : "plus")
                            .font(.subheadline)
                        Text(trait)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(selectedTraits.contains(trait) ? Color.accentPrimary : Color.gray.opacity(0.2))
                    )
                    .foregroundColor(selectedTraits.contains(trait) ? .white : .primary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func toggleTrait(_ trait: String) {
        if selectedTraits.contains(trait) {
            selectedTraits.removeAll { $0 == trait }
        } else {
            selectedTraits.append(trait)
        }
    }
}

// Custom FlowLayout for flexible tag arrangement
struct FlowLayout: Layout {
    let spacing: CGFloat
    
    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.bounds
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            let position = CGPoint(
                x: bounds.minX + result.positions[index].x,
                y: bounds.minY + result.positions[index].y
            )
            subview.place(at: position, proposal: ProposedViewSize(result.sizes[index]))
        }
    }
}

struct FlowResult {
    let bounds: CGSize
    let positions: [CGPoint]
    let sizes: [CGSize]
    
    init(in maxWidth: CGFloat, subviews: LayoutSubviews, spacing: CGFloat) {
        var sizes: [CGSize] = []
        var positions: [CGPoint] = []
        
        var currentRowY: CGFloat = 0
        var currentRowX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentRowX + size.width > maxWidth && currentRowX > 0 {
                currentRowY += currentRowHeight + spacing
                currentRowX = 0
                currentRowHeight = 0
            }
            
            positions.append(CGPoint(x: currentRowX, y: currentRowY))
            sizes.append(size)
            
            currentRowX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        
        self.positions = positions
        self.sizes = sizes
        self.bounds = CGSize(
            width: maxWidth,
            height: currentRowY + currentRowHeight
        )
    }
}

struct PersonalizationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSaving: Bool = false
    
    var body: some View {
        List {
            nicknameSection
            professionSection
            traitsSection
            additionalContextSection
            resetSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Personalization")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    // Align flags and push to cloud
                    isSaving = true
                    let shouldEnable = !profileManager.nickname.isEmpty || !profileManager.profession.isEmpty || !profileManager.traits.isEmpty || !profileManager.additionalContext.isEmpty
                    profileManager.isUsingPersonalization = shouldEnable
                    settings.isPersonalizationEnabled = shouldEnable
                    Task { @MainActor in
                        await profileManager.syncToCloud()
                        isSaving = false
                        dismiss()
                    }
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .simultaneousGesture(
            DragGesture()
                .onChanged { _ in
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
        )
        .toolbarBackground(Color(UIColor.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
        .task {
            await profileManager.syncFromCloud()
        }
    }
    
    private var nicknameSection: some View {
        Section {
            TextField("Nickname", text: $profileManager.nickname)
                .onChange(of: profileManager.nickname) { _, newValue in
                    let shouldEnable = !newValue.isEmpty || !profileManager.profession.isEmpty || !profileManager.traits.isEmpty || !profileManager.additionalContext.isEmpty
                    profileManager.isUsingPersonalization = shouldEnable
                    settings.nickname = newValue
                    settings.isPersonalizationEnabled = shouldEnable
                }
        } header: {
            Text("What should Tin call you?")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var professionSection: some View {
        Section {
            TextField("Profession", text: $profileManager.profession)
                .onChange(of: profileManager.profession) { _, newValue in
                    let shouldEnable = !profileManager.nickname.isEmpty || !newValue.isEmpty || !profileManager.traits.isEmpty || !profileManager.additionalContext.isEmpty
                    profileManager.isUsingPersonalization = shouldEnable
                    settings.profession = newValue
                    settings.isPersonalizationEnabled = shouldEnable
                }
        } header: {
            Text("What's your occupation?")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var traitsSection: some View {
        Section {
            TraitSelectionView(
                availableTraits: settings.availableTraits,
                selectedTraits: $profileManager.traits
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .onChange(of: profileManager.traits) { _, newValue in
                let shouldEnable = !profileManager.nickname.isEmpty || !profileManager.profession.isEmpty || !newValue.isEmpty || !profileManager.additionalContext.isEmpty
                profileManager.isUsingPersonalization = shouldEnable
                settings.selectedTraits = newValue
                settings.isPersonalizationEnabled = shouldEnable
            }
        } header: {
            Text("Conversational traits")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var additionalContextSection: some View {
        Section {
            TextField("Anything else Tin should know about you?", text: $profileManager.additionalContext, axis: .vertical)
                .lineLimit(3...6)
                .onChange(of: profileManager.additionalContext) { _, newValue in
                    let shouldEnable = !profileManager.nickname.isEmpty || !profileManager.profession.isEmpty || !profileManager.traits.isEmpty || !newValue.isEmpty
                    profileManager.isUsingPersonalization = shouldEnable
                    settings.additionalContext = newValue
                    settings.isPersonalizationEnabled = shouldEnable
                }
        } header: {
            Text("Additional context")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                profileManager.nickname = ""
                profileManager.profession = ""
                profileManager.traits = []
                profileManager.additionalContext = ""
                profileManager.isUsingPersonalization = false

                settings.resetPersonalization()

                Task {
                    await profileManager.syncToCloud()
                }
            } label: {
                HStack {
                    Text("Reset All")
                    Spacer()
                }
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }
}
