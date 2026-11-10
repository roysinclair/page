import SwiftUI

// The Now stream's building blocks: section headers, the Decide cards shaped
// by reversibility, the swipeable Undoable row, Look and Review cards, the
// Settled list and the floating nav capsule. They draw a `NowRow` and hand
// every action to a closure; the screen that hosts them routes it through
// the existing services (APIClient / SessionStore / NotificationService),
// so these views never type anything themselves.

/// "Decide ②": a title in words with the section's glyph, and the count in
/// a filled badge of its colour. Room above it, so each section reads as its
/// own group. Settled, which is only told, passes `quiet`: no glyph, no badge.
struct NWSectionHeader: View {
    var title: String
    var count: Int?
    var color: NightWatch.RGBA
    var symbol: String? = nil
    var quiet = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol, !quiet { NWIconTile(symbol: symbol, jewel: .of(color), size: 30) }
            Text(NWSectionHeader.words(title))
                .font(quiet ? NightWatch.Typo.title : NightWatch.Typo.section)
                .foregroundColor((quiet ? NightWatch.Palette.textSecondary : NightWatch.Palette.textPrimary).color)
            if let count, !quiet { NWCountBadge(count: count, color: color) }
            Spacer(minLength: 0)
        }
        // Sections stand apart: more room above a section than between its cards.
        .padding(.top, quiet ? 4 : 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// "IN FLIGHT" → "In flight".
    static func words(_ title: String) -> String { SectionTitle.words(title) }
}

/// A section's count: a glossy pill of its colour, glowing a little.
struct NWCountBadge<Count: Hashable>: View {
    var count: Count
    var color: NightWatch.RGBA
    var reduceMotion = false

    var body: some View {
        Text("\(String(describing: count))").font(.system(.footnote, weight: .heavy)).monospacedDigit()
            .foregroundColor(NightWatch.Palette.onBright.color)
            .padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24)
            .background(Capsule().fill(LinearGradient(colors: [color.mixed(with: .init(1, 1, 1), 0.3).color, color.color],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            .shadow(color: color.opacity(0.55).color, radius: 6, x: 0, y: 2)
    }
}

extension NowRow.Section {
    var color: NightWatch.RGBA {
        switch self {
        case .decide, .look: return NightWatch.Palette.amber
        case .review: return NightWatch.Palette.teal
        }
    }

    var symbol: String {
        switch self {
        case .decide: return "hand.raised.fill"
        case .look: return "eye.fill"
        case .review: return "checkmark.seal.fill"
        }
    }
}

extension NowRow {
    /// "waiting 4m", "finished 2m".
    func waitingText(now: Date) -> String {
        let t = RelativeTime.compact(seconds: Int(max(0, now.timeIntervalSince(waitingSince))))
        return (section == .review ? "finished " : "waiting ") + t
    }

    var tint: NightWatch.RGBA? {
        switch chip {
        case .irreversible: return NightWatch.Palette.red
        case .considered: return NightWatch.Palette.sky
        case .looksStuck, .forecast, .rateLimited, .question, .budget: return NightWatch.Palette.amber
        case .undoable: return NightWatch.Palette.green
        case .review: return NightWatch.Palette.teal
        }
    }
}

/// The header line of a card: chip, project, how long it has waited.
struct NWCardTopLine: View {
    var row: NowRow
    var now: Date
    var onJewel = false
    var body: some View {
        HStack(spacing: 10) {
            NWChip(kind: row.chip, pill: true, onJewel: onJewel)
            Text(row.projectName)
                .font(NightWatch.Typo.name)
                .foregroundColor(onJewel ? Color.white.opacity(0.92) : NightWatch.Palette.textSecondary.color)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if onJewel { Image(systemName: "clock").font(.system(.caption2, weight: .bold)) }
                // On a jewel the clock says "waiting"; the chip holds just the time.
                Text(onJewel ? WaitChip.text(row.waitingText(now: now)) : row.waitingText(now: now)).lineLimit(1)
            }
            .font(NightWatch.Typo.captionStrong.monospacedDigit())
            .foregroundColor(onJewel ? Color.white.opacity(0.95) : NightWatch.Palette.textTertiary.color)
            .padding(.horizontal, onJewel ? 8 : 0).padding(.vertical, onJewel ? 4 : 0)
            .background(Capsule().fill(Color.black.opacity(onJewel ? 0.22 : 0)))
        }
    }
}

/// What the card's action area says once an action is under way: the 1.2 s
/// cancel ring (nothing has been sent; tapping cancels), then the wait for
/// the Mac, then the Mac's word. Only a confirmed delivery is teal. Given
/// the delivery state (`receipt`), it is drawn as the Receipt thread.
struct NWOutcomeStrip: View {
    var outcome: CardOutcome
    var pending: PendingAction?
    var receipt: ReceiptThreadInput? = nil
    var onCancel: () -> Void = {}

