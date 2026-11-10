package app.page.android.ui.nw.budget

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.NowStore
import app.page.android.data.SessionStore
import app.page.android.model.BudgetSaveStatus
import app.page.android.model.BudgetSheetModel

/**
 * The budget sheet, live: Save is the `budget` op ([SessionStore.saveBudget]); the sheet shows "Saving..." and keeps the old
 * value until the Mac answers, closes on its word, and says why when it refuses (an offline Mac: "Your Mac is offline -
 * the budget wasn't changed."). Cancel, the scrim and back close it without sending anything. (iOS BudgetSheetContainer.)
 */
@Composable
fun BudgetSheetContainer(model: BudgetSheetModel, modifier: Modifier = Modifier) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    // Only this sheet's own change: another sheet's answer is not read here.
    val status = if (state.budgetFor == model.id) state.budgetSave else BudgetSaveStatus.Idle
    LaunchedEffect(status) { if (status == BudgetSaveStatus.Saved) AppRouter.closeBudget() }
    NWBudgetSheet(
        model, NowStore.zone, status, onSave = { SessionStore.saveBudget(model, it) }, onCancel = AppRouter::closeBudget, modifier = modifier,
    )
}
