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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Help Tin personalize your conversations")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                    
                    personalizationContent
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            }
            .background(colorScheme == .dark ? Color.backgroundPrimary : Color.white)
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
        .background(colorScheme == .dark ? Color.backgroundPrimary : Color(UIColor.systemGroupedBackground))
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
        VStack(spacing: 24) {
            // Nickname section
            VStack(alignment: .leading, spacing: 12) {
                Text("What should Tin call you?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Nickname", text: $localNickname)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colorScheme == .dark ? Color(UIColor.systemGray5) : Color(UIColor.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .onChange(of: localNickname) { _, newValue in
                        settings.nickname = newValue
                    }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(hex: "1C1C1E") : Color(UIColor.systemGray6))
            )
            
            // Profession section
            VStack(alignment: .leading, spacing: 12) {
                Text("What's your occupation?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Profession", text: $localProfession)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colorScheme == .dark ? Color(UIColor.systemGray5) : Color(UIColor.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .onChange(of: localProfession) { _, newValue in
                        settings.profession = newValue
                    }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(hex: "1C1C1E") : Color(UIColor.systemGray6))
            )
            
            // Traits section
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(hex: "1C1C1E") : Color(UIColor.systemGray6))
            )
            
            // Additional context section
            VStack(alignment: .leading, spacing: 12) {
                Text("Additional context")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                TextField("Anything else Tin should know about you?", text: $localAdditionalContext, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colorScheme == .dark ? Color(UIColor.systemGray5) : Color(UIColor.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .lineLimit(3...6)
                    .onChange(of: localAdditionalContext) { _, newValue in
                        settings.additionalContext = newValue
                    }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(hex: "1C1C1E") : Color(UIColor.systemGray6))
            )
            
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