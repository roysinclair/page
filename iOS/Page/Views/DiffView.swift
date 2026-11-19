import SwiftUI
import UIKit

/// A session's changes as a sheet: this turn's files (or the repository's
/// uncommitted changes) with the redacted diff, asked from the Mac when the
/// screen opens (`diff` op). Read-only. The Session Room's Changes lens
/// draws the same panel; this is for the turn summary on a Decision sheet.
struct DiffView: View {
    let sessionId: String
    let title: String

    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var content: SessionContent
    @Environment(\.dismiss) private var dismiss
    @State private var requestedAt = Date()
    /// Bumped once the Mac has had `ChangesModel.noAnswerAfter` seconds to answer: the only moment the screen
    /// changes with nothing new in hand, so nothing else ticks.
    @State private var waited = 0

    var body: some View {
        _ = waited
        let load = ChangesModel.load(hasDiff: content.diffs[sessionId] != nil, error: content.diffErrors[sessionId],
                                     requestedAt: requestedAt, now: Date())
        return ZStack {
            NWBackdrop()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.system(.body, weight: .semibold))
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .frame(width: 48, height: 48).nwChromeGlass(in: Circle()) { Circle().fill(Color.white.opacity(0.09)) }
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text("Close"))
                    Text(title).font(.system(.title3, design: .monospaced, weight: .semibold))
                        .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, NightWatch.Space.lg).padding(.top, 14).padding(.bottom, 6)
                NWChangesPanel(model: content.diffs[sessionId].map(ChangesModel.build), load: load,
                               onRefresh: request, onCopy: { UIPasteboard.general.string = $0 }) { EmptyView() }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { request() }
        .task(id: requestedAt) {
            try? await Task.sleep(nanoseconds: UInt64((ChangesModel.noAnswerAfter + 0.05) * 1_000_000_000))
            if !Task.isCancelled { waited += 1 }
        }
    }

    private func request() {
        requestedAt = Date()
        sessions.requestDiff(sessionId: sessionId)
    }
}
