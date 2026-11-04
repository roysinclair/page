package app.page.android.ui.sessions

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DesktopAccessDisabled
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.ui.graphics.vector.ImageVector
import app.page.android.model.SessionAvailability
import app.page.android.ui.components.BannerTone

/** What each availability state tells the user, and the step that fixes it. */
data class SessionAvailabilityCopy(
    val icon: ImageVector,
    val tone: BannerTone,
    val title: String,
    val message: String,
    val actionTitle: String?,
    val action: Action?,
    /** For the uppercase status line. */
    val shortStatus: String,
) {
    enum class Action { REPAIR, RETRY }

    companion object {
        fun of(availability: SessionAvailability): SessionAvailabilityCopy = when (availability) {
            SessionAvailability.RelayTooOld -> SessionAvailabilityCopy(
                Icons.Filled.Sync, BannerTone.WARNING, "Update your relay",
                "Your relay (the Cloudflare Worker) doesn't support live sessions yet. Redeploy it from the latest Page Studio release, then pull down to refresh. Pages keep working meanwhile.",
                "Check again", Action.RETRY, "Relay needs an update",
            )
            is SessionAvailability.NeedsRepair -> if (availability.keyMismatch) {
                SessionAvailabilityCopy(
                    Icons.Filled.KeyOff, BannerTone.ERROR, "Re-pair with your computer",
                    "Live updates from your computer can't be unlocked with this phone's key, so the pairing was probably regenerated on your computer. Unpair, then on your computer open Page Studio → Pair phone… (on Linux, run paged pair) and scan the code.",
                    "Re-pair…", Action.REPAIR, "Pairing key changed",
                )
            } else {
                SessionAvailabilityCopy(
                    Icons.Filled.Key, BannerTone.WARNING, "Re-pair with your computer to see live sessions",
                    "This pairing has no session key: it came from an older Page Studio on your computer, or was made before live sessions existed. Update Page Studio on your computer, unpair here, then open Page Studio → Pair phone… on your computer (on Linux, run paged pair) and scan the new code. Pages keep working meanwhile.",
                    "Re-pair…", Action.REPAIR, "Re-pair needed",
                )
            }
            SessionAvailability.MacOffline -> SessionAvailabilityCopy(
                Icons.Filled.DesktopAccessDisabled, BannerTone.WARNING, "Your computer is offline",
                "Live sessions show up while Page Studio on your computer is connected to the relay. Wake the computer, or check that Page Studio is running there.",
                "Try again", Action.RETRY, "Computer offline",
            )
            SessionAvailability.ClockSkew -> SessionAvailabilityCopy(
                Icons.Filled.Schedule, BannerTone.WARNING, "Your clocks disagree",
                "Updates from your computer arrive more than 10 minutes old by this phone's clock, so they're ignored. Turn on automatic date & time on both your phone and your computer.",
                "Try again", Action.RETRY, "Clock mismatch",
            )
            SessionAvailability.MacTooOld -> SessionAvailabilityCopy(
                Icons.Filled.SystemUpdate, BannerTone.WARNING, "Update Page Studio on your computer",
                "Your computer is online but isn't sending live sessions. Update Page Studio on your computer to the latest version, and check that remote sessions are turned on in its Preferences.",
                "Check again", Action.RETRY, "Computer needs an update",
            )
            SessionAvailability.MacDisabled -> SessionAvailabilityCopy(
                Icons.Filled.VisibilityOff, BannerTone.WARNING, "Live sessions are off on your computer",
                "Page Studio on your computer isn't sharing its sessions. Turn them back on in Page Studio → Preferences → Phone on your computer.",
                "Check again", Action.RETRY, "Off on your computer",
            )
            SessionAvailability.Waiting -> SessionAvailabilityCopy(
                Icons.Filled.HourglassEmpty, BannerTone.INFO, "Connecting to your computer…", "", null, null, "Connecting…",
            )
            SessionAvailability.Ready -> SessionAvailabilityCopy(
                Icons.Filled.CheckCircle, BannerTone.INFO, "Live", "", null, null, "Live",
            )
        }
    }
}
