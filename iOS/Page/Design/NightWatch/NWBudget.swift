import SwiftUI

// Budget caps (Designs/budget-caps.md): the bar, the percent picker, the
// Budget list's rows, the sheet that sets a budget, and the card a stopped
// project sends. Amber and teal only: red stays Irreversible's.

private extension BudgetMeter.Tone {
    var color: NightWatch.RGBA {
        switch self {
        case .quiet: return NightWatch.Palette.sky.mixed(with: NightWatch.Palette.textTertiary, 0.55)
        case .calm: return NightWatch.Palette.teal
        case .warm: return NightWatch.Palette.amber
        }
    }
}

/// A budget as a bar: the fill is what is used (against the budget, full when
/// Page stops it; against the whole week with no budget), the tick is where Page warns.
struct NWBudgetBar: View {
    var meter: BudgetMeter
    var height: CGFloat = 8
    var onJewel = false

    var body: some View {
        let tone = meter.tone.color
        GeometryReader { g in
            let w = g.size.width
            let fill = meter.fraction > 0 ? max(height, w * meter.fraction) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(onJewel ? 0.2 : 0.09)).frame(height: height)
                Capsule()
                    .fill(LinearGradient(colors: [tone.mixed(with: .init(1, 1, 1), 0.28).color, tone.color], startPoint: .top, endPoint: .bottom))
                    .frame(width: fill, height: height)
                    .shadow(color: tone.opacity(meter.tone == .quiet ? 0 : 0.55).color, radius: 5)
                if let m = meter.warnMark {
                    Capsule().fill(Color.white.opacity(onJewel ? 0.9 : 0.75))
                        .frame(width: 2, height: height + 6)
                        .offset(x: w * m - 1)
                }
            }
            .frame(height: height + 6)
        }
        .frame(height: height + 6)
        .accessibilityHidden(true)
    }
}

/// The budget picker: the value large, − and + in steps of 5, and Off · 10 · 25 · 50.
struct NWPercentPicker: View {
    @Binding var value: Int?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                step("minus", label: "Less", enabled: value != nil) { value = BudgetPercent.down(value) }
                Text(BudgetPercent.text(value))
                    .font(NightWatch.Typo.hero.monospacedDigit())
                    .foregroundColor((value == nil ? NightWatch.Palette.textTertiary : NightWatch.Palette.textPrimary).color)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
                step("plus", label: "More", enabled: (value ?? 0) < 100) { value = BudgetPercent.up(value) }
            }
            NWSegmented(options: BudgetPercent.presets.map { (value: $0, label: BudgetPercent.text($0)) }, selection: $value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Budget"))
        .accessibilityValue(Text(value.map { "\($0) percent of the week" } ?? "Off"))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: value = BudgetPercent.up(value)
            case .decrement: value = BudgetPercent.down(value)
            @unknown default: break
            }
        }
    }

    private func step(_ symbol: String, label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy(duration: 0.2)) { action() } }) {
            Image(systemName: symbol).font(.system(.title3, weight: .bold)).frame(width: 30)
        }
        .frame(width: 84)
        .buttonStyle(NWButtonStyle(kind: .soft))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(label))
    }
}

/// One project in Budget: its colour, name, share and bar.
struct NWBudgetProjectRow: View {
    var project: BudgetProject
    var defaultCap: Int?
    var measuring = false
    var action: () -> Void = {}

