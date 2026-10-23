package com.koboai.burrow.widgets

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source guards for three binding rules:
 * - `burrow_info` (cyan) is named only by its definitions in colors.xml and
 *   by widgets/SlabColors.kt, so nothing but the LIVE slab can turn cyan;
 * - no OkHttp logging interceptor at BODY or HEADERS level, in any build
 *   type, and no dependency on it;
 * - the Today's briefing widget never names `burrow_primary` or
 *   `burrow_error` (canvas 01a161fa, "Never used").
 */
class WidgetGuardTest {
    private val roots = listOf("src/main", "src/debug", "src/release").map(::File)

    private fun files(): List<File> =
        roots.filter { it.isDirectory }.flatMap { root ->
            root.walkTopDown().filter { it.isFile && it.extension in setOf("kt", "java", "xml") }.toList()
        }

    companion object {
        private val INFO = Regex("""\bburrow_info\b""")

        fun infoOffences(
            path: String,
            text: String,
        ): List<String> {
            val allowed =
                path.endsWith("widgets/SlabColors.kt") ||
                    (path.matches(Regex(""".*/res/values(-night)?/colors\.xml""")))
            if (allowed) return emptyList()
            return text.lines().filter { INFO.containsMatchIn(it) }.map { "$path: ${it.trim()}" }
        }

        private val ALERT_COLOURS = Regex("""\bburrow_(primary|error)\b""")

        /** The briefing widget has no buttons and nothing has failed: orange or red on a cover screen reads as an alert. */
        fun briefingColourOffences(text: String): List<String> = text.lines().filter { ALERT_COLOURS.containsMatchIn(it) }.map { it.trim() }

        private val LOGGING = Regex("""HttpLoggingInterceptor|logging-interceptor|Level\.(BODY|HEADERS)""")

        fun loggingOffences(
            path: String,
            text: String,
        ): List<String> = text.lines().filter { LOGGING.containsMatchIn(it) }.map { "$path: ${it.trim()}" }
    }

    @Test
    fun `the guards go red on what they are meant to catch`() {
        assertEquals(1, infoOffences("src/main/res/layout/x.xml", """android:background="@color/burrow_info"""").size)
        assertEquals(1, infoOffences("src/main/java/com/koboai/burrow/share/ShareActivity.kt", "setColor(R.color.burrow_info)").size)
        assertTrue(infoOffences("src/main/java/x/Y.kt", "R.color.burrow_on_info").isEmpty())
        assertTrue(infoOffences("src/main/java/com/koboai/burrow/widgets/SlabColors.kt", "R.color.burrow_info").isEmpty())
        assertEquals(1, loggingOffences("app/build.gradle", "implementation \"com.squareup.okhttp3:logging-interceptor:4.12.0\"").size)
        assertEquals(1, loggingOffences("X.kt", "HttpLoggingInterceptor().setLevel(HttpLoggingInterceptor.Level.BODY)").size)
    }

    @Test
    fun `burrow_info appears only in colors xml and the slab mapping`() {
        val all = files()
        assertTrue(all.any { it.path.endsWith("SlabColors.kt") })
        val found = all.flatMap { infoOffences(it.path, it.readText()) }
        assertTrue("burrow_info outside the slab mapping:\n" + found.joinToString("\n"), found.isEmpty())
        // Positive control: the mapping does name it.
        assertTrue(File("src/main/java/com/koboai/burrow/widgets/SlabColors.kt").readText().contains("R.color.burrow_info"))
    }

    @Test
    fun `the briefing widget names neither burrow_primary nor burrow_error`() {
        // Positive control: the guard goes red on what it is meant to catch.
        assertEquals(1, briefingColourOffences("slabColor(context, R.color.burrow_primary)").size)
        assertEquals(1, briefingColourOffences("slabColor(context, R.color.burrow_error)").size)
        assertTrue(briefingColourOffences("R.color.burrow_primary_dark").isEmpty())
        val file = File("src/main/java/com/koboai/burrow/widgets/TodaysBriefingWidget.kt")
        assertTrue(file.isFile)
        val found = briefingColourOffences(file.readText())
        assertTrue("alert colours in the briefing widget:\n" + found.joinToString("\n"), found.isEmpty())
    }

    @Test
    fun `no logging interceptor in any source set or build file`() {
        val buildFiles = listOf(File("build.gradle"), File("../build.gradle"), File("../variables.gradle"))
        assertTrue(buildFiles.all { it.isFile })
        val found =
            (files() + buildFiles).flatMap { loggingOffences(it.path, it.readText()) }
        assertTrue("logging interceptor found:\n" + found.joinToString("\n"), found.isEmpty())
        assertFalse(File("build.gradle").readText().contains("okhttp3:okhttp:"))
    }
}
