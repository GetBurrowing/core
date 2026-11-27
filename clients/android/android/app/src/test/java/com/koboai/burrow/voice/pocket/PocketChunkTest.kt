package com.koboai.burrow.voice.pocket

import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.LDIM
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.MIMI_D
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.SPF
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.S_BLK
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.S_DEC
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Barge-in (task 01a21e4a stage 6): a stop must free the synthesis worker
 * within one graph run, wherever it lands: in the text prompt, in generation,
 * between decoder blocks, or just before the SEANet run.
 */
class PocketChunkTest {
    /** Counts every graph run; [stopAfter] runs in, the reply is stopped. */
    private class FakeSteps(
        val stopAfter: Int = Int.MAX_VALUE,
        val eosAt: Int = Int.MAX_VALUE,
    ) : PocketSteps {
        var runs = 0
        var steps = 0
        var generated = 0
        var blocks = 0
        var seanet = 0
        val stopped get() = runs >= stopAfter

        override val bos = FloatArray(1024)
        override val neutral = FloatArray(LDIM)

        override fun reset() {}

        override fun room() = 400

        override fun embed(id: Int) = FloatArray(1024)

        override fun prompt() = FloatArray(LDIM)

        override fun noise(): FloatArray {
            generated++
            return FloatArray(LDIM)
        }

        override fun step(
            emb: FloatArray,
            noise: FloatArray,
        ): Pair<FloatArray, Float> {
            runs++
            steps++
            val eos = if (generated > eosAt) 0f else -10f
            return FloatArray(LDIM) to eos
        }

        override fun project(latent: FloatArray) = FloatArray(1024)

        override fun decTx(block: FloatArray): FloatArray {
            runs++
            blocks++
            return FloatArray(MIMI_D * S_BLK)
        }

        override fun decOnly(features: FloatArray): FloatArray {
            runs++
            seanet++
            return FloatArray(S_DEC * SPF / 16)
        }
    }

    private fun latents(n: Int) = List(n) { FloatArray(LDIM) }

    @Test
    fun `a stop during the text prompt frees the worker within one step`() {
        val fake = FakeSteps(stopAfter = 5)
        assertNull(PocketChunk.generate(fake, IntArray(40), framesAfterEos = 3) { fake.stopped })
        assertEquals(5, fake.steps)
    }

    @Test
    fun `a stop during generation frees the worker within one step`() {
        val fake = FakeSteps(stopAfter = 10 + 7)
        assertNull(PocketChunk.generate(fake, IntArray(10), framesAfterEos = 3) { fake.stopped })
        assertEquals(17, fake.steps)
    }

    @Test
    fun `a stop between decoder blocks frees the worker within one block, and SEANet never runs`() {
        val fake = FakeSteps(stopAfter = 2)
        assertNull(PocketChunk.decode(fake, latents(200)) { fake.stopped })
        assertEquals(2, fake.blocks)
        assertEquals(0, fake.seanet)
    }

    @Test
    fun `a stop after the last decoder block skips the SEANet run`() {
        // 90 frames: blocks at 0 and 32 only, so the stop lands right before SEANet.
        val fake = FakeSteps(stopAfter = 2)
        assertNull(PocketChunk.decode(fake, latents(90)) { fake.stopped })
        assertEquals(2, fake.blocks)
        assertEquals(0, fake.seanet)
    }

    @Test
    fun `without a stop a chunk runs to EOS and decodes every frame`() {
        val fake = FakeSteps(eosAt = 20)
        val frames = PocketChunk.generate(fake, IntArray(10), framesAfterEos = 3) { false }
        assertNotNull(frames)
        // EOS seen on frame 20; three more frames, then the loop ends.
        assertEquals(23, frames!!.size)
        val pcm = PocketChunk.decode(fake, frames) { false }
        assertEquals(23 * SPF, pcm!!.size)
        assertEquals(1, fake.seanet)
    }
}
