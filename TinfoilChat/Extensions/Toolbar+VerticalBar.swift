//
//  Toolbar+VerticalBar.swift
//  TinfoilChat
//
//  On iPhone Duo, toolbar items can move into a vertical bar along the side
//  of the screen. These let the app's custom items join it on the releases
//  that have it.
//

import SwiftUI

extension ToolbarContent {
    /// Lets an item whose custom view is no bigger than an icon move into a
    /// vertical bar, as an item with a symbol does. A custom view otherwise
    /// stays in a horizontal bar.
    @ToolbarContentBuilder
    func allowsVerticalBar() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            axisBehavior(.verticalPreferred)
        } else {
            self
        }
    }

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

    /// Keeps `usesVerticalBar` set to whether the bars of the navigation
    /// container this view is in go into a vertical bar, as on a closed
    /// iPhone Duo.
    func readsVerticalBar(into usesVerticalBar: Binding<Bool>) -> some View {
        background {
            VerticalBarReader { isInVerticalBar in
                Color.clear
                    .onChange(of: isInVerticalBar, initial: true) { _, isVertical in
                        usesVerticalBar.wrappedValue = isVertical
                    }
            }
        }
    }
}

/// Builds a toolbar item's view knowing whether it is in a vertical bar,
/// which has room for an icon only.
struct VerticalBarReader<Content: View>: View {
    @ViewBuilder let content: (_ isInVerticalBar: Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            VerticalBarEdgeReader(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let content: (Bool) -> Content

    var body: some View {
        content(verticalEdge != nil)
    }
}