    var body: some View {
        if let receipt, !receipt.isEmpty, outcome != .none {
            NWReceiptThreadView(input: receipt, onTap: onCancel)
        } else {
            plain
        }
    }

    @ViewBuilder private var plain: some View {
        switch outcome {
        case .none: EmptyView()
        case .arming:
            if let pending {
                // Ticks until the ring is full, and holds while Now is covered or the app is not active
                // (the harness's pinned clock draws one moment; Reduce Motion ticks every 0.1 s).
                NWLiveClock(until: pending.armed ? pending.startedAt.addingTimeInterval(pending.armDuration) : nil) { now in
                    arming(pending, now: now)
                }
            }
        case .sending:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color)
                Text("Waiting for your computer to confirm…").font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textSecondary.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous).fill(Color.white.opacity(0.06)))
            .accessibilityElement(children: .combine)
        case .delivered(let detail):
            NWReceiptLine(text: "Delivered · \(detail)")
        case .problem(let why):
            // Tapping opens the decision, to see what happened and try again.
            Button(action: onCancel) { NWReceiptLine(text: why, failed: true) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the decision to try again"))
        }
    }

    private func arming(_ p: PendingAction, now: Date) -> some View {
        let progress: Double
        if case .arming(let v) = p.phase(now: now) { progress = v } else { progress = 1 }
        return Button(action: onCancel) {
            HStack(spacing: 12) {
                NWRing(progress: progress, color: NightWatch.Palette.amber, lineWidth: 3.5, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.armLabel(now: now)).font(NightWatch.Typo.bodyStrong)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                    if let preview = p.preview {
                        Text(preview).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Text("Cancel").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.amber.color)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.12).color))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                .strokeBorder(NightWatch.Palette.amber.opacity(0.4).color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Sending, tap to cancel"))
    }
}

/// A Decide card for a Considered or Irreversible approval: the command in
/// full, the delivery preview, then Deny and the approve control. Considered
/// approves with a tap (then the 1.2 s cancel ring); Irreversible with
/// press-and-hold plus biometrics. Tapping the card opens the Decision sheet.
struct NWDecideCard: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    var fixedHold: Double? = nil
    var onApprove: () -> Void = {}
    var onHoldComplete: () -> Void = {}
    var onDeny: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        let irreversible = row.chip == .irreversible
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 14) {
                    NWCardTopLine(row: row, now: now, onJewel: true)
                    HStack(alignment: .center, spacing: 12) {
                        NWIconTile(symbol: row.chip.symbol, jewel: .of(row.tint), size: 44, glass: true)
                        Text(row.headline)
                            .font(NightWatch.Typo.headline)
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    commandBox(irreversible: irreversible)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the decision"))
            // The buttons below are the visible way; these are the same, named, for VoiceOver.
            .accessibilityActions {
                // Same condition as the visible buttons: Deny present, Approve beside it.
                if outcome == .none, row.action(.deny) != nil {
                    Button("Deny") { onDeny() }
                    if row.action(.approve) != nil {
                        // The hold's own path: it still asks the phone to confirm before anything is sent.
                        if irreversible { Button("Approve, then confirm with your device") { onHoldComplete() } }
                        else { Button("Approve") { onApprove() } }
                    }
                }
            }
            actions(irreversible: irreversible)
        }
        .padding(NightWatch.Space.lg)
        .background(NWJewelSurface(jewel: .of(row.tint), lift: 1.25))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func actions(irreversible: Bool) -> some View {
        if outcome != .none {
            NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
        } else if let deny = row.action(.deny) {
            HStack(spacing: 10) {
                Button(deny.label, action: onDeny).buttonStyle(NWButtonStyle(kind: .glass))
                if let approve = row.action(.approve) {
                    if irreversible {
                        NWHoldButton(fixedProgress: fixedHold, onJewel: true, onComplete: onHoldComplete)
                    } else {
                        Button(approve.label, action: onApprove).buttonStyle(NWButtonStyle(kind: .white))
                    }
                }
            }
        } else if row.action(.openOnMac) != nil {
            Button("Open on your computer", action: onOpen).buttonStyle(NWButtonStyle(kind: .glass))
        }
    }

    private func commandBox(irreversible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").foregroundColor((irreversible ? NightWatch.Palette.red : NightWatch.Palette.textTertiary).color)
                Text(row.summary).foregroundColor((irreversible ? NightWatch.Palette.red.mixed(with: .init(1, 1, 1), 0.2) : NightWatch.Palette.textPrimary).color)
                    .lineLimit(3)
            }
            .font(NightWatch.Typo.mono)
            if let p = row.focusPreview {
                Text(p).font(NightWatch.Typo.monoMicro).foregroundColor(Color.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A well cut into the jewel: darker, with its shadow along the top edge.
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous)
            .fill(NightWatch.Palette.inset.opacity(0.72).color)
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.5), Color.white.opacity(0.10)], startPoint: .top, endPoint: .bottom), lineWidth: 1)))
    }
}

