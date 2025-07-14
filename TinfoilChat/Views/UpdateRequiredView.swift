//
//  UpdateRequiredView.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

import SwiftUI

/// View displayed when the app version is below the minimum supported version
struct UpdateRequiredView: View {
    @Environment(\.colorScheme) var colorScheme
    
    private let appStoreURL = "https://apps.apple.com/app/tinfoil/id6745201750"
    
    var body: some View {
        ZStack {
            // Background
            (colorScheme == .dark ? Color(hex: "111827") : Color.white)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                Spacer()
                
                // Logo
                Image(colorScheme == .dark ? "logo-white" : "logo-dark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 60)
                
                VStack(spacing: 24) {
                    // Title
                    Text("Update Required")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                    
                    // Description
                    Text("A new version of Tinfoil is required to continue. Please update to the latest version from the App Store.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    // Version info
                    VStack(spacing: 8) {
                        Text("Current Version: \(AppConfig.shared.currentAppVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Required Version: \(AppConfig.shared.minSupportedVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Update button
                Button(action: openAppStore) {
                    Text("Update Now")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentPrimary)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                
                Spacer()
            }
        }
    }
    
    private func openAppStore() {
        if let url = URL(string: appStoreURL) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    UpdateRequiredView()
}