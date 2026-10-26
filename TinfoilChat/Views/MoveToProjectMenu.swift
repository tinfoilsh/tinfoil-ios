import SwiftUI

/// Context-menu submenu listing the projects a chat can be filed under, so
/// a long project list doesn't crowd the parent menu.
struct MoveToProjectMenu: View {
    let title: String
    let projects: [Project]
    let onSelect: (Project) -> Void

    var body: some View {
        if !projects.isEmpty {
            Menu {
                ForEach(projects) { project in
                    Button {
                        onSelect(project)
                    } label: {
                        Label {
                            Text(project.name)
                        } icon: {
                            ProjectFolderIcon(color: project.color, size: 22)
                        }
                    }
                }
            } label: {
                Label(title, systemImage: "folder")
            }
        }
    }
}
