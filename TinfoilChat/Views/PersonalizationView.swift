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
                .accessibilityAddTraits(selectedTraits.contains(trait) ? .isSelected : [])
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
    @ObservedObject private var profileManager = ProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSaving: Bool = false
    @State private var isPersonalizationEnabled = ProfileDefaults.isUsingPersonalization
    @State private var nickname = ProfileDefaults.nickname
    @State private var profession = ProfileDefaults.profession
    @State private var traits = ProfileDefaults.traits
    @State private var additionalContext = ProfileDefaults.additionalContext

    private let availableTraits = SettingsManager.shared.availableTraits
    
    var body: some View {
        List {
            enableSection
            nicknameSection
            professionSection
            traitsSection
            additionalContextSection
            clearSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsBackground(for: colorScheme))
        .navigationTitle("Personalization")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    isSaving = true
                    profileManager.isUsingPersonalization = isPersonalizationEnabled
                    profileManager.nickname = nickname
                    profileManager.profession = profession
                    profileManager.traits = traits
                    profileManager.additionalContext = additionalContext
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
            isPersonalizationEnabled = profileManager.isUsingPersonalization
            nickname = profileManager.nickname
            profession = profileManager.profession
            traits = profileManager.traits
            additionalContext = profileManager.additionalContext
        }
    }

    private var enableSection: some View {
        Section {
            Toggle("Personalize responses", isOn: $isPersonalizationEnabled)
                .tint(Color.accentPrimary)
        } footer: {
            Text("Use these details to tailor responses. Turning this off keeps your details saved.")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }
    
    private var nicknameSection: some View {
        Section {
            TextField("Nickname", text: $nickname)
        } header: {
            Text("What should Tin call you?")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var professionSection: some View {
        Section {
            TextField("Profession", text: $profession)
        } header: {
            Text("What's your occupation?")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var traitsSection: some View {
        Section {
            TraitSelectionView(
                availableTraits: availableTraits,
                selectedTraits: $traits
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } header: {
            Text("Conversational traits")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var additionalContextSection: some View {
        Section {
            TextField("Anything else Tin should know about you?", text: $additionalContext, axis: .vertical)
                .lineLimit(3...6)
        } header: {
            Text("Additional context")
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                nickname = ""
                profession = ""
                traits = []
                additionalContext = ""
            } label: {
                HStack {
                    Text("Clear details")
                    Spacer()
                }
            }
        }
        .listRowBackground(Color.cardSurface(for: colorScheme))
    }
}
