//
//  MemoryView.swift
//  TinfoilChat
//
//  Created on 19/07/25.
//  Copyright © 2025 Tinfoil. All rights reserved.
//

import SwiftUI

struct MemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSaveConfirmation = false
    
    // Local state for form fields
    @State private var localNickname = ""
    @State private var localProfession = ""
    @State private var localTraits: [String] = []
    @State private var localAdditionalContext = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom header
            panelHeader
            
            // Content
            NavigationView {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Help Tin personalize your conversations")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 8)
                            
                            personalizationContent
                        }
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }
                .navigationBarHidden(true)
                .listStyle(InsetGroupedListStyle())
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { _ in
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                )
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        .background(Color(UIColor.systemGroupedBackground))
        .accentColor(Color.accentPrimary)
        .overlay(
            saveConfirmationOverlay,
            alignment: .top
        )
        .onAppear {
            localNickname = settings.nickname
            localProfession = settings.profession
            localTraits = settings.selectedTraits
            localAdditionalContext = settings.additionalContext
        }
    }
    
    // Personalization content view
    private var personalizationContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("What should Tin call you?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Nickname", text: $localNickname)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: localNickname) { _, newValue in
                        settings.nickname = newValue
                    }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("What's your occupation?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Profession", text: $localProfession)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: localProfession) { _, newValue in
                        settings.profession = newValue
                    }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Conversational traits")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TraitSelectionView(
                    availableTraits: settings.availableTraits,
                    selectedTraits: $localTraits
                )
                .onChange(of: localTraits) { _, newValue in
                    settings.selectedTraits = newValue
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Additional context")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Anything else Tin should know about you?", text: $localAdditionalContext, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(3...6)
                    .onChange(of: localAdditionalContext) { _, newValue in
                        settings.additionalContext = newValue
                    }
            }
            
            VStack(spacing: 0) {
                // Non-interactive spacer
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 16)
                
                // Button container with explicit boundaries
                HStack(spacing: 16) {
                    // Reset button
                    Button(action: {
                        settings.resetPersonalization()
                        localNickname = ""
                        localProfession = ""
                        localTraits = []
                        localAdditionalContext = ""
                    }) {
                        Text("Reset")
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    
                    // Save button
                    Button(action: {
                        // Dismiss keyboard first
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        
                        // Always enable personalization when saving
                        settings.isPersonalizationEnabled = true
                        
                        // Show confirmation after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showSaveConfirmation = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                showSaveConfirmation = false
                            }
                        }
                    }) {
                        Text("Save")
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentPrimary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .background(Color.clear)
                .contentShape(Rectangle())
            }
        }
    }
    
    // Save confirmation overlay
    private var saveConfirmationOverlay: some View {
        Group {
            if showSaveConfirmation {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Memory saved")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                )
                .padding(.top, 80)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showSaveConfirmation)
            }
        }
    }
    
    // Panel header matching the style from VerifierViewController
    private var panelHeader: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Text("Memory")
                    .font(.title)
                    .fontWeight(.bold)
            }
            Spacer()
            
            // Dismiss button with X icon
            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(.systemGray))
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Close memory screen")
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .overlay(
            Divider()
                .opacity(0.2)
            , alignment: .bottom
        )
    }
}