//
//  AutoIntelligenceSelector.swift
//  TinfoilChat
//
//  Icon-only pill shown in place of the reasoning controls when Auto is the
//  selected model. Tapping it opens a popover with a thick stepped slider
//  (Low / Med / High / Extra / Max) that sets how capable a model and how
//  much reasoning the router should pick.
//

import SwiftUI

struct AutoIntelligenceSelector: View {
    @Binding var intelligence: AutoIntelligence
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            iconLabel
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AutoIntelligencePopover(intelligence: $intelligence)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Auto intelligence")
        .accessibilityValue(intelligence.label)
        .accessibilityHint("Chooses how capable a model Auto picks")
    }

    @ViewBuilder
    private var iconLabel: some View {
        let pill = Image(systemName: "slider.horizontal.3")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        if #available(iOS 26, *) {
            pill.glassEffect(.identity)
        } else {
            pill
        }
    }
}

private struct AutoIntelligencePopover: View {
    @Binding var intelligence: AutoIntelligence

    var body: some View {
        VStack(spacing: Constants.UI.AutoIntelligenceSlider.popoverSpacing) {
            Text(intelligence.label)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.numericText())
                .animation(.snappy, value: intelligence)
            SteppedSlider(
                stepCount: AutoIntelligence.allCases.count,
                index: Binding(
                    get: { intelligence.index },
                    set: { intelligence = AutoIntelligence.at(index: $0) }
                )
            )
            .accessibilityLabel("Intelligence")
            .accessibilityValue(intelligence.label)
            Text("Higher intelligence picks a more capable model and thinks longer.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Constants.UI.AutoIntelligenceSlider.popoverPadding)
        .frame(width: Constants.UI.AutoIntelligenceSlider.popoverWidth)
    }
}

/// A discrete slider with one stop per step. The track is as tall as a switch
/// so the fill reads as a level indicator; a dot marks each stop and the thumb
/// covers the current one.
struct SteppedSlider: View {
    let stepCount: Int
    @Binding var index: Int

    private let trackHeight = Constants.UI.AutoIntelligenceSlider.trackHeight
    private let thumbDiameter = Constants.UI.AutoIntelligenceSlider.thumbDiameter
    private let dotDiameter = Constants.UI.AutoIntelligenceSlider.dotDiameter

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = width - thumbDiameter
            let stepWidth = stepCount > 1 ? travel / CGFloat(stepCount - 1) : 0
            let thumbCenterX = thumbDiameter / 2 + CGFloat(index) * stepWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(Color.accentPrimary)
                    .frame(width: thumbCenterX + thumbDiameter / 2)
                HStack(spacing: 0) {
                    ForEach(0..<stepCount, id: \.self) { step in
                        Circle()
                            .fill(step <= index ? Color.white.opacity(0.6) : Color.secondary.opacity(0.7))
                            .frame(width: dotDiameter, height: dotDiameter)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, thumbDiameter / 2 - dotDiameter / 2)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbCenterX - thumbDiameter / 2)
            }
            .frame(height: trackHeight)
            .animation(.snappy(duration: 0.2), value: index)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard stepWidth > 0 else { return }
                        let position = value.location.x - thumbDiameter / 2
                        let nearest = Int((position / stepWidth).rounded())
                        let clamped = min(max(nearest, 0), stepCount - 1)
                        if clamped != index { index = clamped }
                    }
            )
        }
        .frame(height: trackHeight)
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(index + 1, stepCount - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: break
            }
        }
    }
}
