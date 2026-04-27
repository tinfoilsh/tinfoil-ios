//
//  ReasoningEffortSelector.swift
//  TinfoilChat
//
//  Icon-only pill that opens a menu for picking reasoning effort and (for
//  models that support it) toggling thinking on/off. The button label is
//  intentionally just the lightbulb icon — the current effort/state is
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
    case high
    case medium
    case low

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
            toggleOnlyMenu
        } else {
            effortMenu
        }
    }

    /// Menu for models that only expose on/off thinking — same look-and-
    /// feel as the effort menu, with two options (On / Off) so the
    /// interaction is consistent regardless of model capabilities.
    private var toggleOnlyMenu: some View {
        Menu {
            Section {
                Button {
                    thinkingEnabled = true
                } label: {
                    Label("On", systemImage: thinkingEnabled ? "checkmark" : "")
                }
                Button {
                    thinkingEnabled = false
                } label: {
                    Label("Off", systemImage: thinkingEnabled ? "" : "checkmark")
                }
            } header: {
                Text("Thinking — turn reasoning on or off")
            }
        } label: {
            iconLabel(active: thinkingEnabled)
        }
        .accessibilityLabel(thinkingEnabled ? "Thinking on" : "Thinking off")
    }

    /// Icon-only menu for models with graded effort. When the model also
    /// supports a toggle, an "Off" item is included.
    private var effortMenu: some View {
        Menu {
            Section {
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
                if supportsToggle {
                    Button {
                        thinkingEnabled = false
                    } label: {
                        Label("Off", systemImage: thinkingEnabled ? "" : "checkmark")
                    }
                }
            } header: {
                Text("Thinking — choose how much the model reasons")
            }
        } label: {
            iconLabel(active: !supportsToggle || thinkingEnabled)
        }
        .accessibilityLabel("Reasoning effort")
    }

    /// Shared icon-only pill body used by both the toggle button and the
    /// effort menu. Uses the SF Symbols `lightbulb`/`lightbulb.slash`
    /// glyph pair — the system-provided slash variant adapts to both
    /// light and dark modes natively, so no manual overlay is needed.
    private func iconLabel(active: Bool) -> some View {
        Image(systemName: active ? "lightbulb" : "lightbulb.slash")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(active ? .primary : .primary.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
    }
}
