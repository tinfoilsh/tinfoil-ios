//
//  MessageAttachmentIndicator.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

struct MessageAttachmentIndicator: View {
    let attachments: [Attachment]
    let isDarkMode: Bool
    @EnvironmentObject private var viewModel: TinfoilChat.ChatViewModel
    @State private var showImageViewer = false
    @State private var initialImageIndex: Int = 0

    private var allConversationImages: [Attachment] {
        (viewModel.currentChat?.messages ?? [])
            .flatMap { $0.attachments }
            .filter { $0.type == .image && $0.imageBase64 != nil }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(attachments) { attachment in
                AttachmentChip(attachment: attachment, isDarkMode: isDarkMode)
                    .onTapGesture {
                        if attachment.type == .image && attachment.imageBase64 != nil {
                            let images = allConversationImages
                            if let index = images.firstIndex(where: { $0.id == attachment.id }) {
                                initialImageIndex = index
                                showImageViewer = true
                            }
                        }
                    }
            }
        }
        .padding(.bottom, 4)
        .fullScreenCover(isPresented: $showImageViewer) {
            ImageViewerOverlay(
                images: allConversationImages,
                initialIndex: initialImageIndex
            )
        }
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 6) {
            if attachment.type == .image, let base64 = attachment.thumbnailBase64,
               let data = Data(base64Encoded: base64),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))
            }

            Text(attachment.fileName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isDarkMode ? .white.opacity(0.8) : .black.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        )
    }

    private var iconName: String {
        let ext = (attachment.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "html": return "globe"
        case "csv": return "tablecells"
        case "md": return "text.document"
        default: return "doc.text"
        }
    }
}

private struct ImageViewerOverlay: View {
    let images: [Attachment]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, attachment in
                    ZoomableImagePage(attachment: attachment)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            // Close button + counter
            VStack {
                HStack {
                    if images.count > 1 {
                        Text("\(currentIndex + 1) / \(images.count)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding()

                Spacer()

                // Left/right arrow buttons
                if images.count > 1 {
                    HStack {
                        Button {
                            withAnimation {
                                currentIndex = max(0, currentIndex - 1)
                            }
                        } label: {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(currentIndex > 0 ? 0.7 : 0.2))
                        }
                        .disabled(currentIndex == 0)

                        Spacer()

                        Button {
                            withAnimation {
                                currentIndex = min(images.count - 1, currentIndex + 1)
                            }
                        } label: {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(currentIndex < images.count - 1 ? 0.7 : 0.2))
                        }
                        .disabled(currentIndex == images.count - 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            currentIndex = initialIndex
        }
    }
}

private struct ZoomableImagePage: View {
    let attachment: Attachment
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        if let base64 = attachment.imageBase64,
           let data = Data(base64Encoded: base64),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = lastScale * value.magnification
                        }
                        .onEnded { _ in
                            lastScale = max(1.0, scale)
                            scale = lastScale
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = 1.0
                        lastScale = 1.0
                    }
                }
        }
    }
}
