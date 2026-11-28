package com.koboai.burrow.voice.pocket

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import com.koboai.burrow.BuildConfig

/**
 * Whether this phone can run Pocket TTS, and if not, why. Where the answer is
 * no, the reply is read by a system voice exactly as before. Mirrors iOS
 * `PocketTTSSupport.decide`.
 */
object PocketSupport {
    /** The Voice tab's on-device path needs API 31 (the on-device recognizer). */
    const val MIN_SDK = 31

    /** LiteRT ships these 64-bit ABIs. */
    val ABIS = setOf("arm64-v8a", "x86_64")

    /**
     * Below this much RAM (`ActivityManager.MemoryInfo.totalMem`) the gate
     * says `low_memory`. Derivation: [PEAK_PSS_BYTES] is the app's peak PSS
     * in the debug `pocket_probe` on the API 35 x86_64 emulator (4 GB,
     * 2026-11-27): 2,477,431 kB, during the first load, warm-up and a
     * three-sentence paragraph, with every graph on CPU (the CPU path
     * dequantizes the fp16 weights to fp32, so a phone's GPU path should need
     * less; not measured). Headroom: twice the peak, plus 2 GiB for the system
     * and the WebView shell, rounded up to a whole GiB: 2 x 2.36 GiB + 2 GiB
     * = 6.73 GiB -> 7 GiB. An 8 GB phone typically reports more than 7 GiB
     * and passes; a 6 GB one is refused (an inference, not measured on phones).
     */
    const val PEAK_PSS_BYTES = 2_477_431L * 1024
    const val MIN_TOTAL_MEM_BYTES = 7L * 1024 * 1024 * 1024

    /** Synthesis time over audio time on the first warm-up sentence: above this, `too_slow`. */
    const val MAX_RTF = 0.8

    val REASONS = listOf("os_too_old", "abi_unsupported", "low_ram_device", "low_memory", "too_slow")

    /** os_too_old | abi_unsupported | low_ram_device | low_memory | too_slow, or null when supported. */
    fun decide(
        sdkInt: Int,
        abis: List<String>,
        isLowRamDevice: Boolean,
        totalMemBytes: Long,
        measuredRtf: Double?,
    ): Pair<Boolean, String?> {
        val reason =
            when {
                sdkInt < MIN_SDK -> "os_too_old"
                abis.none { it in ABIS } -> "abi_unsupported"
                isLowRamDevice -> "low_ram_device"
                totalMemBytes < MIN_TOTAL_MEM_BYTES -> "low_memory"
                measuredRtf != null && measuredRtf > MAX_RTF -> "too_slow"
                else -> null
            }
        return (reason == null) to reason
    }
}

/**
 * The gate for this process: the device facts, the warm-up's measured RTF
 * once known (a slow warm-up marks the phone unsupported for the session),
 * and a debug override ([forced], set only by the debug probe receiver).
 */
class PocketGate(
    private val facts: () -> Triple<Int, List<String>, Pair<Boolean, Long>>,
) {
    /** The first warm-up's RTF, this session. */
    @Volatile var measuredRtf: Double? = null

    /** Debug builds only: "supported", or a reason to report. */
    @Volatile var forced: String? = null

    fun current(): Pair<Boolean, String?> {
        forced?.let { return if (it == SUPPORTED) true to null else false to it }
        val (sdk, abis, memory) = facts()
        return PocketSupport.decide(sdk, abis, memory.first, memory.second, measuredRtf)
    }

    companion object {
        const val SUPPORTED = "supported"

        /** Debug builds: the prefs file and key the debug `force_gate` broadcast writes, so it survives a relaunch. */
        const val DEBUG_PREFS = "burrow_voice_debug"
        const val DEBUG_FORCE_GATE = "force_gate"

        fun forContext(context: Context): PocketGate {
            val activity = context.getSystemService(ActivityManager::class.java)
            return PocketGate {
                val info = ActivityManager.MemoryInfo().also { activity.getMemoryInfo(it) }
                Triple(Build.VERSION.SDK_INT, Build.SUPPORTED_ABIS.toList(), activity.isLowRamDevice to info.totalMem)
            }.also { gate ->
                if (BuildConfig.DEBUG) {
                    gate.forced = context.getSharedPreferences(DEBUG_PREFS, Context.MODE_PRIVATE).getString(DEBUG_FORCE_GATE, null)
                }
            }
        }
    }
}
