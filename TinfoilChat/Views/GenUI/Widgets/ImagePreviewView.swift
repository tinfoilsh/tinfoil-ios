//
//  ImagePreviewView.swift
//  TinfoilChat
//
//  Full-screen, swipeable, pinch-to-zoom image previewer used by the
//  GenUI image widget. Mirrors the webapp lightbox: the user taps a
//  thumbnail and the gallery opens over the chat with paging across
//  the full image set, a close button, and an optional caption.

import SwiftUI

private let previewCloseButtonInset: CGFloat = 16
private let previewMinScale: CGFloat = 1.0
private let previewMaxScale: CGFloat = 4.0
private let previewDoubleTapScale: CGFloat = 2.5
private let previewBackgroundOpacity: Double = 0.96
private let previewSwipeDismissThreshold: CGFloat = 120
private let previewSwipeDismissMaxOffset: CGFloat = 600
private let previewSwipeDirectionLockRatio: CGFloat = 1.4

struct ImagePreviewView: View {
    let images: [ImageWidget.Item]
    @Binding var startIndex: Int
    @Binding var isPresented: Bool

    @State private var currentIndex: Int = 0
    @State private var dismissOffset: CGFloat = 0

    init(
        images: [ImageWidget.Item],
        startIndex: Binding<Int>,
        isPresented: Binding<Bool>
    ) {
        self.images = images
        self._startIndex = startIndex
        self._isPresented = isPresented
        self._currentIndex = State(initialValue: startIndex.wrappedValue)
    }

    private var backgroundOpacity: Double {
        let progress = min(abs(dismissOffset) / previewSwipeDismissMaxOffset, 1.0)
        return previewBackgroundOpacity * (1.0 - progress * 0.6)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZoomableImage(url: image.url, alt: image.alt, caption: image.caption)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .offset(y: dismissOffset)
            .simultaneousGesture(dismissGesture)

            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .padding(.top, previewCloseButtonInset)
            .padding(.trailing, previewCloseButtonInset)
            .accessibilityLabel("Close image viewer")
        }
        .onAppear { currentIndex = startIndex }
        .onChange(of: currentIndex) { _, value in startIndex = value }
        .statusBarHidden(true)
    }

    /// Vertical swipe-to-dismiss. Direction-locks so that horizontal
    /// drags fall through to the underlying `TabView`'s page gesture.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = abs(value.translation.width)
                let dy = value.translation.height
                guard dy > 0,
                      dy > dx * previewSwipeDirectionLockRatio else {
                    return
                }
                dismissOffset = dy
            }
            .onEnded { value in
                if dismissOffset > previewSwipeDismissThreshold ||
                   value.predictedEndTranslation.height > previewSwipeDismissMaxOffset / 2 {
                    isPresented = false
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dismissOffset = 0
                    }
                }
            }
    }
}

private struct ZoomableImage: View {
    let url: String
    let alt: String?
    let caption: String?

    @State private var scale: CGFloat = previewMinScale
    @State private var lastScale: CGFloat = previewMinScale
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var isZoomed: Bool { scale > previewMinScale }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                imageContent(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(magnification)
                    // Pan only while zoomed, so an un-zoomed view never
                    // intercepts horizontal drags from the parent
                    // TabView's page gesture or the container's
                    // swipe-down-to-dismiss.
                    .gesture(isZoomed ? panWhenZoomed : nil)
                    .onTapGesture(count: 2) { handleDoubleTap() }
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func imageContent(in size: CGSize) -> some View {
        if let parsed = URL(string: url),
           parsed.scheme?.lowercased() == "https" {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .empty:
                    ProgressView().tint(.white)
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.6))
                @unknown default:
                    Color.clear
                }
            }
            .accessibilityLabel(altText)
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private var altText: String {
        if let alt, !alt.isEmpty { return alt }
        if let caption, !caption.isEmpty { return caption }
        return "Image"
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let proposed = lastScale * value
                scale = min(max(proposed, previewMinScale), previewMaxScale)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= previewMinScale {
                    resetTransform()
                }
            }
    }

    private var panWhenZoomed: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func handleDoubleTap() {
        withAnimation(.easeInOut(duration: 0.18)) {
            if scale > previewMinScale {
                resetTransform()
            } else {
                scale = previewDoubleTapScale
                lastScale = previewDoubleTapScale
            }
        }
    }

    private func resetTransform() {
        scale = previewMinScale
        lastScale = previewMinScale
        offset = .zero
        lastOffset = .zero
    }
}
