package app.page.android.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * The socket's events, applied one after another in the order they arrived, with the slow part of each (parsing and
 * decrypting a frame) done on [workers] instead of the thread the events are applied on (the main thread).
 *
 * Every event is [post]ed from the socket's thread. A message's `prepare` starts at once on [workers], so frames
 * decrypt side by side; its `apply` runs on [consumer]'s thread, and never before the `apply` of every event posted
 * before it, whether that event had a `prepare` or not. So a frame can never overtake the socket opening before it or
 * the socket ending after it, however long each one's `prepare` takes.
 *
 * `prepare` must not touch state the apply side owns: it gets what it needs captured. If it throws, `apply` gets null
 * and does the work the long way.
 */
internal class OrderedInbound<P : Any>(private val consumer: CoroutineScope, private val workers: CoroutineScope) {
    private class Item<P : Any>(val prepared: Deferred<P?>?, val apply: (P?) -> Unit)

    private val channel = Channel<Item<P>>(Channel.UNLIMITED)

    // Started by the first event, not at construction, so nothing is launched until the socket is used.
    private val loop = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        consumer.launch { for (item in channel) item.apply(item.prepared?.await()) }
    }

    /** An event with nothing to prepare. */
    fun post(apply: () -> Unit) {
        loop.value
        channel.trySend(Item(null) { apply() })
    }

    /** An event whose [prepare] runs on the workers while the events before it are applied. */
    fun post(prepare: () -> P?, apply: (P?) -> Unit) {
        loop.value
        val prepared = workers.async(start = CoroutineStart.DEFAULT) { try { prepare() } catch (_: Exception) { null } }
        channel.trySend(Item(prepared, apply))
    }
}
