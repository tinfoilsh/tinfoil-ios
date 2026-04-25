//
//  ImageGridWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct ImageGridWidget: GenUIWidget {
    struct Item: Decodable {
        let url: String
        let alt: String?
        let caption: String?
        let link: String?
    }

    struct Args: Decodable {
        let images: [Item]
        let title: String?
    }

    let name = "render_image_grid"
    let description = "Display multiple images arranged in a responsive grid. Use for galleries, comparisons, or when multiple visuals support a single topic."
    let promptHint = "multiple images as a responsive grid"

    var schema: JSONSchema {
        let item = GenUISchema.object(
            properties: [
                "url": GenUISchema.string(),
                "alt": GenUISchema.string(),
                "caption": GenUISchema.string(),
                "link": GenUISchema.string(),
            ],
            required: ["url"]
        )
        return GenUISchema.object(
            properties: [
                "images": GenUISchema.array(
                    items: item,
                    description: "One or more images to arrange in a grid",
                    minItems: 1
                ),
                "title": GenUISchema.string(),
            ],
            required: ["images"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(ImageGridView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct ImageGridView: View {
    let args: ImageGridWidget.Args
    let isDarkMode: Bool

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = args.title, !title.isEmpty {
                GenUITitle(text: title, isDarkMode: isDarkMode)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(args.images.enumerated()), id: \.offset) { _, image in
                    VStack(alignment: .leading, spacing: 4) {
                        GenUIRemoteImage(url: image.url, isDarkMode: isDarkMode, contentMode: .fill)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius)
                                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                            )
                            .onTapGesture {
                                if let link = image.link { GenUIURLOpener.open(link) }
                            }

                        if let caption = image.caption, !caption.isEmpty {
                            Text(caption)
                                .font(.caption2)
                                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}
