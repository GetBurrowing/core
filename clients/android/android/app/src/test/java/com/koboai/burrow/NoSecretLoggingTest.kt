package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source guard: no log call in the app may name a token, a bearer, a code
 * or a verifier. Covers `android.util.Log`, Capacitor's `Logger`,
 * `println` and `printStackTrace` (whose trace prints a message that could
 * carry one). Runs in `testDebugUnitTest`, so `check` fails on it.
 */
class NoSecretLoggingTest {
    companion object {
        private val LOG_CALL =
            Regex(
                listOf(
                    """Log\.(v|d|i|w|e|wtf)""",
                    """Logger\.(verbose|debug|info|warn|error)""",
                    """println|print""",
                    """System\.(out|err)\.print\w*""",
                ).joinToString("|", prefix = """\b(""", postfix = """)\s*\("""),
            )
        private val SECRET = Regex("""(?i)token|bearer|code|verifier|secret|password|key""")

        /** The offending lines of [source]: a log call whose line names a secret. */
        fun offences(source: String): List<String> =
            source.lines().filter { line ->
                val call = LOG_CALL.find(line) ?: return@filter false
                SECRET.containsMatchIn(line.substring(call.range.first))
            } + source.lines().filter { it.contains("printStackTrace(") }
    }

    @Test
    fun `the guard flags what it is meant to flag`() {
        // A guard that cannot go red proves nothing: show it does.
        assertEquals(1, offences("""Log.d(TAG, "bearer=${'$'}token")""").size)
        assertEquals(1, offences("""    Log.i("Auth", code)""").size)
        assertEquals(1, offences("""Logger.debug("verifier " + v)""").size)
        assertEquals(1, offences("""println(grant.token)""").size)
        assertEquals(1, offences("""e.printStackTrace()""").size)
        assertTrue(offences("""Log.d(TAG, "page finished")""").isEmpty())
        assertTrue(offences("""val token = store.token(host)""").isEmpty())
    }

    @Test
    fun `no app source logs a secret`() {
        val root = File("src/main/java")
        assertTrue("run from the app module: ${File(".").absolutePath}", root.isDirectory)
        // Every build type's sources: the debug push receiver and token
        // source live in src/debug.
        val roots = listOf(root, File("src/debug/java"), File("src/release/java"))
        assertTrue(roots.all { it.isDirectory })
        val sources =
            roots.flatMap { dir -> dir.walkTopDown().filter { it.isFile && (it.extension == "kt" || it.extension == "java") }.toList() }
        assertFalse(sources.isEmpty())
        assertTrue(sources.any { it.name == "DebugPushReceiver.kt" })
        val found = sources.flatMap { file -> offences(file.readText()).map { "${file.name}: ${it.trim()}" } }
        assertTrue("log calls naming a secret:\n" + found.joinToString("\n"), found.isEmpty())
    }
}
