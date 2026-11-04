package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/NowBanners.swift. The problems the Now stream
// surfaces above everything else, and the session-availability copy Lanes shows
// when live sessions can't load. These are the inbox banners and the Sessions
// availability cards, as pure values. Android has no push provider, so the
// push banner and the other-Macs banners (one pairing only) are not here.

/** Whether Android lets Page notify you (mapped from `NotificationAccess.Authorization`). */
enum class NotificationsState {
    ALLOWED, OFF, NOT_SET, CHECKING;

    val text: String
        get() = when (this) {
            ALLOWED -> "Allowed"
            OFF -> "Off — you won't be paged"
            NOT_SET -> "Not set up yet"
            CHECKING -> "Checking…"
        }
}

/** "Connected", "Connecting…", "Reconnecting…" or "Offline — <why>". */
object RelayConnectionText {
    fun text(connected: Boolean, connecting: Boolean, failure: String?): String {
        if (connected) return "Connected"
        if (connecting) return "Connecting…"
        if (failure != null) return "Offline — $failure"
        return "Reconnecting…"
    }
}

data class NowBanner(
    val id: String,
    val tone: Tone,
    /** A semantic icon name (the views map it to an icon). */
    val symbol: String,
    val title: String,
    val message: String,
    val actionTitle: String?,
    val action: Action?,
) {
    enum class Tone { ERROR, WARNING, INFO }

    enum class Action {
        /** Unpair, then scan a new code on the Mac. */
        REPAIR,

        /** Pull the lists again. */
        RETRY,
        OPEN_NOTIFICATION_SETTINGS,
    }

    data class Inputs(
        val authRejected: Boolean,
        /** The inbox failed to load, with the relay's reason. */
        val inboxFailure: String?,
        val connected: Boolean,
        val presence: MacPresence,
        val notifications: NotificationsState,
        val now: Instant,
    )

    companion object {
        /** Most important first. Pure. */
        fun build(i: Inputs): List<NowBanner> {
            val out = ArrayList<NowBanner>()
            if (i.authRejected) {
                out.add(
                    NowBanner(
                        "auth", Tone.ERROR, "key.slash", "This pairing no longer works",
                        "Your relay rejected this phone's pairing token. The computer probably generated a new one. Unpair and scan the new code.",
                        "Re-pair…", Action.REPAIR,
                    ),
                )
            } else if (i.inboxFailure != null && !i.connected) {
                out.add(
                    NowBanner(
                        "relay", Tone.ERROR, "wifi.exclamationmark", "Can't reach your relay",
                        "${i.inboxFailure} The list may be out of date.", "Try again", Action.RETRY,
                    ),
                )
            } else {
                when (val p = i.presence) {
                    MacPresence.NeverConnected -> out.add(
                        NowBanner(
                            "never", Tone.ERROR, "key.slash", "Your computer hasn't connected with this pairing",
                            "The relay has never seen Page Studio on your computer use this pairing code, so no pages can reach this phone. If you regenerated the token on your computer, re-pair with the new code.",
                            "Re-pair…", Action.REPAIR,
                        ),
                    )
                    is MacPresence.Offline -> {
                        val repair = i.presence.suggestsRepair(i.now)
                        val last = p.lastSeen?.let { "Last seen ${RelativeTime.ago(it, i.now)}. " } ?: ""
                        out.add(
                            NowBanner(
                                "offline", Tone.WARNING, "desktopcomputer.trianglebadge.exclamationmark", "Your computer is offline",
                                last + "New pages can't reach you until Page Studio on your computer reconnects to the relay." +
                                    (if (repair) " If you regenerated the token on your computer, re-pair this phone." else ""),
                                if (repair) "Re-pair…" else null, if (repair) Action.REPAIR else null,
                            ),
                        )
                    }
                    is MacPresence.Stale -> out.add(
                        NowBanner(
                            "stale", Tone.WARNING, "desktopcomputer.trianglebadge.exclamationmark", "Your computer stopped checking in",
                            "Last heartbeat ${RelativeTime.ago(p.lastSeen, i.now)}. It may be asleep or busy; pages may be delayed.",
                            null, null,
                        ),
                    )
                    else -> Unit
                }
            }
            if (i.notifications == NotificationsState.OFF) {
                out.add(
                    NowBanner(
                        "notifications", Tone.WARNING, "bell.slash", "Notifications are off",
                        "You won't be paged while Page Relay is closed.", "Open Settings", Action.OPEN_NOTIFICATION_SETTINGS,
                    ),
                )
            }
            return out
        }
    }
}

