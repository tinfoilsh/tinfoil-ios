# Message interaction improvements

## Goals

Make long user messages look and behave like user messages rather than document attachments, restore native iOS text selection through the user-message context menu, simplify message editing, and make response retry actions consistent.

## Agreed behavior

### Long user messages

- Keep long messages collapsed in the transcript so very large rows do not create layout and performance problems.
- Replace the current document-style “Long Message” card, word count, document icon, and chevron with a normal-looking user-message preview.
- Show a short attributed-text preview with a trailing fade/ellipsis and a clear affordance that more content is available.
- Tapping the preview opens the complete message in the existing bottom sheet; do not expand enormous messages inline in the transcript.
- Render the full sheet with the same native attributed user-message treatment used by ordinary user bubbles, not the assistant `LaTeXMarkdownView`/StructuredText renderer.
- The full sheet must be one scrollable, non-editable, selectable native `UITextView`, preserving basic inline markdown styling and native iOS selection handles.
- Remove the “Select Text” toolbar button and the second raw, monospaced selection sheet.

### User-message long press

- Continue intercepting the initial long press to show an app-owned context menu.
- Menu actions should be Select Text, Copy, Edit (when allowed), and Fork (when allowed).
- Remove Resend entirely.
- For an ordinary user bubble, Select Text dismisses the menu, selects a word in that same bubble, and displays native iOS selection handles there.
- For a collapsed long-message preview, Select Text opens the full-message sheet and activates native selection there.
- Remove the permanently visible Fork icon beneath user messages.
- Keep Fork available for assistant messages because forking after an assistant response preserves that response.

### Message editing

- Continue using the existing bottom composer and destructive-tail warning.
- The warning’s X is the only cancel action.
- Remove the separate Cancel and Save text buttons.
- While editing, retain the normal model/reasoning controls, voice transcription, and trailing send arrow.
- The trailing arrow saves the edit and regenerates from that point.
- Hide the plus/attachment button while editing.
- Do not add or modify attachments in this change. Preserve the original message’s existing attachments exactly as today.
- Continue preserving and restoring the pre-edit composer draft on cancellation.

### Assistant actions and retry

- Keep the current responsive primary/overflow organization so actions can move into the ellipsis when space is constrained.
- Keep the existing Copy behavior that opens the raw-content copying sheet.
- Leave Share behavior unchanged.
- Keep assistant Fork.
- Do not add Continue.
- Normalize failed-response retry to one circular inline Regenerate icon.
- Remove the separate error-card “Try again” action.
- Ensure a completely empty failed response still exposes the inline Regenerate action.
- Preserve Upgrade behavior for errors where regeneration is intentionally unavailable, such as applicable premium limits.

## Constraints and rationale

- Do not render an arbitrarily large full message as an expanded table row.
- Do not re-enable Textual/StructuredText selection for unlimited content. It previously caused main-thread hangs because rich markdown selection can install custom `UITextInput` behavior across many fragments.
- `UITextInput` is internal selection machinery, not a visual style. A single native `UITextView` can retain the normal user-message appearance while providing native selection handles safely.
- Preserve VoiceOver affordances for collapsed content, expansion, context actions, and selected text.
- Do not let fade overlays intercept taps, long presses, links, or selection handles.
- Preserve current guards around safeguard-flagged chats, streaming, recovery, read-only state, account teardown, and concurrent edits/forks.

## Implementation sequence

1. [x] Replace the long-message attachment card and detail-selection flow.
2. [x] Add a programmatic selection handle for ordinary user-message `UITextView`s and update context menus.
3. [x] Simplify edit mode while retaining standard non-attachment composer controls.
4. [x] Normalize assistant retry controls, including empty failures.
5. [x] Add or update focused tests for selection/menu policy, edit controls/state, long-message thresholds/previews, and retry visibility where practical.
6. [ ] Compile and test in Xcode. Repository policy requires the user to handle building, running, and testing in Xcode and forbids command-line `xcodebuild`.
