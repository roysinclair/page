package app.page.android.model

// A reply to a page that the Mac refused because the session's input box holds text (`reply.injected` `reason:
// draft`): what the phone learns about that text (`peekDraft`), what it says, and the one button that follows. The
// draft text never travels in `reply.injected` (the relay sees it); it only ever comes back over the sealed sessions
// channel. Mirrors the room's "Clear it and send" (SessionStore.clearDraftAndSend). Pure, so it is unit-tested.

/** Where the unsent-text recovery for one failed reply stands. [draft] is only ever the text the Mac read. */
sealed interface ReplyDraftRecovery {
    /** `peekDraft` is out and unanswered. */
    data object Asking : ReplyDraftRecovery

    /** Nothing more is known (no answer, no text readable, another refusal): the copy stays, with no button. */
    data object Unknown : ReplyDraftRecovery

    /** The Mac read [draft] in the box: "Clear it and send". [clearing]: its `clearDraft` is out. */
    data class Typed(val draft: String, val clearing: Boolean = false) : ReplyDraftRecovery

    /** The box is clear: "Send again". */
    data object Clear : ReplyDraftRecovery

    /** The Mac answered a `clearDraft` with news of its own (Page's sentence for it); no button. */
    data class Problem(val message: String) : ReplyDraftRecovery
}

object ReplyDraft {
    const val REASON_DRAFT = "draft"
    const val REASON_INPUT_UNVERIFIED = "input_unverified"

    const val UNSENT_COPY = "There's unsent text in the session's input box on your Mac."
    const val CLEAR_COPY = "The input box on your Mac is clear now."
    const val NO_CLEAR_CONFIRM = "Your Mac didn't confirm clearing the input box, so your message wasn't sent. Check the session on your Mac, then try again."
    const val CLEAR_AND_SEND_SPOKEN = "Clear the text in the input box on your Mac and send your message"

    /**
     * Page's sentence for a failed reply's `reason`, so the Mac's raw detail ("You have a half-typed message in that
     * pane") is never shown. null for a reason Page doesn't know (the Mac's own detail is then used, as before).
     */
    fun failureCopy(reason: String?): String? = when (reason) {
        REASON_DRAFT -> UNSENT_COPY
        REASON_INPUT_UNVERIFIED -> SessionResultCopy.refusal(REASON_INPUT_UNVERIFIED, null, "Claude")
        else -> null
    }

    /** What the Mac's answer to a `peekDraft` makes of the recovery. */
    fun afterPeek(result: CommandResult?): ReplyDraftRecovery = when {
        result == null -> ReplyDraftRecovery.Unknown
        result.code == CommandResult.Code.REFUSED && result.reason == REASON_DRAFT ->
            result.draft?.let { ReplyDraftRecovery.Typed(it) } ?: ReplyDraftRecovery.Unknown
        result.ok && result.code == CommandResult.Code.DELIVERED -> ReplyDraftRecovery.Clear
        else -> ReplyDraftRecovery.Unknown
    }

    /** What the Mac's answer to the `clearDraft` after "Clear it and send" makes of the recovery; null: it is clear, send the reply again. */
    fun afterClear(result: CommandResult?, agent: String): ReplyDraftRecovery? = when {
        result == null -> ReplyDraftRecovery.Problem(NO_CLEAR_CONFIRM)
        result.ok && result.code == CommandResult.Code.DELIVERED -> null
        // Text again (maybe other text): the same offer, with what is there now.
        result.code == CommandResult.Code.REFUSED && result.reason == REASON_DRAFT && result.draft != null -> ReplyDraftRecovery.Typed(result.draft)
        result.code == CommandResult.Code.REFUSED -> ReplyDraftRecovery.Problem(SessionResultCopy.refusal(result.reason, result.detail, agent, result.draft))
        else -> ReplyDraftRecovery.Problem(SessionResultCopy.failure(result.reason, result.detail))
    }

    /** The sentence under a failed reply, from what the recovery has learned. */
    fun copy(recovery: ReplyDraftRecovery?): String? = when (recovery) {
        null, ReplyDraftRecovery.Asking, ReplyDraftRecovery.Unknown -> null
        is ReplyDraftRecovery.Typed -> "There's “${SessionResultCopy.shownDraft(recovery.draft)}” typed in the session's input box on your Mac."
        ReplyDraftRecovery.Clear -> CLEAR_COPY
        is ReplyDraftRecovery.Problem -> recovery.message
    }

    /** The one button under a failed reply: its words, what TalkBack says, and whether it can be tapped. */
    data class Action(val kind: Kind, val label: String, val spoken: String?, val enabled: Boolean) {
        enum class Kind { CLEAR_AND_SEND, SEND_AGAIN }
    }

    /**
     * The delivery as the sheet shows it: a `draft` failure says what the recovery has learned. [recovery] is only
     * looked at for that failure; any other delivery is returned as it is. Pure.
     */
    fun shown(delivery: ReplyDelivery?, recovery: ReplyDraftRecovery?): ReplyDelivery? {
        if (delivery !is ReplyDelivery.Failed || delivery.reason != REASON_DRAFT) return delivery
        return copy(recovery)?.let { delivery.copy(message = it) } ?: delivery
    }

    /**
     * The button for a failed `draft` reply. "Send again" needs the reply to send ([canResend]); "Clear it and send"
     * needs it too, since it ends by sending it. null: copy only. Pure.
     */
    fun action(delivery: ReplyDelivery?, recovery: ReplyDraftRecovery?, canResend: Boolean): Action? {
        if (delivery !is ReplyDelivery.Failed || delivery.reason != REASON_DRAFT || !canResend) return null
        return when (recovery) {
            is ReplyDraftRecovery.Typed -> Action(Action.Kind.CLEAR_AND_SEND, "Clear it and send", CLEAR_AND_SEND_SPOKEN, enabled = !recovery.clearing)
            ReplyDraftRecovery.Clear -> Action(Action.Kind.SEND_AGAIN, "Send again", null, enabled = true)
            else -> null
        }
    }
}
