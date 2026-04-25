//
//  ImageWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct ImageWidget: GenUIWidget {
    struct Args: Decodable {
        let url: String
        let alt: String?
        let caption: String?
        let link: String?
        let aspectRatio: String?
    }

    let name = "render_image"
    let description = "Display a single image with optional caption. Use for diagrams, logos, photos, or any single visual reference."
    let promptHint = "a single image with optional caption"

    var schema: JSONSchema {
        GenUISchema.object(
            properties: [
                "url": GenUISchema.string(description: "Image URL"),
                "alt": GenUISchema.string(description: "Accessible alt text"),
                "caption": GenUISchema.string(),
                "link": GenUISchema.string(description: "Optional destination when tapped"),
                "aspectRatio": GenUISchema.string(
                    description: "Container shape: square (1:1), video (16:9), or auto",
                    enumValues: ["square", "video", "auto"]
                ),
            ],
            required: ["url"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(ImageWidgetView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct ImageWidgetView: View {
    let args: ImageWidget.Args
    let isDarkMode: Bool

    private var ratio: CGFloat? {
        switch args.aspectRatio {
        case "square": return 1.0
        case "video": return 16.0 / 9.0
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let ratio {
                    GenUIRemoteImage(url: args.url, isDarkMode: isDarkMode, contentMode: .fill)
                        .aspectRatio(ratio, contentMode: .fit)
                } else {
                    GenUIRemoteImage(url: args.url, isDarkMode: isDarkMode, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
            )
            .onTapGesture {
                if let link = args.link {
                    GenUIURLOpener.open(link)
                }
            }

            if let caption = args.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            }
        }
    }
}
