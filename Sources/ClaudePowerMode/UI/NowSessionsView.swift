import SwiftUI
@testable import PageCore

// The sessions that are not working, in the Now panel (Designs/panel-sessions.md): the IDLE
// group, the × and the swipe that put a finished or idle card away, and the status line with
// its Undo. All state lives in `NowStore`; the cards themselves are `NWInFlightRowView` (idle)
// and `NWDecideRowView` (a finished turn), so every kind of session reads as one card.
// Amber and teal, never red.

// MARK: - The IDLE group

/// Sessions at their prompt: a header like In flight's with a quiet dot, the first three cards,
/// and "Show all N". Shows even when nothing is in flight, and while only dismissed sessions
/// are left (so they can be brought back).
struct NWIdleGroup: View {
    @ObservedObject var store: NowStore
    /// The tallest the cards may be before they scroll (the popover must fit the screen).
    var maxCardsHeight: CGFloat = 640

    var body: some View {
        let rows = store.idleRows
        let collapsed = store.state.idleCollapsed
        let layout = InFlightLayout.visible(rows, collapsed: collapsed, expanded: store.state.idleExpanded)
        VStack(alignment: .leading, spacing: 8) {
            header(rows: rows, collapsed: collapsed)
            if !collapsed {
                NWIdleCards(store: store, rows: layout.shown, maxHeight: maxCardsHeight)
                if layout.more > 0 {
                    Button { store.setIdleExpanded(true) } label: {
                        Text(InFlightLayout.showAllTitle(total: rows.count))
                            .font(Font.system(size: 11.5, weight: .medium))
                            .foregroundColor(NightWatch.Palette.teal.color)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Show all \(rows.count) idle sessions"))
                } else if store.state.idleExpanded && rows.count > InFlightLayout.cap {
                    Button { store.setIdleExpanded(false) } label: {
                        Text("Show fewer")
                            .font(Font.system(size: 11.5, weight: .medium))
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .id(IdleGroup.anchorId)
    }

    private func header(rows: [InFlightRow], collapsed: Bool) -> some View {
        HStack(spacing: 8) {
            Button { store.setIdleCollapsed(!collapsed) } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(Font.system(size: 8, weight: .bold))
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(width: 10)
                    Circle().fill(NightWatch.Palette.textQuiet.color).frame(width: 6, height: 6)
                    Text(IdleGroup.title(count: rows.count).uppercased()).nwLabel()
                    if collapsed {
                        Text(InFlightLayout.names(rows))
                            .font(NightWatch.Typo.monoMicro)
                            .foregroundColor(NightWatch.Palette.textSecondary.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the idle sessions" : "Hide the idle sessions")
            .accessibilityLabel(Text("\(IdleGroup.title(count: rows.count)), \(collapsed ? "collapsed" : "expanded")"))
            .accessibilityHint(Text("Shows or hides the sessions waiting at their prompt"))
            if store.dismissedCount > 0 {
                Button { store.restoreDismissed() } label: {
                    Text(IdleGroup.dismissedTitle(count: store.dismissedCount))
                        .font(Font.system(size: 11, weight: .medium))
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Bring the dismissed sessions back")
                .accessibilityLabel(Text("Show \(store.dismissedCount) dismissed sessions"))
            }
        }
    }
}

/// The idle cards, in a scroller that only scrolls once they outgrow the room they have. When a
/// card is dismissed, the ones below glide up into its place (its own gap list: it never moves
/// a decision row or an In-flight card).
struct NWIdleCards: View {
    @ObservedObject var store: NowStore
    var rows: [InFlightRow]
    var maxHeight: CGFloat
    /// Each card's height, so a card that left can say how far the rest glide.
    @State private var heights: [String: CGFloat] = [:]

    var body: some View {
        let gaps = store.motion.cardGaps.filter { $0.group == .idle }
        NWOneShot(start: gaps.map(\.at).min(), duration: NowMotion.gapDuration + 0.02) { now in
            NWCardScroll(maxHeight: maxHeight, onResize: { store.cardsResized() }) {
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        NWInFlightRowView(store: store, row: row)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: NWCardHeightsKey.self, value: [row.id: g.size.height])
                            })
                            .offset(y: NWCardGapShift.shift(forIndex: index, gaps: gaps, heights: heights, now: now))
                            .transition(.opacity)
                    }
                }
                .padding(.trailing, 1)
            }
        }
        .onPreferenceChange(NWCardHeightsKey.self) { found in
            var all = heights
            for (k, v) in found { all[k] = v }
            if all != heights { heights = all }
        }
    }
}

/// A vertical scroller exactly as tall as its content, up to `maxHeight`, and scrolling past that. A
/// bare ScrollView is greedy: with two of them in the panel (In flight, IDLE) the stack hands each an
/// equal share of the height, so one would be cut off and the other left with blank space. The height
/// is measured, so each takes what it needs; `onResize` tells the panel to fit its window again.
struct NWCardScroll<Content: View>: View {
    var maxHeight: CGFloat
    var onResize: () -> Void = {}
    @ViewBuilder var content: () -> Content
    @State private var measured: CGFloat = 0

    var body: some View {
        let scroller = ScrollView(.vertical, showsIndicators: true) {
            content().background(GeometryReader { g in
                Color.clear.preference(key: NWContentHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(NWContentHeightKey.self) { h in
            guard abs(h - measured) > 0.5 else { return }
            measured = h
            DispatchQueue.main.async { onResize() }
        }
        if measured > 0 {
            scroller.frame(height: min(measured, maxHeight))
        } else {
            scroller.frame(maxHeight: maxHeight)
        }
    }
}

struct NWContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct NWCardHeightsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

enum NWCardGapShift {
    /// Pure. Where a card is drawn relative to its place: cards below one that left start one card
    /// height (and the gap between them) down and glide up.
    static func shift(forIndex index: Int, gaps: [NowMotion.CardGap], heights: [String: CGFloat], now: Date) -> CGFloat {
        var dy: CGFloat = 0
        for g in gaps where index >= g.index {
            let h = (heights[g.rowId] ?? 120) + 8
            let u = MotionCurve.easeOut(now.timeIntervalSince(g.at) / NowMotion.gapDuration)
            dy += h * CGFloat(1 - u)
        }
        return dy
    }
}

// MARK: - Swipe

/// Wraps a card so a finished or idle one can be swiped sideways (a mouse drag; the trackpad's two-finger
/// swipe is the panel controller's) and put away. The card follows the finger; behind it, on the side it
/// uncovers, a label says what lifting the finger will do: "Dismiss" (teal), or with the setting on,
/// "Dismiss · close tab" (amber). Only a dismissable card takes the gesture, and it is horizontal only,
/// so a tap on the card (to open it) and a click on its buttons work as before. (VoiceOver's "Dismiss"
/// action is on the cards themselves, where VoiceOver focuses.)
struct NWSwipeCard<Content: View>: View {
    @ObservedObject var store: NowStore
    var rowId: String
    /// The kind of card can be dismissed at all (a finished or idle one): fixed for the card, so its
    /// identity never changes. Whether it can be right now (its reply is not on its way) masks the gesture.
    var enabled = true
    @ViewBuilder var content: () -> Content
    @State private var dragging = false
    @State private var last: (x: Double, at: Date)?
    @State private var velocity = 0.0

    private var offset: Double {
        guard let s = store.swipe, s.rowId == rowId else { return 0 }
        return s.offset
    }

    var body: some View {
        if enabled {
            ZStack {
                if offset != 0 { backdrop }
                content().offset(x: CGFloat(offset))
            }
            .onHover { store.setHover(rowId, inside: $0) }
            // Masked off while the card cannot be dismissed (its reply is on its way).
            .highPriorityGesture(drag, including: store.canDismiss(rowId) ? .all : .subviews)
        } else {
            content()
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                let x = Double(v.translation.width)
                if !dragging {
                    // Horizontal only: a mostly vertical drag is not ours.
                    guard abs(v.translation.width) > abs(v.translation.height), store.swipeBegan(rowId: rowId) else { return }
                    dragging = true
                }
                if let l = last { velocity = SwipeDismissModel.velocity(delta: x - l.x, seconds: v.time.timeIntervalSince(l.at)) }
                last = (x, v.time)
                store.swipeMoved(rowId: rowId, offset: x)
            }
            .onEnded { v in
                guard dragging else { return }
                dragging = false
                let speed = velocity
                last = nil
                velocity = 0
                store.swipeEnded(rowId: rowId, offset: Double(v.translation.width), velocity: speed)
            }
    }

    /// The label on the side the card uncovers.
    private var backdrop: some View {
        NWSwipeLabel(offset: offset, progress: SwipeDismissModel.progress(offset: offset, width: store.cardWidth),
                     text: store.swipeLabel, closesTerminal: store.dismissClosesTerminal)
    }
}

/// "✕ Dismiss" in the strip a swiping card uncovers: teal, or amber with "Dismiss · close tab".
struct NWSwipeLabel: View {
    var offset: Double
    var progress: Double
    var text: String
    var closesTerminal: Bool

    var body: some View {
        let tint = closesTerminal ? NightWatch.Palette.amber : NightWatch.Palette.teal
        let shape = RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
        ZStack(alignment: offset > 0 ? .leading : .trailing) {
            Color.clear
            HStack(spacing: 7) {
                Image(systemName: "xmark")
                    .font(Font.system(size: 10.5, weight: .bold))
                // "Dismiss · close tab" stacks on two lines, so it fits the strip at 120 pt.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(text.components(separatedBy: " · ").enumerated()), id: \.offset) { n, line in
                        Text(line)
                            .font(Font.system(size: n == 0 ? 12 : 10.5, weight: n == 0 ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .foregroundColor(tint.opacity(0.55 + 0.45 * progress).color)
            .padding(.horizontal, 14)
            .frame(width: CGFloat(abs(offset)), alignment: offset > 0 ? .leading : .trailing)
            .frame(maxHeight: .infinity)
            .background(shape.fill(tint.opacity(0.07 + 0.08 * progress).color))
            .clipShape(shape)
        }
        .accessibilityHidden(true)
    }
}

/// VoiceOver's "Dismiss" among a card's actions, on the element VoiceOver focuses. nil (a card that
/// can't be dismissed) adds nothing.
struct NWDismissAction: ViewModifier {
    var perform: (() -> Void)?

    func body(content: Content) -> some View {
        if let perform {
            content.accessibilityAction(named: Text(DismissCopy.accessibilityAction), perform)
        } else {
            content
        }
    }
}

extension View {
    func nwDismissAction(_ perform: (() -> Void)?) -> some View { modifier(NWDismissAction(perform: perform)) }
}

// MARK: - ×

/// The × after the chip on a finished or idle card: 22 by 22, quiet until the pointer is on it or the
/// card is selected. Its tooltip says what it does, "also closes its cmux tab" included when the
/// setting is on.
struct NWDismissButton: View {
    @ObservedObject var store: NowStore
    var rowId: String
    var project: String
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        Button { store.dismiss(rowId: rowId) } label: {
            Image(systemName: "xmark")
                .font(Font.system(size: 9.5, weight: .bold))
                .foregroundColor((hovering || selected ? NightWatch.Palette.textSecondary : NightWatch.Palette.textQuiet).color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(store.dismissHelp(forRowId: rowId))
        .accessibilityLabel(Text("Dismiss \(project)"))
    }
}

// MARK: - Status line

/// "Dismissed payments-api · Undo", or with the setting on "Closing payments-api's cmux tab in 5s · Undo":
/// the status line for the five seconds the dismissal can be taken back.
struct NWDismissLine: View {
    @ObservedObject var store: NowStore
    var pending: PendingDismissal

    var body: some View {
        // A coarse timeline: the seconds count down, nothing else moves.
        TimelineView(.periodic(from: store.now(), by: 0.5)) { _ in
            NWReceiptLine(text: pending.line(now: store.now()), failed: false, symbol: "arrow.uturn.backward.square",
                          actionTitle: DismissCopy.undoTitle) { store.undoDismissal() }
        }
    }
}
