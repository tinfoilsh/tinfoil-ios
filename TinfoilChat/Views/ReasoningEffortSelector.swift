//
//  ReasoningEffortSelector.swift
//  TinfoilChat
//
//  Icon-only pill that opens a menu for picking reasoning effort and (for
//  models that support it) toggling thinking on/off. The button label is
//  intentionally just the brain icon — the current effort/state is
//  surfaced via the menu's checkmarks rather than the button text.
//
//   - Toggle-only (e.g. Gemma): tapping the icon flips `thinkingEnabled`
//     directly, no menu needed.
//   - Effort + optional toggle (e.g. DeepSeek, GPT-OSS): tapping opens a
//     menu with Low / Medium / High plus an "Off" entry when the model
//     also supports a toggle.
//

import SwiftUI

private enum EffortOption: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var asReasoningEffort: ReasoningEffort {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }

    init(_ effort: ReasoningEffort) {
        switch effort {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}

struct ReasoningEffortSelector: View {
    /// Whether the model exposes graded effort (low/medium/high).
    let supportsEffort: Bool
    /// Whether the model exposes an on/off thinking toggle.
    let supportsToggle: Bool
    @Binding var reasoningEffort: ReasoningEffort
    @Binding var thinkingEnabled: Bool

    var body: some View {
        if !supportsEffort && !supportsToggle {
            EmptyView()
        } else if supportsToggle && !supportsEffort {
            toggleOnlyButton
        } else {
            effortMenu
        }
    }

    /// Icon-only pill for models that only expose on/off thinking. Tapping
    /// flips `thinkingEnabled` immediately without a menu.
    private var toggleOnlyButton: some View {
        Button {
            thinkingEnabled.toggle()
        } label: {
            iconLabel(active: thinkingEnabled)
        }
        .accessibilityLabel(thinkingEnabled ? "Thinking on" : "Thinking off")
    }

    /// Icon-only menu for models with graded effort. When the model also
    /// supports a toggle, an "Off" item is included.
    private var effortMenu: some View {
        Menu {
            if supportsToggle {
                Button {
                    thinkingEnabled = false
                } label: {
                    Label("Off", systemImage: thinkingEnabled ? "" : "checkmark")
                }
            }
            ForEach(EffortOption.allCases) { option in
                Button {
                    if supportsToggle && !thinkingEnabled {
                        thinkingEnabled = true
                    }
                    reasoningEffort = option.asReasoningEffort
                } label: {
                    let isActive = (!supportsToggle || thinkingEnabled)
                        && EffortOption(reasoningEffort) == option
                    Label(option.displayLabel, systemImage: isActive ? "checkmark" : "")
                }
            }
        } label: {
            iconLabel(active: !supportsToggle || thinkingEnabled)
        }
        .accessibilityLabel("Reasoning effort")
    }

    /// Shared icon-only pill body used by both the toggle button and the
    /// effort menu. When inactive, a diagonal slash is drawn through the
    /// brain to indicate thinking is disabled (SF Symbols has no
    /// `brain.slash` glyph, so the slash is overlaid manually). The slash
    /// is rendered as a single solid `.primary` capsule on top of the
    /// brain, which adapts correctly to both light and dark modes.
    private func iconLabel(active: Bool) -> some View {
        Image(systemName: "brain")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(active ? .primary : .primary.opacity(0.9))
            .overlay(alignment: .center) {
                if !active {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 22, height: 2.5)
                        .rotationEffect(.degrees(-45))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
    }
}
