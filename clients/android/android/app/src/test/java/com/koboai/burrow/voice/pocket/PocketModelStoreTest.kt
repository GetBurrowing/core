package com.koboai.burrow.voice.pocket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Serves fixed bytes per URL, honouring the offset as an HTTP Range would. */
class FakeFetcher(
    private val content: Map<String, ByteArray>,
) : PocketFetcher {
    val offsets = mutableListOf<Long>()

    /** Fails after writing this many bytes of the next fetch (an interrupted download). */
    var failAfter: Int? = null

    /** Called on every progress step, while the store is downloading. */
    var during: ((Long) -> Unit)? = null

    override fun fetch(
        url: String,
        staging: File,
        offset: Long,
        progress: (Long) -> Unit,
    ) {
        offsets.add(offset)
        val bytes = content.getValue(url.substringAfterLast('/'))
        val limit = failAfter?.let { minOf(bytes.size, offset.toInt() + it) } ?: bytes.size
        var written = offset
        java.io.FileOutputStream(staging, offset > 0).use { out ->
            for (start in offset.toInt() until limit step 4) {
                val end = minOf(start + 4, limit)
                out.write(bytes, start, end - start)
                written = end.toLong()
                progress(written)
                during?.invoke(written)
            }
        }
        if (failAfter != null && limit < bytes.size) {
            failAfter = null
            throw IOException("connection reset")
        }
    }
}

fun sha(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

@RunWith(RobolectricTestRunner::class)
class PocketModelStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private val a = ByteArray(40) { it.toByte() }
    private val b = ByteArray(24) { (100 + it).toByte() }
    private val files = listOf(PocketFile("a.tflite", 40, sha(a)), PocketFile("voices/b.bin", 24, sha(b)))
    private val fetcher = FakeFetcher(mapOf("a.tflite" to a, "b.bin" to b))
    private val states = mutableListOf<PocketModelState>()
    private var loads = 0

    private fun store(
        list: List<PocketFile> = files,
        loader: PocketLoader? = PocketLoader { loads++ },
    ) = PocketModelStore(tmp.root, list, fetcher, loader, { it.run() }, { it() }).also { s -> s.onChange = { states.add(it) } }

    @Test
    fun `a first use downloads every file, checks it, loads, and is ready`() {
        val store = store()
        assertEquals(PocketModelState.Absent, store.state)
        store.prepare()
        assertEquals(PocketModelState.Ready, store.state)
        assertTrue(a.contentEquals(File(tmp.root, "a.tflite").readBytes()))
        assertTrue(b.contentEquals(File(tmp.root, "voices/b.bin").readBytes()))
        assertEquals(1, loads)
        assertEquals(listOf("downloading", "compiling", "ready"), states.map { it.name }.distinct())
        assertEquals("ready", store.data().getString("state"))
        assertEquals(64L, store.data().getLong("received"))
        assertEquals(64L, store.data().getLong("total"))
        assertTrue(tmp.root.walkTopDown().none { it.name.endsWith(".part") })
    }

    @Test
    fun `a sha256 mismatch fails with checksum, and nothing is moved into place`() {
        val wrong = listOf(PocketFile("a.tflite", 40, sha(b)), files[1])
        val store = store(wrong)
        store.prepare()
        assertEquals(PocketModelState.Failed("checksum"), store.state)
        assertEquals("checksum", store.data().getString("reason"))
        assertFalse(File(tmp.root, "a.tflite").exists())
        assertFalse("the part is deleted", File(tmp.root, "a.tflite.part").exists())
        assertFalse("the next file is never fetched", File(tmp.root, "voices/b.bin").exists())
        assertEquals(0, loads)
    }

    @Test
    fun `a size mismatch fails with checksum too`() {
        val store = store(listOf(PocketFile("a.tflite", 41, sha(a))))
        store.prepare()
        assertEquals(PocketModelState.Failed("checksum"), store.state)
        assertFalse(File(tmp.root, "a.tflite").exists())
    }

    @Test
    fun `an interrupted download keeps its part and resumes from its length with a Range`() {
        fetcher.failAfter = 16
        val store = store()
        store.prepare()
        assertEquals(PocketModelState.Failed("network"), store.state)
        val part = File(tmp.root, "a.tflite.part")
        assertEquals(16L, part.length())
        assertFalse(File(tmp.root, "a.tflite").exists())

        store.prepare()
        assertEquals(listOf(0L, 16L, 0L), fetcher.offsets)
        assertEquals(PocketModelState.Ready, store.state)
        assertTrue(a.contentEquals(File(tmp.root, "a.tflite").readBytes()))
    }

    @Test
    fun `a part left by an earlier process is resumed, not restarted`() {
        File(tmp.root, "a.tflite.part").writeBytes(a.copyOfRange(0, 20))
        store().prepare()
        assertEquals(20L, fetcher.offsets.first())
        assertTrue(a.contentEquals(File(tmp.root, "a.tflite").readBytes()))
    }

    @Test
    fun `progress is monotonic and ends at the total`() {
        File(tmp.root, "a.tflite.part").writeBytes(a.copyOfRange(0, 8))
        store().prepare()
        val received = states.filterIsInstance<PocketModelState.Downloading>().map { it.received }
        assertTrue(received.isNotEmpty())
        assertEquals(received.sorted(), received)
        assertEquals(received.distinct(), received)
        assertEquals(64L, received.last())
        assertTrue(states.filterIsInstance<PocketModelState.Downloading>().all { it.total == 64L })
    }

    @Test
    fun `files already in place are not fetched again`() {
        store().prepare()
        fetcher.offsets.clear()
        val again = store()
        again.prepare()
        assertTrue(fetcher.offsets.isEmpty())
        assertEquals(PocketModelState.Ready, again.state)
        assertEquals(2, loads)
    }

    @Test
    fun `a load failure is failed load`() {
        val store = store(loader = { throw IllegalStateException("graph") })
        store.prepare()
        assertEquals(PocketModelState.Failed("load"), store.state)
    }

    @Test
    fun `a voice file store without a loader is ready once its file is there`() {
        val voice = store(listOf(files[1]), loader = null)
        voice.prepare()
        assertEquals(PocketModelState.Ready, voice.state)
        assertEquals(PocketModelState.Ready, store(listOf(files[1]), loader = null).state)
    }

    @Test
    fun `reset deletes everything and the state is absent`() {
        val store = store()
        store.prepare()
        store.reset()
        assertEquals(PocketModelState.Absent, store.state)
        assertFalse(File(tmp.root, "a.tflite").exists())
    }

    @Test
    fun `the model lives under noBackupFilesDir, never the cache`() {
        val app = RuntimeEnvironment.getApplication()
        val dir = PocketVoices.directory(app)
        assertTrue(dir.path.startsWith(app.noBackupFilesDir.path))
        assertFalse(dir.path.startsWith(app.cacheDir.path))
        assertTrue(dir.path.endsWith("pocket-tts/" + PocketManifest.REVISION))
    }

    @Test
    fun `the states are the JS MODEL_STATES`() {
        assertEquals(listOf("absent", "downloading", "compiling", "ready", "failed"), PocketModelState.NAMES)
    }
}
