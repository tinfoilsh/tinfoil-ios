import SwiftUI
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Offers a saved file to the share sheet, and removes it once the sheet
/// closes.
private struct ExportedFileShareSheet: ViewModifier {
    @Binding var file: ExportedFile?
    /// The file the sheet shows, which the binding no longer holds once the
    /// sheet closes.
    @State private var shown: ExportedFile?

    func body(content: Content) -> some View {
        content
            .sheet(item: $file, onDismiss: removeShown) { file in
                ActivityView(activityItems: [file.url])
            }
            .onChange(of: file, initial: true) { _, file in
                if let file { shown = file }
            }
    }

    private func removeShown() {
        shown?.remove()
        shown = nil
    }
}

extension View {
    func shareSheet(for file: Binding<ExportedFile?>) -> some View {
        modifier(ExportedFileShareSheet(file: file))
    }
}
