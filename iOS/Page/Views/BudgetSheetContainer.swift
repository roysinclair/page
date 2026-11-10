import SwiftUI

/// The budget sheet, live (Designs/budget-caps.md §6): a project's budget, one session's, or the default.
/// Save sends the `budget` op through the encrypted command path (`SessionStore.saveBudget`); the picker keeps the
/// old value until the Mac answers, a refusal or an offline Mac says why under it, and an answer closes the sheet.
/// The list that follows echoes the new value everywhere else.
struct BudgetSheetContainer: View {
    let model: BudgetSheetModel

    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    /// The sheet's own height, so the detent is exactly the content (and the system sheet is never taller than it).
    @State private var contentHeight: CGFloat = 0

    private var status: BudgetSaveStatus { sessions.budgetSaves[model.id] ?? .idle }

    var body: some View {
        ScrollView {
            NWBudgetSheet(model: model, timeZone: .current, status: status,
                          onSave: { sessions.saveBudget(model, pct: $0) },
                          onCancel: { dismiss() })
                .background(GeometryReader { g in Color.clear.preference(key: BudgetSheetHeightKey.self, value: g.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(BudgetSheetHeightKey.self) { contentHeight = $0 }
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight), .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(NightWatch.Palette.surface.color)
        .preferredColorScheme(.dark)
        .onAppear { sessions.clearBudgetStatus(model.id) }
        .onDisappear { sessions.clearBudgetStatus(model.id) }
        // The Mac said yes: the value is saved there, and the list echoes it. Nothing is changed on this phone before that.
        .onChange(of: status) { _, now in
            if now == .saved { dismiss() }
            // A change that didn't go is said aloud as it appears, since nothing else moves.
            if let why = now.failure { AccessibilityNotification.Announcement(why).post() }
        }
    }
}

private struct BudgetSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
