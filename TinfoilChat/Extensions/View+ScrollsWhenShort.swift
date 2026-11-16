//
//  View+ScrollsWhenShort.swift
//  TinfoilChat
//

import SwiftUI

extension View {
    /// Lets a screen laid out to fill its window scroll when the window is
    /// too short for it, as an iPhone in landscape is, so none of it is cut
    /// off. In a window tall enough for it, it fills the window as before,
    /// placed by `alignment` when it does not stretch to fill it.
    func scrollsWhenShort(alignment: Alignment = .center) -> some View {
        modifier(ScrollsWhenShort(alignment: alignment))
    }
}

private struct ScrollsWhenShort: ViewModifier {
    let alignment: Alignment

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: alignment)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
