package com.koboai.burrow.voice

/**
 * The Voice debug trace: ids, states, counts and timings, never what was said
 * or the reply (NoMessageTextLoggingTest scans every call). Release builds
 * have no sink, so a line is never even built; debug builds install one at
 * process start (src/debug `DebugVoiceTraceInit`, tag BurrowVoiceTrace).
 * Mirrors iOS `VoiceTrace.swift`.
 */
object VoiceTrace {
    @Volatile
    var sink: ((String) -> Unit)? = null

    fun log(line: () -> String) {
        sink?.invoke(line())
    }
}
