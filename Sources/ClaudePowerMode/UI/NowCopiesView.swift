import SwiftUI
@testable import PageCore

// A conversation open in two terminals, on its card in the Now panel (Designs/session-copies.md): an amber
// line with "Close the other", and the confirm that opens inside the card. Laid out like the budget line and
// its editor, drawn like the health line. State lives in `NowStore`; Close calls `onCloseOtherCopies`.

/// The card's copies slot: the line, and the confirm when it is open here.
struct NWCopiesSlot: View {
    @ObservedObject var store: NowStore
    var sessionId: String
    var project: String
    var copies: SessionCopies

    private var asking: Bool { store.copiesConfirm == sessionId }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NWCopiesLineView(copies: copies, asking: asking) { store.askCloseOtherCopies(sessionId: sessionId) }
            if asking {
                NWCopiesConfirmView(project: project,
                                    onCancel: { store.cancelCloseOtherCopies() },
                                    onClose: { store.confirmCloseOtherCopies() })
            }
        }
    }
}

/// "⚠ Open in 2 terminals · close one" and, under it, [Close the other]. No button when Page Studio can't close the other,
/// or while the confirm is open.
struct NWCopiesLineView: View {
    var copies: SessionCopies
    var asking = false
    var onClose: () -> Void = {}

    private var warning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Font.system(size: 10, weight: .medium))
                .foregroundColor(NightWatch.Palette.amber.opacity(0.95).color)
            Text(SessionCopiesCopy.line(count: copies.count))
                .font(NightWatch.Typo.monoMicro)
                .foregroundColor(NightWatch.Palette.amber.opacity(0.95).color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var button: some View {
        NWActionButton(title: SessionCopiesCopy.closeButton, help: SessionCopiesCopy.closeHelp) { onClose() }
            .fixedSize()
    }

    var body: some View {
        // The sentence is the warning, so it is never cut or wrapped: the button goes on its own row under it,
        // at the card's right edge like the editors' buttons. While its confirm is open the button goes: the
        // confirm's own Close and Cancel are the only buttons then (the approved design, 2026-11-14).
        VStack(alignment: .leading, spacing: 7) {
            warning
            if copies.canCloseOther && !asking {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    button
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(SessionCopiesCopy.line(count: copies.count)))
    }
}

/// The inline confirm, in the panel's own style (the budget editor's box): the question, what it does, Cancel and Close.
struct NWCopiesConfirmView: View {
    var project: String
    var onCancel: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            (Text(SessionCopiesCopy.confirmQuestion(project: project) + " ")
                .font(Font.system(size: 12, weight: .semibold))
                .foregroundColor(NightWatch.Palette.textPrimary.color)
             + Text(SessionCopiesCopy.confirmDetail)
                .font(NightWatch.Typo.monoSmall)
                .foregroundColor(NightWatch.Palette.textSecondary.color))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                NWActionButton(title: SessionCopiesCopy.confirmCancel, help: "Leave both terminals open · Esc") { onCancel() }
                NWActionButton(title: SessionCopiesCopy.confirmClose, emphasised: true,
                               help: "Close the other terminal · Return") { onClose() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(NightWatch.Palette.glass.opacity(0.4).color, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
