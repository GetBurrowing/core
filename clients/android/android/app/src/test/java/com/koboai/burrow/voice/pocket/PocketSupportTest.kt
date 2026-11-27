package com.koboai.burrow.voice.pocket

import org.junit.Assert.assertEquals
import org.junit.Test

class PocketSupportTest {
    private val gib = 1024L * 1024 * 1024
    private val phone = listOf("arm64-v8a", "armeabi-v7a", "armeabi")

    private fun reason(
        sdk: Int = 35,
        abis: List<String> = phone,
        lowRam: Boolean = false,
        mem: Long = 12 * gib,
        rtf: Double? = null,
    ) = PocketSupport.decide(sdk, abis, lowRam, mem, rtf).second

    @Test
    fun `every reason`() {
        assertEquals(null, reason())
        assertEquals(null, reason(abis = listOf("x86_64")))
        assertEquals("os_too_old", reason(sdk = 30))
        assertEquals("abi_unsupported", reason(abis = listOf("armeabi-v7a", "armeabi")))
        assertEquals("abi_unsupported", reason(abis = listOf("x86")))
        assertEquals("low_ram_device", reason(lowRam = true))
        assertEquals("low_memory", reason(mem = PocketSupport.MIN_TOTAL_MEM_BYTES - 1))
        assertEquals(null, reason(mem = PocketSupport.MIN_TOTAL_MEM_BYTES))
        assertEquals("too_slow", reason(rtf = 0.81))
        assertEquals(null, reason(rtf = 0.8))
        assertEquals(null, reason(rtf = 0.3))
        PocketSupport.REASONS.forEach { r -> assertEquals(r, r.lowercase()) }
    }

    @Test
    fun `the decision is the first reason that holds`() {
        assertEquals("abi_unsupported", reason(abis = listOf("x86"), lowRam = true, mem = gib, rtf = 5.0))
        assertEquals("low_ram_device", reason(lowRam = true, mem = gib))
        assertEquals("low_memory", reason(mem = gib, rtf = 5.0))
    }

    @Test
    fun `the memory threshold is derived from the measured peak`() {
        // Twice the emulator's peak PSS plus 2 GiB, rounded up to a whole GiB.
        assertEquals(2_536_889_344L, PocketSupport.PEAK_PSS_BYTES)
        val derived = (2 * PocketSupport.PEAK_PSS_BYTES + 2 * gib + gib - 1) / gib * gib
        assertEquals(derived, PocketSupport.MIN_TOTAL_MEM_BYTES)
    }

    @Test
    fun `a slow warm-up marks the phone unsupported for the session`() {
        val gate = PocketGate { Triple(35, phone, false to 12 * gib) }
        assertEquals(true to null, gate.current())
        gate.measuredRtf = 1.2
        assertEquals(false to "too_slow", gate.current())
    }

    @Test
    fun `the debug override wins either way`() {
        val gate = PocketGate { Triple(35, listOf("x86"), false to gib) }
        gate.forced = PocketGate.SUPPORTED
        assertEquals(true to null, gate.current())
        gate.forced = "low_memory"
        assertEquals(false to "low_memory", gate.current())
        gate.forced = null
        assertEquals(false to "abi_unsupported", gate.current())
    }
}
