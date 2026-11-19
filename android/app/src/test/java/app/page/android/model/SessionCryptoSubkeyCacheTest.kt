package app.page.android.model

import java.util.concurrent.Callable
import java.util.concurrent.Executors
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** The HKDF subkey is derived once per key, and the cached key is the very key the vector fixes. */
class SessionCryptoSubkeyCacheTest {
    private val root = ByteArray(32) { it.toByte() }

    @Test
    fun cachedKeyIsTheDerivedKey() {
        for (d in SessionCrypto.Direction.entries) {
            assertArrayEquals(SessionCrypto.subkey(root, d), SessionCrypto.subkeySpec(root, d).encoded)
        }
        assertEquals("ofSfPY2KtPqbs29ecqGVJzfSrP61BvMETQTitpTwtYE", Base64Url.encode(SessionCrypto.subkeySpec(root, SessionCrypto.Direction.MAC_TO_PHONE).encoded))
        assertEquals("s_XovkSs3InwR9tqHVrGlT_dVvTJeDPPtd0r-wC1qp4", Base64Url.encode(SessionCrypto.subkeySpec(root, SessionCrypto.Direction.PHONE_TO_MAC).encoded))
    }

    @Test
    fun sameRootContentGivesTheCachedKeyAndAnotherRootGivesAnother() {
        val first = SessionCrypto.subkeySpec(root, SessionCrypto.Direction.MAC_TO_PHONE)
        // A different array with the same bytes (a reloaded key) hits the cache.
        assertSame(first, SessionCrypto.subkeySpec(root.copyOf(), SessionCrypto.Direction.MAC_TO_PHONE))
        // The directions never share a key.
        assertNotEquals(first.encoded.toList(), SessionCrypto.subkeySpec(root, SessionCrypto.Direction.PHONE_TO_MAC).encoded.toList())
        // A new pairing's key derives afresh, and when the old one comes back it derives again, to the same bytes.
        val other = ByteArray(32) { (it + 1).toByte() }
        val otherKey = SessionCrypto.subkeySpec(other, SessionCrypto.Direction.MAC_TO_PHONE)
        assertNotEquals(first.encoded.toList(), otherKey.encoded.toList())
        assertArrayEquals(first.encoded, SessionCrypto.subkeySpec(root, SessionCrypto.Direction.MAC_TO_PHONE).encoded)
    }

    @Test
    fun mutatingTheCallersRootDoesNotChangeTheCache() {
        val mine = root.copyOf()
        val key = SessionCrypto.subkeySpec(mine, SessionCrypto.Direction.MAC_TO_PHONE).encoded.copyOf()
        mine[0] = 99
        // The cache keeps its own copy of the root: the mutated array is a different key, the original still hits.
        assertArrayEquals(key, SessionCrypto.subkeySpec(root, SessionCrypto.Direction.MAC_TO_PHONE).encoded)
        assertNotEquals(key.toList(), SessionCrypto.subkeySpec(mine, SessionCrypto.Direction.MAC_TO_PHONE).encoded.toList())
    }

    @Test
    fun framesStillOpenFromManyThreadsWhileTheKeyChanges() {
        val roots = listOf(root, ByteArray(32) { (it * 3).toByte() })
        val sealed = roots.map { r -> SessionCrypto.seal("hello".toByteArray(), r, SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE) }
        val pool = Executors.newFixedThreadPool(8)
        try {
            val jobs = (0 until 400).map { i ->
                Callable {
                    val k = i % 2
                    val out = SessionCrypto.open(sealed[k], roots[k], SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE)
                    assertNotNull("frame $i", out)
                    assertTrue(out!!.contentEquals("hello".toByteArray()))
                    // And the wrong key never opens it.
                    assertEquals(null, SessionCrypto.open(sealed[k], roots[1 - k], SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE))
                }
            }
            pool.invokeAll(jobs).forEach { it.get() }
        } finally {
            pool.shutdownNow()
        }
    }
}
