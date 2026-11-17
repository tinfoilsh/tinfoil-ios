//
//  ConnectorCallView.swift
//  TinfoilChat
//

import SwiftUI
import TinfoilIcons

private enum ConnectorCallLayout {
    static let spacing: CGFloat = 10
    static let headerSpacing: CGFloat = 8
    static let titleSpacing: CGFloat = 2
    static let cardPadding: CGFloat = 12
    static let buttonSpacing: CGFloat = 8
    static let buttonHorizontalPadding: CGFloat = 12
    static let buttonVerticalPadding: CGFloat = 7
    static let buttonCornerRadius: CGFloat = 8
    static let sendingOpacity = 0.5
}

/// What answers a call that waits for the user's approval, and their answer
/// as it is sent.
struct ConnectorApproving {
    var state: ConnectorApprovalState?
    var answer: (ConnectorApprovalChoice) -> Void
}

/// A call a reply makes to a connector's tool: the connector and the tool,
/// how the call went and, while it waits for the user's approval, what
/// answers it.
struct ConnectorCallView: View {
    let call: ConnectorCallState
    let isDarkMode: Bool
    let approving: ConnectorApproving

    /// The call waits for an answer the user has not given.
    private var asks: Bool {
        call.pendingApprovalId() != nil && approving.state?.answered != true
    }

    private var isSending: Bool { approving.state?.sending != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: ConnectorCallLayout.spacing) {
            HStack(spacing: ConnectorCallLayout.headerSpacing) {
                FaviconView(url: call.connectorURL, isDarkMode: isDarkMode)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ConnectorCallLayout.titleSpacing) {
                    Text(asks ? "\(call.connectorName) wants to run \(call.toolName)" : "\(call.connectorName): \(call.toolName)")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                Spacer(minLength: 0)
                if call.status == .running, !asks || isSending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            if asks {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ConnectorCallLayout.buttonSpacing) { answers }
                    VStack(alignment: .leading, spacing: ConnectorCallLayout.buttonSpacing) { answers }
                }
                .disabled(isSending)
                .opacity(isSending ? ConnectorCallLayout.sendingOpacity : 1)
            }
            if let error = approving.state?.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .genUICard(isDarkMode: isDarkMode, padding: ConnectorCallLayout.cardPadding)
        .accessibilityElement(children: .contain)
    }

    private var statusLabel: String {
        if isSending { return "Sending your answer" }
        switch call.approval {
        case .declined:
            return "Declined"
        case .expired:
            return "Not answered in time"
        case .pending where call.status == .running:
            if approving.state?.answered == true { return "Answered" }
            return call.pendingApprovalId() == nil ? "Not answered in time" : "Waiting for your approval"
        case .pending, .approved, nil:
            break
        }
        switch call.status {
        case .running: return "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    @ViewBuilder
    private var answers: some View {
        answerButton("Allow once", choice: .once, isPrimary: true)
        answerButton("Always allow", choice: .always, isPrimary: false)
        answerButton("Decline", choice: .decline, isPrimary: false)
    }

    private func answerButton(_ title: String, choice: ConnectorApprovalChoice, isPrimary: Bool) -> some View {
        Button {
            approving.answer(choice)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundColor(isPrimary ? (isDarkMode ? Color.black : Color.white) : GenUIStyle.primaryText(isDarkMode))
                .padding(.horizontal, ConnectorCallLayout.buttonHorizontalPadding)
                .padding(.vertical, ConnectorCallLayout.buttonVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: ConnectorCallLayout.buttonCornerRadius)
                        .fill(isPrimary ? GenUIStyle.primaryText(isDarkMode) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ConnectorCallLayout.buttonCornerRadius)
                        .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: isPrimary ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}