/// A question: the agent is waiting for words, not a yes or no. The answer is
/// written in the sheet (Esc, then your message, then Return).
struct NWQuestionCard: View {
    var row: NowRow
    var now: Date
    /// The Mac sent the question itself, so the sheet offers tap-to-tick answers.
    var answerable = false
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                NWCardTopLine(row: row, now: now, onJewel: true)
                HStack(alignment: .center, spacing: 12) {
                    NWIconTile(symbol: row.chip.symbol, jewel: .of(row.tint), size: 44, glass: true)
                    Text(row.summary)
                        .font(NightWatch.Typo.title)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                if let p = row.focusPreview {
                    Text(p).font(NightWatch.Typo.monoMicro).foregroundColor(Color.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                }
                HStack {
                    Spacer()
                    Text(answerable ? "Answer" : (row.action(.tellInstead)?.label ?? "Open"))
                        .font(NightWatch.Typo.button).foregroundColor(NightWatch.Palette.onBright.color)
                        .padding(.horizontal, 22).frame(minHeight: 44)
                        .background(Capsule().fill(Color.white))
                }
            }
            .padding(NightWatch.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NWJewelSurface(jewel: .of(row.tint), lift: 1.25))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the question"))
    }
}

/// An Undoable row: swipe right to approve. The Approve affordance sits behind
/// the row and is revealed as it moves; past the threshold a haptic ticks and
/// the 1.2 s cancel ring starts (nothing is sent until it runs out). A tap
/// opens the Decision sheet.
struct NWUndoableRow: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    /// Draws the row part-way through a swipe (the render harness).
    var fixedDrag: CGFloat? = nil
    var onApprove: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}
    @State private var drag: CGFloat = 0
    @State private var passed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwChromeGlassOn) private var glass
    private let commitAt: CGFloat = 110

    var body: some View {
        if outcome != .none {
            VStack(alignment: .leading, spacing: 10) {
                rowBody.background(NWJewelSurface(jewel: .green, radius: NightWatch.Radius.row))
                NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
            }
        } else {
            swipeable
        }
    }

    private var swipeable: some View {
        // A row with no Approve action (Open on Mac only) is never swipeable, whatever its chip says.
        let can = row.canSwipeApprove
        let x = can ? (fixedDrag ?? drag) : 0
        return ZStack(alignment: .leading) {
            if can {
            // The well is chrome the row uncovers: green glass, greener as the swipe nears the threshold.
            // Glass only while the row is moved, so a row at rest has nothing showing round its rim.
            let reach = Double(min(1, x / commitAt))
            if x > 0 || !glass {
                Color.clear
                    .nwChromeGlass(in: RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous),
                                   tint: NightWatch.Palette.chromeGlass.mixed(with: NightWatch.Palette.green.opacity(0.6), 0.22 + 0.2 * reach),
                                   interactive: false) {
                        RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
                            .fill(NightWatch.Palette.green.opacity(0.14 + 0.10 * reach).color)
                    }
                    .overlay(HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                        Text("Approve").font(NightWatch.Typo.bodyStrong)
                    }
                    .foregroundColor(NightWatch.Palette.green.color)
                    .padding(.leading, 18), alignment: .leading)
            }
            }
            rowBody
                // Opaque, so the Approve well never shows through the row.
                .background(NWJewelSurface(jewel: .green, radius: NightWatch.Radius.row))
                .offset(x: x)
                .onTapGesture(perform: onOpen)
                // Beside the list's own scrolling; only a clearly sideways drag moves the row.
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard can, NWDestination.isHorizontal(dx: Double(v.translation.width), dy: Double(v.translation.height)) else { drag = 0; return }
                        drag = max(0, min(160, v.translation.width))
                        if drag >= commitAt, !passed { passed = true; NWHaptics.tick() }
                        if drag < commitAt { passed = false }
                    }
                    .onEnded { v in
                        let go = can && v.translation.width >= commitAt
                            && NWDestination.isHorizontal(dx: Double(v.translation.width), dy: Double(v.translation.height))
                        passed = false
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { drag = 0 }
                        if go { onApprove() }
                    })
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.summary), \(row.projectName), undoable"))
        .accessibilityActions { if can { Button("Approve") { onApprove() } } }
        .accessibilityAction(named: Text("Open")) { onOpen() }
    }

    private var rowBody: some View {
        HStack(spacing: 14) {
            NWIconTile(symbol: "terminal.fill", jewel: .green, size: 44, glass: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.summary).font(NightWatch.Typo.mono)
                    .foregroundColor(.white).lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(row.projectName) · undoable")
                    Image(systemName: "chevron.right.2").font(.system(.caption2, weight: .bold))
                    Text("swipe to run")
                }
                .font(NightWatch.Typo.captionStrong)
                .foregroundColor(Color.white.opacity(0.92)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

/// A Look card: a stuck agent, a rate limit, a forecast. Tapping opens the
/// sheet; the button acts (Steer opens the composer, Stop it arms the cancel ring).
struct NWLookCard: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    var onSteer: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                NWIconTile(symbol: row.chip.symbol, jewel: .amber, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.headline).font(NightWatch.Typo.title)
                        .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle).font(NightWatch.Typo.caption)
                        .foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if outcome == .none, let steer = row.action(.tellInstead) {
                    Button(steer.label, action: onSteer)
                        .buttonStyle(NWButtonStyle(kind: .amber))
                        .frame(width: 84)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            if outcome != .none { NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel) }
        }
        .padding(NightWatch.Space.md)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, fill: NightWatch.Palette.surfaceRaised, tint: NightWatch.Palette.amber))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open")) { onOpen() }
        .accessibilityActions { if outcome == .none, let steer = row.action(.tellInstead) { Button(steer.label) { onSteer() } } }
    }

    /// "cargo test failed 6× · since 00:58" style: the summary, then how long.
    private var subtitle: String { "\(row.summary) · \(row.waitingText(now: now))" }
}

