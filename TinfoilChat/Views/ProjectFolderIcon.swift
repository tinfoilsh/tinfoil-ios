import SwiftUI

struct ProjectFolderIcon: View {
    let color: String?
    var size: CGFloat = 28

    private var tint: Color {
        Color.projectColor(color)
    }

    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(tint.opacity(0.12))
            )
    }
}