    var body: some View {
        let cap = project.effectiveCap(default: defaultCap)
        // Early in the week nothing is stopped or near it, whatever the numbers say: they mean nothing yet.
        let stopped = project.state == .over && !measuring
        let meter = BudgetMeter(used: project.used, cap: cap, state: measuring ? .ok : project.state)
        let inherited = project.cap == nil && defaultCap != nil
        Button(action: action) {
            HStack(spacing: 14) {
                NWIconTile(symbol: stopped ? "pause.fill" : "folder.fill", jewel: .of(project.hue), size: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(NightWatch.Typo.name).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .lineLimit(1).truncationMode(.middle)
                    if !measuring { NWBudgetBar(meter: meter, height: 7) }
                    Text(measuring ? "Measuring…" : detail(meter, inherited: inherited))
                        .font(NightWatch.Typo.caption.monospacedDigit())
                        .foregroundColor((meter.tone == .warm ? NightWatch.Palette.amber : NightWatch.Palette.textTertiary).color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "chevron.right").font(.system(.caption, weight: .bold)).foregroundColor(NightWatch.Palette.textQuiet.color)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(meter.spoken(name: project.name)))
        .accessibilityHint(Text("Sets its budget"))
    }

    /// "26% of 25% · stopped"; "11% of 15% · default budget"; "2% · no budget".
    private func detail(_ m: BudgetMeter, inherited: Bool) -> String {
        if project.state == .over, !measuring { return m.line + " · stopped, raise it to carry on" }
        return m.line + (inherited ? " · default budget" : "")
    }
}

/// Budget's project list: every project with a share or a budget this week,
/// the default, and the one line that says it is an estimate.
struct NWBudgetProjects: View {
    var budget: MacBudget
    var timeZone: TimeZone
    var open: (BudgetSheetModel) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects this week").font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                Spacer()
                if let r = budget.resetsAt {
                    Text("resets \(BudgetCopy.resets(r, timeZone: timeZone))").font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

            if !budget.capture {
                note(BudgetCopy.captureOff)
            } else {
                if budget.measuring { note(BudgetCopy.measuring) }
                ForEach(budget.projects) { p in
                    NWBudgetProjectRow(project: p, defaultCap: budget.defaultCap, measuring: budget.measuring) {
                        open(.project(p, resetsAt: budget.resetsAt))
                    }
                    .id("budget-\(p.key)")
                }
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 72)
                Button {
                    open(.forDefault(budget))
                } label: {
                    HStack(spacing: 14) {
                        NWSoftTile(symbol: "slider.horizontal.3", tint: NightWatch.Palette.sky, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default for other projects").font(NightWatch.Typo.name).foregroundColor(NightWatch.Palette.textPrimary.color)
                            Text("Any project without a budget of its own").font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                        }
                        Spacer(minLength: 6)
                        Text(BudgetPercent.text(budget.defaultCap)).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.teal.color)
                        Image(systemName: "chevron.right").font(.system(.caption, weight: .bold)).foregroundColor(NightWatch.Palette.textQuiet.color)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                note(BudgetCopy.footnote)
            }
        }
        .id("budget-projects")
    }

    private func note(_ s: String) -> some View {
        Text(s).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// The sheet that sets a budget: the project's colour across the top, how much
/// it has used, the picker, and what Page will do, in words.
struct NWBudgetSheet: View {
    var model: BudgetSheetModel
    var timeZone: TimeZone = .current
    /// Where the change stands: the sheet keeps the old value until the Mac answers, and says why when it can't.
    var status: BudgetSaveStatus = .idle
    var onSave: (Int?) -> Void = { _ in }
    var onCancel: () -> Void = {}
    @State private var value: Int?

    init(model: BudgetSheetModel, timeZone: TimeZone = .current, status: BudgetSaveStatus = .idle,
         onSave: @escaping (Int?) -> Void = { _ in }, onCancel: @escaping () -> Void = {}) {
        self.model = model
        self.timeZone = timeZone
        self.status = status
        self.onSave = onSave
        self.onCancel = onCancel
        _value = State(initialValue: model.cap)
    }

    private var jewel: NWJewel { model.hue.map { NWJewel.of($0) } ?? NWJewel(JewelTone.sky.ramp) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                NWIconTile(symbol: symbol, jewel: jewel, size: 52, glass: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(NightWatch.Typo.sheetTitle).foregroundColor(.white).lineLimit(2).minimumScaleFactor(0.8)
                    Text(model.subtitle).font(NightWatch.Typo.caption).foregroundColor(Color.white.opacity(0.88))
                }
            }
            if let used = model.used {
                VStack(alignment: .leading, spacing: 6) {
                    NWBudgetBar(meter: BudgetMeter(used: used, cap: value), height: 10, onJewel: true)
                    Text(BudgetMeter(used: used, cap: value).line).font(NightWatch.Typo.captionStrong.monospacedDigit()).foregroundColor(Color.white.opacity(0.9))
                }
            }
            NWPercentPicker(value: $value)
                .disabled(status.isSaving)
            Text(model.preview(value, timeZone: timeZone))
                .font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let why = status.failure { failure(why) }
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel).buttonStyle(NWButtonStyle(kind: .quiet))
                Button(status.isSaving ? "Saving…" : "Save") { onSave(value) }
                    .buttonStyle(NWButtonStyle(kind: .bright))
                    .disabled(status.isSaving)
                    .opacity(status.isSaving ? 0.7 : 1)
            }
        }
        .padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 22)
        .background(alignment: .top) { NWBudgetSheetBackground(jewel: jewel) }
    }

    /// Why the change didn't go, in the Mac's words or Page's: amber (never red), with the old value still in force.
    private func failure(_ why: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(NightWatch.Palette.amber.color)
            Text(why).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.12).color))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch model.scope {
        case .project: return "folder.fill"
        case .session: return "person.crop.circle.badge.clock"
        case .defaultCap: return "slider.horizontal.3"
        }
    }
}