/** What Lanes says when live sessions can't load, and the step that fixes it. */
data class SessionAvailabilityCopy(
    val systemImage: String,
    val tone: Tone,
    val title: String,
    val message: String,
    val actionTitle: String?,
    val action: Action?,
    /** For the status line. */
    val shortStatus: String,
) {
    enum class Action { REPAIR, RETRY }
    enum class Tone { WARNING, ERROR, INFO }

    companion object {
        fun of(availability: SessionAvailability): SessionAvailabilityCopy = when (availability) {
            SessionAvailability.RelayTooOld -> SessionAvailabilityCopy(
                "arrow.triangle.2.circlepath", Tone.WARNING, "Update your relay",
                "Your relay (the Cloudflare Worker) doesn't support live sessions yet. Redeploy it from the latest Page Studio release, then pull down to refresh. Pages keep working meanwhile.",
                "Check again", Action.RETRY, "Relay needs an update",
            )
            is SessionAvailability.NeedsRepair ->
                if (availability.keyMismatch) SessionAvailabilityCopy(
                    "key.slash", Tone.ERROR, "Re-pair with your computer",
                    "Live updates from your computer can't be unlocked with this phone's key, so the pairing was probably regenerated on your computer. Unpair, then on your computer open Page Studio → Pair phone… (on Linux, run paged pair) and scan the code.",
                    "Re-pair…", Action.REPAIR, "Pairing key changed",
                ) else SessionAvailabilityCopy(
                    "key", Tone.WARNING, "Re-pair with your computer to see live sessions",
                    "This pairing has no session key: it came from an older Page Studio on your computer, or was made before live sessions existed. Update Page Studio on your computer, unpair here, then open Page Studio → Pair phone… on your computer (on Linux, run paged pair) and scan the new code. Pages keep working meanwhile.",
                    "Re-pair…", Action.REPAIR, "Re-pair needed",
                )
            SessionAvailability.MacOffline -> SessionAvailabilityCopy(
                "desktopcomputer.trianglebadge.exclamationmark", Tone.WARNING, "Your computer is offline",
                "Live sessions show up while Page Studio on your computer is connected to the relay. Wake the computer, or check that Page Studio is running there.",
                "Try again", Action.RETRY, "Computer offline",
            )
            SessionAvailability.ClockSkew -> SessionAvailabilityCopy(
                "clock.badge.exclamationmark", Tone.WARNING, "Your clocks disagree",
                "Updates from your computer arrive more than 10 minutes old by this phone's clock, so they're ignored. Turn on automatic date and time on both your phone and your computer.",
                "Try again", Action.RETRY, "Clock mismatch",
            )
            SessionAvailability.MacTooOld -> SessionAvailabilityCopy(
                "arrow.down.app", Tone.WARNING, "Update Page Studio on your computer",
                "Your computer is online but isn't sending live sessions. Update Page Studio on your computer to the latest version, and check that remote sessions are turned on in its Preferences.",
                "Check again", Action.RETRY, "Computer needs an update",
            )
            SessionAvailability.MacDisabled -> SessionAvailabilityCopy(
                "eye.slash", Tone.WARNING, "Live sessions are off on your computer",
                "Page Studio on your computer isn't sharing its sessions. Turn them back on in Page Studio → Preferences → Phone on your computer.",
                "Check again", Action.RETRY, "Off on your computer",
            )
            SessionAvailability.Waiting -> SessionAvailabilityCopy("hourglass", Tone.INFO, "Connecting to your computer…", "", null, null, "Connecting…")
            SessionAvailability.Ready -> SessionAvailabilityCopy("checkmark.circle", Tone.INFO, "Live", "", null, null, "Live")
        }
    }
}
