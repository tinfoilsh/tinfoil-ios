//
//  MessageAttachmentIndicator.swift
//  TinfoilChat
//
//  Copyright © 2025 Tinfoil. All rights reserved.

import SwiftUI

private enum Base64ImageDecoder {
    static let cache = NSCache<NSString, UIImage>()

    static func cachedImage(for cacheKey: String) -> UIImage? {
        cache.object(forKey: cacheKey as NSString)
    }

    static func decode(base64: String, cacheKey: String) async -> UIImage? {
        if let cached = cachedImage(for: cacheKey) {
            return cached
        }

        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = Data(base64Encoded: base64) else { return nil }
            return UIImage(data: data)
        }.value

        if let image {
            cache.setObject(image, forKey: cacheKey as NSString)
        }

        return image
    }
}

struct DecodedBase64ImageView<Placeholder: View>: View {
    let base64: String?
    let cacheKey: String
    let contentMode: ContentMode
    let placeholder: Placeholder

    @State private var image: UIImage?

    init(
        base64: String?,
        cacheKey: String,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.base64 = base64
        self.cacheKey = cacheKey
        self.contentMode = contentMode
        self.placeholder = placeholder()
        _image = State(initialValue: Base64ImageDecoder.cachedImage(for: cacheKey))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) {
            guard let base64 else {
                image = nil
                return
            }

            if let cached = Base64ImageDecoder.cachedImage(for: cacheKey) {
                image = cached
                return
            }

            guard !Task.isCancelled else { return }
            image = await Base64ImageDecoder.decode(base64: base64, cacheKey: cacheKey)
        }
    }
}

struct MessageAttachmentIndicator: View {
    let attachments: [Attachment]
    let isDarkMode: Bool
    @EnvironmentObject private var viewModel: TinfoilChat.ChatViewModel

    private var imageAttachments: [Attachment] {
        attachments.filter { $0.type == .image }
    }

    private var documentAttachments: [Attachment] {
        attachments.filter { $0.type == .document }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !imageAttachments.isEmpty {
                imageGrid
            }

            ForEach(documentAttachments) { attachment in
                AttachmentChip(attachment: attachment, isDarkMode: isDarkMode)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var imageGrid: some View {
        let size = Constants.Attachments.messageThumbnailSize
        let columns = Constants.Attachments.messageThumbnailColumns
        let rows = imageAttachments.chunked(into: columns)
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { attachment in
                        ImageThumbnail(attachment: attachment, size: size)
                            .onTapGesture {
                                let allImages = (viewModel.currentChat?.messages ?? [])
                                    .flatMap { $0.attachments }
                                    .filter { $0.type == .image && $0.base64 != nil }
                                if let index = allImages.firstIndex(where: { $0.id == attachment.id }) {
                                    viewModel.imageViewerImages = allImages
                                    viewModel.imageViewerIndex = index
                                    viewModel.showImageViewer = true
                                }
                            }
                    }
                }
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(isDarkMode ? .white.opacity(0.7) : .black.opacity(0.6))

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

private struct ImageThumbnail: View {
    let attachment: Attachment
    let size: CGFloat

    private var thumbnailBase64: String? {
        attachment.thumbnailBase64 ?? attachment.base64
    }

    private var cacheKey: String {
        "attachment-thumbnail-\(attachment.id)-\(thumbnailBase64?.hashValue ?? 0)"
    }

    var body: some View {
        DecodedBase64ImageView(base64: thumbnailBase64, cacheKey: cacheKey) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ImageViewerOverlay: View {
    let images: [Attachment]
    let initialIndex: Int
    let onDismiss: () -> Void
    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingVertically = false

    init(images: [Attachment], initialIndex: Int, onDismiss: @escaping () -> Void) {
        self.images = images
        self.initialIndex = initialIndex
        self.onDismiss = onDismiss
        _currentIndex = State(initialValue: initialIndex)
    }

    private var backgroundOpacity: Double {
        1.0 - min(abs(dragOffset) / 300.0, 0.5)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity).ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, attachment in
                    ZoomableImagePage(attachment: attachment)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if !isDraggingVertically {
                            isDraggingVertically = abs(value.translation.height) > abs(value.translation.width)
                        }
                        if isDraggingVertically {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if isDraggingVertically && abs(value.translation.height) > 100 {
                            onDismiss()
                        } else {
                            withAnimation(.interactiveSpring()) {
                                dragOffset = 0
                            }
                        }
                        isDraggingVertically = false
                    }
            )

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
                        onDismiss()
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
        .persistentSystemOverlays(.hidden)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct ZoomableImagePage: View {
    let attachment: Attachment
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var decodedImage: UIImage?

    private var fullSizeBase64: String? {
        attachment.base64 ?? attachment.thumbnailBase64
    }

    private var cacheKey: String {
        "attachment-full-\(attachment.id)-\(fullSizeBase64?.hashValue ?? 0)"
    }

    var body: some View {
        Group {
            if let decodedImage {
                Image(uiImage: decodedImage)
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
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Unable to load image")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }
            }
        }
        .task(id: cacheKey) {
            guard let fullSizeBase64 else {
                decodedImage = nil
                return
            }

            if let cached = Base64ImageDecoder.cachedImage(for: cacheKey) {
                decodedImage = cached
                return
            }

            guard !Task.isCancelled else { return }
            decodedImage = await Base64ImageDecoder.decode(base64: fullSizeBase64, cacheKey: cacheKey)
        }
    }
}
