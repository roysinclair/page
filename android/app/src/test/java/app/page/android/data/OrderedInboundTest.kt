package app.page.android.data

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.Executors
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The socket's events are applied in the order they arrived, on the consumer's thread, however long each frame takes to decode. */
class OrderedInboundTest {
    private val mainExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "fake-main") }
    private val consumer = CoroutineScope(SupervisorJob() + mainExecutor.asCoroutineDispatcher())
    private val workers = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val inbound = OrderedInbound<Int>(consumer, workers)

    @After
    fun tearDown() {
        mainExecutor.shutdownNow()
    }

    @Test
    fun framesAreAppliedInPostingOrderWhateverTheirDecodeTimes() {
        val n = 200
        val applied = Collections.synchronizedList(ArrayList<String>())
        val threads = Collections.synchronizedSet(HashSet<String>())
        val done = CountDownLatch(n)
        val rnd = java.util.Random(7)
        val expected = ArrayList<String>()
        for (i in 0 until n) {
            // Every 5th event is a plain one (the socket opening or ending); the rest are frames with a decode of 0 to 6 ms,
            // the early ones slower than the late ones.
            if (i % 5 == 0) {
                expected += "event$i"
                inbound.post { applied += "event$i"; threads += Thread.currentThread().name.substringBefore(" @"); done.countDown() }
            } else {
                val ms = rnd.nextInt(7).toLong() + if (i < 20) 5 else 0
                expected += "frame$i"
                inbound.post(prepare = { Thread.sleep(ms); i }) { p -> applied += "frame$p"; threads += Thread.currentThread().name.substringBefore(" @"); done.countDown() }
            }
        }
        assertTrue("all applied", done.await(20, TimeUnit.SECONDS))
        assertEquals(expected, applied.toList())
        assertEquals("applied only on the consumer's thread", setOf("fake-main"), threads.toSet())
    }

    @Test
    fun decodingRunsOffTheConsumerThread() {
        val done = CountDownLatch(1)
        var decodedOn = ""
        inbound.post(prepare = { decodedOn = Thread.currentThread().name; 1 }) { done.countDown() }
        assertTrue(done.await(10, TimeUnit.SECONDS))
        assertNotEquals("fake-main", decodedOn)
    }

    @Test
    fun aDecodeThatThrowsHandsApplyNullAndLaterFramesStillFollow() {
        val applied = Collections.synchronizedList(ArrayList<Int?>())
        val done = CountDownLatch(3)
        inbound.post(prepare = { 1 }) { applied += it; done.countDown() }
        inbound.post(prepare = { error("bad frame") }) { applied += it; done.countDown() }
        inbound.post(prepare = { 3 }) { applied += it; done.countDown() }
        assertTrue(done.await(10, TimeUnit.SECONDS))
        assertEquals(listOf(1, null, 3), applied.toList())
    }
}
