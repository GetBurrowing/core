package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source guard (task 01a116c4): no log call in the app may name message
 * text or who and where it came from: a body, text, reply, content, a
 * space name or an author name. A chat push now carries people and
 * conversations into shortcuts; none of it belongs in logcat. Mirrors
 * [NoSecretLoggingTest], with its own positive control.
 */
class NoMessageTextLoggingTest {
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
        private val MESSAGE_TEXT = Regex("""(?i)body|text|reply|content|spaceName|authorName""")

        /** The offending lines of [source]: a log call whose line names message text. */
        fun offences(source: String): List<String> =
            source.lines().filter { line ->
                val call = LOG_CALL.find(line) ?: return@filter false
                MESSAGE_TEXT.containsMatchIn(line.substring(call.range.first))
            }
    }

    @Test
    fun `the guard flags what it is meant to flag`() {
        // A guard that cannot go red proves nothing: show it does.
        assertEquals(1, offences("""Log.d(TAG, payload.body)""").size)
        assertEquals(1, offences("""    Log.i("Reply", "sent ${'$'}reply")""").size)
        assertEquals(1, offences("""Logger.debug("from " + payload.authorName)""").size)
        assertEquals(1, offences("""println(payload.spaceName)""").size)
        assertEquals(1, offences("""Log.w(TAG, message.content)""").size)
        assertEquals(1, offences("""Log.e(TAG, input.text)""").size)
        assertTrue(offences("""Log.d(TAG, "shortcut published")""").isEmpty())
        assertTrue(offences("""val body = payload.body""").isEmpty())
    }

    @Test
    fun `no app source logs message text`() {
        val root = File("src/main/java")
        assertTrue("run from the app module: ${File(".").absolutePath}", root.isDirectory)
        val roots = listOf(root, File("src/debug/java"), File("src/release/java"))
        assertTrue(roots.all { it.isDirectory })
        val sources =
            roots.flatMap { dir -> dir.walkTopDown().filter { it.isFile && (it.extension == "kt" || it.extension == "java") }.toList() }
        assertFalse(sources.isEmpty())
        assertTrue(sources.any { it.name == "NotificationPresenter.kt" })
        assertTrue(sources.any { it.name == "ConversationShortcuts.kt" })
        val found = sources.flatMap { file -> offences(file.readText()).map { "${file.name}: ${it.trim()}" } }
        assertTrue("log calls naming message text:\n" + found.joinToString("\n"), found.isEmpty())
    }
}