/// A Review card: a finished turn, with what changed and Looks good. The
/// first time it shows this app process its chips count up from 0 and the
/// tests ✓ draws (`NowMotion.chipText`, `chipCheck`), on a clock of its own
/// that stops when they have.
struct NWReviewCard: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    /// When its chips first showed (reference-date seconds); nil: they have long since counted.
    var chipsShownAt: Double? = nil
    var motion = NWNowMotion()
    var onLooksGood: () -> Void = {}
    var onSteer: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        NWIconTile(symbol: "checkmark.seal.fill", jewel: .teal, size: 36)
                        Text(row.projectName).font(NightWatch.Typo.nameLarge)
                            .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.waitingText(now: now)).font(NightWatch.Typo.caption.monospacedDigit())
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                    }
                    let chips = TurnSummaryChips.parse(row.summary)
                    if chips.isEmpty {
                        Text(row.summary).font(NightWatch.Typo.body)
                            .foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        let start = motion.reduceMotion ? nil : chipsShownAt
                        NWWorkflowClock(origin: 0, until: (start ?? -.infinity) + NowMotion.chipsSettle, pinned: motion.pinned) { t in
                            HStack(spacing: 8) {
                                ForEach(Array(chips.enumerated()), id: \.offset) { _, c in NWTurnChip(chip: c, elapsed: start.map { t - $0 } ?? .infinity) }
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the finished turn"))
            .accessibilityActions {
                if outcome == .none {
                    if row.action(.carryOn) != nil { Button("Looks good") { onLooksGood() } }
                    if let steer = row.action(.tellInstead) { Button(steer.label) { onSteer() } }
                }
            }
            if outcome != .none {
                NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
            } else {
                HStack(spacing: 10) {
                    if let steer = row.action(.tellInstead) { Button(steer.label, action: onSteer).buttonStyle(NWButtonStyle(kind: .quiet)) }
                    if row.action(.carryOn) != nil {
                        Button(action: onLooksGood) { Text("Looks good ✦") }.buttonStyle(NWButtonStyle(kind: .bright))
                    } else if row.action(.openOnMac) != nil {
                        Button("Open on your computer", action: onOpen).buttonStyle(NWButtonStyle(kind: .quiet))
                    }
                }
            }
        }
        .padding(NightWatch.Space.lg)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, fill: NightWatch.Palette.surfaceRaised, tint: NightWatch.Palette.teal))
        .accessibilityElement(children: .contain)
    }
}

