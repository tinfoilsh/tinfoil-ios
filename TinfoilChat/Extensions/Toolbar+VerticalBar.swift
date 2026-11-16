//
//  Toolbar+VerticalBar.swift
//  TinfoilChat
//
//  On iPhone Duo, toolbar items can move into a vertical bar along the side
//  of the screen. These adapt the app's bars to it on the releases that
//  have it.
//

import SwiftUI

extension ToolbarContent {
    /// Keeps an item in its bar after the items around it have moved to
    /// the overflow menu for lack of room.
    @ToolbarContentBuilder
    func staysVisibleLonger() -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}

extension View {
    /// Keeps a sheet's bar along its top rather than moving it into a
    /// vertical bar, for a sheet whose only bar item is its close button:
    /// a vertical bar would take a strip of the sheet's width for it.
    @ViewBuilder
    func keepsBarHorizontal() -> some View {
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
    }
}

/// Builds a toolbar's items knowing whether its buttons sit in a vertical bar
/// along the side, as on iPhone Duo. It reads this as the toolbar is built,
/// so the items for the bar's new axis come with the change that moves it.
struct VerticalBarToolbar<Content: ToolbarContent>: ToolbarContent {
    @ToolbarContentBuilder let content: (_ usesVerticalBar: Bool) -> Content

    var body: some ToolbarContent {
        if #available(iOS 27.1, *) {
            VerticalBarEdgeToolbar(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarEdgeToolbar<Content: ToolbarContent>: ToolbarContent {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let content: (Bool) -> Content

    var body: some ToolbarContent {
        content(verticalEdge != nil)
    }
}
