//
//  ImageWidget.swift
//  TinfoilChat
//
//  Unified image widget. A single item renders as a large standalone
//  image with optional caption; multiple items render as a responsive
//  grid. Mirrors the webapp's `render_image` widget. Tapping any image
//  opens an in-app full-screen viewer (paging + pinch-to-zoom) unless
//  the model supplied a `link`, in which case the link wins.

import OpenAI
import SwiftUI

struct ImageWidget: GenUIWidget {
    struct Item: Decodable {
        let url: String
        let alt: String?
        let caption: String?
        let link: String?
    }

    struct Args: Decodable {
        let images: [Item]
        let title: String?
        let aspectRatio: String?
    }

    let name = "render_image"
    let description = "Display one or more images. Pass a single item for a large standalone image; pass multiple items to render a responsive grid (galleries, comparisons, multi-visual references)."
    let promptHint = "one or more images — pass a single item for a large standalone image, or multiple items for a responsive grid"

    var schema: JSONSchema {
        let item = GenUISchema.object(
            properties: [
                "url": GenUISchema.string(description: "Image URL"),
                "alt": GenUISchema.string(description: "Accessible alt text"),
                "caption": GenUISchema.string(),
                "link": GenUISchema.string(description: "Optional destination when tapped"),
            ],
            required: ["url"]
        )
        return GenUISchema.object(
            properties: [
                "images": GenUISchema.array(
                    items: item,
                    description: "One or more images. A single image renders large with an optional caption; multiple images render in a responsive grid.",
                    minItems: 1
                ),
                "title": GenUISchema.string(),
                "aspectRatio": GenUISchema.string(
                    description: "Single-image only. Container shape: square (1:1), video (16:9), or auto. Ignored when multiple images are provided.",
                    enumValues: ["square", "video", "auto"]
                ),
            ],
            required: ["images"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        if args.images.count == 1, let only = args.images.first {
            return AnyView(SingleImageView(
                images: args.images,
                image: only,
                aspectRatio: args.aspectRatio,
                isDarkMode: context.isDarkMode
            ))
        }
        return AnyView(ImageGridView(
            images: args.images,
            title: args.title,
            isDarkMode: context.isDarkMode
        ))
    }
}

private struct SingleImageView: View {
    let images: [ImageWidget.Item]
    let image: ImageWidget.Item
    let aspectRatio: String?
    let isDarkMode: Bool

    @State private var previewIndex: Int = 0
    @State private var isPreviewPresented: Bool = false

    private var ratio: CGFloat? {
        switch aspectRatio {
        case "square": return 1.0
        case "video": return 16.0 / 9.0
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let ratio {
                    GenUIRemoteImage(url: image.url, isDarkMode: isDarkMode, contentMode: .fill)
                        .aspectRatio(ratio, contentMode: .fit)
                } else {
                    GenUIRemoteImage(url: image.url, isDarkMode: isDarkMode, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(accessibilityText(for: image))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(image.link?.isEmpty == false ? "Opens link" : "Opens full screen")
            .onTapGesture { handleTap() }
            .accessibilityAction { handleTap() }

            if let caption = image.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
        }
        .fullScreenCover(isPresented: $isPreviewPresented) {
            ImagePreviewView(
                images: images,
                startIndex: $previewIndex,
                isPresented: $isPreviewPresented
            )
        }
    }

    private func handleTap() {
        if let link = image.link, !link.isEmpty {
            GenUIURLOpener.open(link)
            return
        }
        previewIndex = 0
        isPreviewPresented = true
    }
}

private struct ImageGridView: View {
    let images: [ImageWidget.Item]
    let title: String?
    let isDarkMode: Bool

    @State private var previewIndex: Int = 0
    @State private var isPreviewPresented: Bool = false

    private enum Layout {
        static let columnCount = 2
        static let columnSpacing: CGFloat = 8
        static let rowSpacing: CGFloat = 8
        static let captionSpacing: CGFloat = 4
        static let fallbackHorizontalInset: CGFloat = 32
    }

    @State private var availableWidth: CGFloat = max(
        0,
        UIScreen.main.bounds.width - Layout.fallbackHorizontalInset
    )

    private var measuredWidth: some View {
        Color.clear
            .frame(height: 0)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ImageGridWidthPreferenceKey.self, value: proxy.size.width)
                }
            )
    }

    private var rowCount: Int {
        (images.count + Layout.columnCount - 1) / Layout.columnCount
    }

    private var cellWidth: CGFloat {
        let totalSpacing = CGFloat(Layout.columnCount - 1) * Layout.columnSpacing
        return max(0, floor((availableWidth - totalSpacing) / CGFloat(Layout.columnCount)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }

            measuredWidth

            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                ForEach(0..<rowCount, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: Layout.columnSpacing) {
                        ForEach(0..<Layout.columnCount, id: \.self) { columnIndex in
                            let imageIndex = rowIndex * Layout.columnCount + columnIndex
                            if imageIndex < images.count {
                                gridCell(index: imageIndex, image: images[imageIndex])
                                    .frame(width: cellWidth, alignment: .leading)
                            } else {
                                Spacer(minLength: 0)
                                    .frame(width: cellWidth)
                            }
                        }
                    }
                    .frame(width: availableWidth, alignment: .leading)
                }
            }
            .frame(width: availableWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ImageGridWidthPreferenceKey.self) { width in
            if width > 0 {
                availableWidth = width
            }
        }
        .fullScreenCover(isPresented: $isPreviewPresented) {
            ImagePreviewView(
                images: images,
                startIndex: $previewIndex,
                isPresented: $isPreviewPresented
            )
        }
    }

    private func gridCell(index: Int, image: ImageWidget.Item) -> some View {
        VStack(alignment: .leading, spacing: Layout.captionSpacing) {
            GenUIRemoteImage(url: image.url, isDarkMode: isDarkMode, contentMode: .fill)
                .frame(width: cellWidth, height: cellWidth)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius)
                        .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel(accessibilityText(for: image))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(image.link?.isEmpty == false ? "Opens link" : "Opens full screen")
                .onTapGesture { handleTap(index: index, image: image) }
                .accessibilityAction { handleTap(index: index, image: image) }

            if let caption = image.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(width: cellWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: cellWidth, alignment: .leading)
        .clipped()
    }

    private func handleTap(index: Int, image: ImageWidget.Item) {
        if let link = image.link, !link.isEmpty {
            GenUIURLOpener.open(link)
            return
        }
        previewIndex = index
        isPreviewPresented = true
    }
}

private func accessibilityText(for image: ImageWidget.Item) -> String {
    if let alt = image.alt, !alt.isEmpty { return alt }
    if let caption = image.caption, !caption.isEmpty { return caption }
    return "Image"
}

private struct ImageGridWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
