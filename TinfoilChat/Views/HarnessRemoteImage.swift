import SwiftUI
import Textual

struct HarnessRemoteImage<Content: View>: View {
    let url: String
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    var body: some View {
        RemoteImageRequest(url: url, content: content).id(url)
    }
}

private struct RemoteImageRequest<Content: View>: View {
    let url: String
    @ViewBuilder var content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task {
                do {
                    let data = try await LinkMetadataService.shared.image(for: url)
                    try Task.checkCancellation()
                    guard let image = UIImage(data: data) else { throw LinkMetadataError.unavailable }
                    phase = .success(Image(uiImage: image))
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failure(error)
                }
            }
    }
}

struct HarnessImageAttachmentLoader: AttachmentLoader {
    func attachment(for url: URL, text: String, environment _: ColorEnvironmentValues) async throws -> some Textual.Attachment {
        let data = try await LinkMetadataService.shared.image(for: url.absoluteString)
        let size = try await MainActor.run {
            guard let image = UIImage(data: data) else { throw LinkMetadataError.unavailable }
            return image.size
        }
        return HarnessImageAttachment(data: data, description: text, width: size.width, height: size.height)
    }
}

private struct HarnessImageAttachment: Textual.Attachment {
    let data: Data
    let description: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                .accessibilityLabel(description)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        let fittedWidth = min(proposal.width ?? width, width)
        return CGSize(width: fittedWidth, height: fittedWidth * height / width)
    }

    func pngData() -> Data? { data }
}
