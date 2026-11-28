// The prompt, generation and decode loops of one text chunk, moved out of
// PocketSynthesizer.kt (ported from LiteRT-Models `pockettts` at 823729dd, MIT;
// provenance in THIRD_PARTY.md) so they run against a fake in tests. Local
// change (task 01a21e4a stage 6): [cancelled] is checked before EVERY graph
// run, so a stopped reply frees the synthesis worker within one run.
package com.koboai.burrow.voice.pocket

import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.DEC_FRAMES
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.EOS_THRESHOLD
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.FRAME_RATE
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.F_BLK
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.F_HOP
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.GEN_SECONDS_PADDING
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.LDIM
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.MIMI_D
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.SPF
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.S_BLK
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.S_DEC
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.TOKENS_PER_SECOND
import com.koboai.burrow.voice.pocket.PocketSynthesizer.Companion.UPS
import kotlin.math.ceil

/** The graph runs and host state one chunk needs: [PocketSynthesizer] on LiteRT, a fake in tests. */
internal interface PocketSteps {
    val bos: FloatArray
    val neutral: FloatArray

    /** Back to the voice's prompt KV state. */
    fun reset()

    /** KV slots left for generated frames. */
    fun room(): Int

    fun embed(id: Int): FloatArray

    /** The noise for a text-prompt step (zeros). */
    fun prompt(): FloatArray

    /** One Gaussian draw for a generated frame. */
    fun noise(): FloatArray

    /** One fused flow-LM + flow-head run: (latent, eos logit). */
    fun step(
        emb: FloatArray,
        noise: FloatArray,
    ): Pair<FloatArray, Float>

    fun project(latent: FloatArray): FloatArray

    /** One Mimi decoder-transformer block run. */
    fun decTx(block: FloatArray): FloatArray

    /** The one-shot SEANet run over the whole window. */
    fun decOnly(features: FloatArray): FloatArray
}

internal object PocketChunk {
    /**
     * The reference autoregressive loop for one <=50-token chunk: the text
     * prompt, then frames until EOS. Null when [cancelled] said stop, checked
     * before every step of both loops.
     */
    fun generate(
        steps: PocketSteps,
        ids: IntArray,
        framesAfterEos: Int,
        cancelled: () -> Boolean,
    ): List<FloatArray>? {
        steps.reset()
        for (id in ids) {
            if (cancelled()) return null
            steps.step(steps.embed(id), steps.prompt())
        }
        val estimate = ceil((ids.size / TOKENS_PER_SECOND + GEN_SECONDS_PADDING) * FRAME_RATE)
        val maxGen = minOf(estimate.toInt(), steps.room())
        val latents = ArrayList<FloatArray>(maxOf(0, maxGen))
        var emb = steps.bos
        var eosStep = -1
        for (g in 0 until maxGen) {
            if (cancelled()) return null
            val (lat, eosLogit) = steps.step(emb, steps.noise())
            if (eosLogit > EOS_THRESHOLD && eosStep < 0) eosStep = g
            if (eosStep >= 0 && g >= eosStep + framesAfterEos) break
            latents.add(lat)
            emb = steps.project(lat)
        }
        return latents
    }

    /**
     * Mimi decode: overlapped dec_tx blocks -> one-shot SEANet window. Null
     * when [cancelled] said stop, checked before every block and before the
     * SEANet run.
     */
    fun decode(
        steps: PocketSteps,
        latents: List<FloatArray>,
        cancelled: () -> Boolean,
    ): FloatArray? {
        val t = minOf(latents.size, DEC_FRAMES)
        val feat = FloatArray(MIMI_D * S_DEC)
        val blk = FloatArray((1 + F_BLK) * LDIM)

        fun runBlock(
            prev: FloatArray,
            start: Int,
        ): FloatArray? {
            if (cancelled()) return null
            System.arraycopy(prev, 0, blk, 0, LDIM)
            for (f in 0 until F_BLK) {
                val src = if (start + f < t) latents[start + f] else steps.neutral
                System.arraycopy(src, 0, blk, (1 + f) * LDIM, LDIM)
            }
            return steps.decTx(blk)
        }

        var out = runBlock(steps.neutral, 0) ?: return null
        val n0 = minOf(F_BLK, t)
        for (c in 0 until MIMI_D) {
            System.arraycopy(out, c * S_BLK, feat, c * S_DEC, n0 * UPS)
        }
        var kept = F_BLK
        while (kept < t) {
            val start = kept - F_HOP
            out = runBlock(latents[start - 1], start) ?: return null
            val n = minOf(F_BLK, t - start)
            val keepN = (n - F_HOP) * UPS
            for (c in 0 until MIMI_D) {
                System.arraycopy(out, c * S_BLK + F_HOP * UPS, feat, c * S_DEC + kept * UPS, keepN)
            }
            kept += n - F_HOP
        }

        if (cancelled()) return null
        val wav = steps.decOnly(feat)
        return FloatArray(t * SPF) { wav[it].coerceIn(-1f, 1f) }
    }
}