/// The sheet's surface: the project's jewel at the top, fading into raised navy.
private struct NWBudgetSheetBackground: View {
    var jewel: NWJewel
    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 34, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 34, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(NightWatch.Palette.surface.color)
            LinearGradient(stops: [.init(color: jewel.top.color, location: 0), .init(color: jewel.bottom.color, location: 0.55),
                                   .init(color: jewel.bottom.opacity(0).color, location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
            RadialGradient(colors: [jewel.light.opacity(jewel.lightStrength).color, jewel.light.opacity(0).color], center: .topLeading, startRadius: 0, endRadius: 300)
                .frame(height: 260)
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.3), Color.white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1)
        }
        .clipShape(shape)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// The card a budget page draws. Reached (Decide): an ember jewel, the bar
/// full, "Raise to 35%" and "Let this turn finish". Near it (Look): the Look
/// card's raised navy, the bar, and the raise.
struct NWBudgetCard: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    var onRaise: () -> Void = {}
    var onLetFinish: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}

    private var reached: Bool { row.section == .decide }
    private var meter: BudgetMeter? { row.budget?.meter(reached: reached) }

    var body: some View {
        if reached { reachedCard } else { warningCard }
    }

    private var reachedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 14) {
                    NWCardTopLine(row: row, now: now, onJewel: true)
                    HStack(alignment: .center, spacing: 12) {
                        NWIconTile(symbol: ChipKind.budget.symbol, jewel: .amber, size: 44, glass: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.headline).font(NightWatch.Typo.headline).foregroundColor(.white)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Text(row.summary).font(NightWatch.Typo.caption).foregroundColor(Color.white.opacity(0.9))
                        }
                    }
                    if let meter { NWBudgetBar(meter: meter, height: 10, onJewel: true) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the decision"))
            if outcome != .none {
                NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
            } else {
                HStack(spacing: 10) {
                    if let finish = row.action(.carryOn) { Button(finish.label, action: onLetFinish).buttonStyle(NWButtonStyle(kind: .glass)) }
                    if let raise = row.action(.approve) { Button(raise.label, action: onRaise).buttonStyle(NWButtonStyle(kind: .white)) }
                }
            }
        }
        .padding(NightWatch.Space.lg)
        .background(NWJewelSurface(jewel: .amber, lift: 1.25))
        .accessibilityElement(children: .contain)
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                NWIconTile(symbol: ChipKind.budget.symbol, jewel: .amber, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.headline).font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(2)
                    Text("\(row.summary) · \(row.waitingText(now: now))").font(NightWatch.Typo.caption)
                        .foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(2)
                }
                Spacer(minLength: 4)
            }
            if let meter { NWBudgetBar(meter: meter, height: 8) }
            if outcome != .none {
                NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
            } else if let raise = row.action(.approve) {
                Button(raise.label, action: onRaise).buttonStyle(NWButtonStyle(kind: .amber))
            }
        }
        .padding(NightWatch.Space.md)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, fill: NightWatch.Palette.surfaceRaised, tint: NightWatch.Palette.amber))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
    }
}