/// "3 files", "+120", "−14", "tests ✓". `elapsed` seconds since its card
/// first showed: its number counts up from 0, then the ✓ draws; the final
/// words hold its width throughout, so nothing beside it shifts, and it is
/// read as its final words.
struct NWTurnChip: View {
    var chip: TurnChip
    var elapsed: Double = .infinity

    var body: some View {
        let c: NightWatch.RGBA
        switch chip.tone {
        case .neutral: c = NightWatch.Palette.textPrimary
        case .added, .pass: c = NightWatch.Palette.green
        // A failed test is amber, never red: red is for two press-and-hold commits only.
        case .removed: c = NightWatch.Palette.red
        case .fail: c = NightWatch.Palette.amber
        }
        return ZStack(alignment: .leading) {
            words(chip.text, check: 1, color: c).hidden()
            words(NowMotion.chipText(chip.text, at: elapsed), check: NowMotion.chipCheck(elapsed), color: c)
        }
        .font(NightWatch.Typo.monoSmall)
        .foregroundColor(c.opacity(0.95).color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.opacity(chip.tone == .neutral ? 0.09 : 0.14).color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(chip.text))
    }

    /// The words, a passing chip's ✓ drawn `check` of the way.
    @ViewBuilder private func words(_ text: String, check: Double, color: NightWatch.RGBA) -> some View {
        if chip.tone == .pass, text.hasSuffix("✓") {
            NWDrawnCheck.over(text, progress: check, color: color.opacity(0.95))
        } else {
            Text(text)
        }
    }
}

/// A ✓ that draws itself (`progress` 0 ... 1), in the space the font's ✓
/// takes, so a line keeps its width and its baseline whether it is drawn or not.
struct NWDrawnCheck: View {
    var progress: Double
    var color: NightWatch.RGBA

    /// `text` ending in "✓", its ✓ drawn in place of the glyph (one run of text, so its spacing is the font's).
    static func over(_ text: String, progress: Double, color: NightWatch.RGBA) -> some View {
        (Text(String(text.dropLast())) + Text("✓").foregroundColor(.clear))
            .overlay(alignment: .trailing) { NWDrawnCheck(progress: progress, color: color) }
    }

    var body: some View {
        Text("✓").hidden()
            .overlay(NWCheckShape().trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                .stroke(color.color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .opacity(progress > 0.001 ? 1 : 0))
            .accessibilityHidden(true)
    }
}

/// A check mark, short stroke then long, in a square centred a little low in its box.
struct NWCheckShape: Shape {
    func path(in r: CGRect) -> Path {
        let side = min(r.width, r.height) * 0.78
        let o = CGPoint(x: r.midX - side / 2, y: r.midY - side / 2 + r.height * 0.04)
        var p = Path()
        p.move(to: CGPoint(x: o.x + side * 0.08, y: o.y + side * 0.55))
        p.addLine(to: CGPoint(x: o.x + side * 0.38, y: o.y + side * 0.86))
        p.addLine(to: CGPoint(x: o.x + side * 0.94, y: o.y + side * 0.16))
        return p
    }
}
