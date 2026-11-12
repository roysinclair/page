import SwiftUI
@testable import PageCore

// The budget row on a session card in the menu-bar panel, and the editor that
// opens inside the card (Designs/budget-caps.md §6). It sits under Open and
// Steer on the In-flight cards and the finished-turn rows. All state lives in
// `NowStore`; Save goes through the same Coordinator path as Page Studio's
// steppers and the phone's `budget` op. Amber and teal only, never red.

/// A card's budget slot: the slim line, and the editor when it is open here.
struct NWBudgetSlot: View {
    @ObservedObject var store: NowStore
    var rowId: String
    var sessionId: String
    var backend: AgentBackendID?

    private var editor: BudgetEditor? {
        guard let e = store.budgetEditor, e.rowId == rowId else { return nil }
        return e
    }

    var body: some View {
        if let line = store.budgetLine(sessionId: sessionId, backend: backend) {
            VStack(alignment: .leading, spacing: 8) {
                NWBudgetLineView(line: line, open: editor != nil) {
                    store.clickSetBudget(rowId: rowId, sessionId: sessionId, backend: backend)
                }
                if let e = editor {
                    NWBudgetEditorView(store: store, editor: e)
                }
            }
        }
    }
}

/// "BUDGET ▮▮▮▯ 21% of 25%      [Set budget]". With usage capture off, only the label and the button.
struct NWBudgetLineView: View {
    var line: NowBudgetLine
    var open: Bool
    var onSet: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            // One word, never wrapped: the bar and the numbers give way first.
            Text("BUDGET").nwLabel().lineLimit(1).fixedSize()
            if line.captureOn {
                // While measuring there is nothing to fill: no bar (as on the Budget page), and the words get its room,
                // which "Measuring · 64% of work" needs.
                if !line.measuring {
                    NWBudgetBoardBar(fraction: line.fraction, warm: line.warm, hasBudget: line.hasBudget)
                        .frame(width: 64)
                }
                Text(line.text)
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor((line.warm ? NightWatch.Palette.amber : NightWatch.Palette.textSecondary).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help(line.help ?? "")
            }
            Spacer(minLength: 4)
            NWActionButton(title: "Set budget", emphasised: open,
                           help: line.captureOn ? "Set a budget for this project or just this session"
                                                : "Usage tracking is off: see how to turn it on") { onSet() }
                // The button keeps its words; the detail line gives way first.
                .fixedSize()
                .layoutPriority(2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(line.accessibilityText))
        .accessibilityHint(Text(line.help ?? ""))
    }
}

/// The inline editor: project or this session, a percent, what Page will do, Save and Cancel.
struct NWBudgetEditorView: View {
    @ObservedObject var store: NowStore
    var editor: BudgetEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if editor.captureOff {
                Text(BudgetCopy.captureOff)
                    .font(NightWatch.Typo.monoSmall)
                    .foregroundColor(NightWatch.Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    NWActionButton(title: "Close", help: "Close · Esc") { store.cancelBudgetEditor() }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach([BudgetEditor.Scope.project, .session], id: \.rawValue) { scope in
                        NWBudgetChoice(title: scope.title, selected: editor.scope == scope,
                                       help: scope == .project ? "One budget for every session in \(editor.projectName)"
                                                               : "A budget for this session only") {
                            store.setBudgetScope(scope)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    ForEach(Array(BudgetPercent.presets.enumerated()), id: \.offset) { _, preset in
                        NWBudgetChoice(title: preset.map(String.init) ?? "Off", selected: editor.value == preset,
                                       help: preset == nil ? "No budget" : "\(preset!)% of the week", minWidth: 36) {
                            store.setBudgetValue(preset)
                        }
                    }
                    Spacer(minLength: 4)
                    NWBudgetStepper(value: editor.value, placeholder: "Off") { store.setBudgetValue($0) }
                }
                Text(editor.preview(timeZone: store.timeZone))
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    NWActionButton(title: "Cancel", help: "Close without saving · Esc") { store.cancelBudgetEditor() }
                    NWActionButton(title: "Save", enabled: editor.changed, emphasised: true,
                                   help: "Save the budget · Return") { store.saveBudget() }
                }
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

/// One choice of a small group (a scope, a preset): as tall as Open and Steer, teal when chosen.
struct NWBudgetChoice: View {
    var title: String
    var selected: Bool
    var help: String
    var minWidth: CGFloat = 0
    var action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: NightWatch.Radius.keycap + 1, style: .continuous) }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundColor((selected ? NightWatch.Palette.teal : NightWatch.Palette.textPrimary).opacity(selected ? 1 : 0.92).color)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minWidth, minHeight: 28)
                .background(shape.fill(selected ? NightWatch.Palette.teal.opacity(0.14).color : Color.white.opacity(0.08)))
                .overlay(shape.strokeBorder(selected ? NightWatch.Palette.teal.opacity(0.6).color : Color.white.opacity(0.10), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
