//
//  MessageComposeWidget.swift
//  TinfoilChat
//

import OpenAI
import SwiftUI

struct MessageComposeWidget: GenUIWidget {
    struct Variant: Decodable {
        let label: String
        let subject: String?
        let body: String
    }

    struct Args: Decodable {
        let channel: String?
        let to: String?
        let title: String?
        let variants: [Variant]
    }

    let name = "render_message_compose"
    let description = "Draft a message or email with one or more tone variants. Includes Copy and (for email) Open in Mail."
    let promptHint = "a draft message or email with optional tone variants and Copy / Open in Mail"

    var schema: JSONSchema {
        let variant = GenUISchema.object(
            properties: [
                "label": GenUISchema.string(description: "Short variant label, e.g. \"Formal\""),
                "subject": GenUISchema.string(),
                "body": GenUISchema.string(),
            ],
            required: ["label", "body"]
        )
        return GenUISchema.object(
            properties: [
                "channel": GenUISchema.string(enumValues: ["email", "message"]),
                "to": GenUISchema.string(description: "Recipient — used for mailto:"),
                "title": GenUISchema.string(),
                "variants": GenUISchema.array(items: variant, minItems: 1),
            ],
            required: ["variants"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(MessageComposeView(args: args, isDarkMode: context.isDarkMode))
    }
}

private struct MessageComposeView: View {
    let args: MessageComposeWidget.Args
    let isDarkMode: Bool

    @State private var selected: Int = 0
    @State private var copied: Bool = false

    private var isEmail: Bool {
        (args.channel ?? "email") == "email"
    }

    private var variant: MessageComposeWidget.Variant? {
        args.variants[safe: selected] ?? args.variants.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmail { emailHeader }
            if args.variants.count > 1 { variantTabs }
            if isEmail { emailHeaderFields }

            if let body = variant?.body {
                Text(body)
                    .font(.subheadline)
                    .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }

            if !isEmail {
                HStack {
                    Spacer()
                    copyButton
                }
                .padding([.horizontal, .bottom], 12)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                .fill(GenUIStyle.cardBackground(isDarkMode))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius))
    }

    @ViewBuilder
    private var emailHeader: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 10, height: 10)
            }
            Spacer()
            Text(args.title ?? "New Message")
                .font(.caption.weight(.medium))
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
            Spacer()
            copyButton
            if let variant {
                Button(action: { openMail(variant: variant) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.caption2)
                        Text("Open in mail").font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(GenUIStyle.primaryText(isDarkMode))
                    .foregroundColor(isDarkMode ? .black : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(GenUIStyle.subtleBackground(isDarkMode))
        .overlay(Rectangle().frame(height: 1).foregroundColor(GenUIStyle.borderColor(isDarkMode)), alignment: .bottom)
    }

    @ViewBuilder
    private var variantTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(args.variants.enumerated()), id: \.offset) { index, variant in
                    Button(action: { selected = index }) {
                        Text(variant.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    selected == index
                                    ? GenUIStyle.primaryText(isDarkMode)
                                    : Color.clear
                                )
                            )
                            .overlay(
                                Capsule().stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                            )
                            .foregroundColor(
                                selected == index
                                ? (isDarkMode ? .black : .white)
                                : GenUIStyle.primaryText(isDarkMode)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(GenUIStyle.subtleBackground(isDarkMode))
        .overlay(Rectangle().frame(height: 1).foregroundColor(GenUIStyle.borderColor(isDarkMode)), alignment: .bottom)
    }

    @ViewBuilder
    private var emailHeaderFields: some View {
        VStack(spacing: 0) {
            headerRow(label: "TO", value: args.to ?? "", placeholder: "recipient@example.com")
            Rectangle().frame(height: 1).foregroundColor(GenUIStyle.borderColor(isDarkMode))
            headerRow(label: "SUBJECT", value: variant?.subject ?? "", placeholder: "(no subject)")
            Rectangle().frame(height: 1).foregroundColor(GenUIStyle.borderColor(isDarkMode))
        }
    }

    @ViewBuilder
    private func headerRow(label: String, value: String, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption2.weight(.medium))
                .tracking(0.5)
                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                .frame(width: 64, alignment: .leading)
            Text(value.isEmpty ? placeholder : value)
                .font(.subheadline)
                .foregroundColor(value.isEmpty ? GenUIStyle.mutedText(isDarkMode) : GenUIStyle.primaryText(isDarkMode))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc").font(.caption2)
                Text(copied ? "Copied" : "Copy").font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundColor(GenUIStyle.mutedText(isDarkMode))
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        guard let body = variant?.body else { return }
        UIPasteboard.general.string = body
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func openMail(variant: MessageComposeWidget.Variant) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = args.to ?? ""
        var queryItems: [URLQueryItem] = []
        if let subject = variant.subject, !subject.isEmpty {
            queryItems.append(URLQueryItem(name: "subject", value: subject))
        }
        queryItems.append(URLQueryItem(name: "body", value: variant.body))
        components.queryItems = queryItems
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
