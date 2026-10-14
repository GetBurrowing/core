package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Fails if shipped app code or config names a personal install host (task
 * 01a12787): the app ships no install list. Walks `src/main` (Kotlin and XML)
 * plus `capacitor.config.ts`, never `src/test` or `src/testDebug`, since
 * test code does not ship. The application id `com.koboai.burrow` and iOS's
 * `com.kobo-ai.burrow` do not match `example\.com`: identity, not an install.
 * The Gradle unit-test working directory is the app module.
 */
class ShippedHostScanTest {
    companion object {
        val PERSONAL_HOST = Regex("""example\.com|ellis|milv\.life|red-st\.ar""")

        fun shippedFiles(): List<File> {
            val main = File("src/main")
            val sources = main.walkTopDown().filter { it.isFile && it.extension in setOf("kt", "xml") }.toList()
            return sources + File("../../capacitor.config.ts")
        }

        fun matches(
            pattern: Regex,
            files: List<File>,
        ): List<String> =
            files.flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    if (pattern.containsMatchIn(line)) "${file.path}:${index + 1}" else null
                }
            }
    }

    @Test
    fun `the scanner finds a known shipped string`() {
        // Positive control: the same walk and matcher see a string that IS in
        // a shipped file, so an empty result below is a real absence.
        val files = shippedFiles()
        assertTrue("the walk misses InstallStore.kt", files.any { it.path.endsWith("burrow/InstallStore.kt") })
        assertTrue("the walk misses the manifest", files.any { it.name == "AndroidManifest.xml" })
        assertTrue("capacitor.config.ts is missing", File("../../capacitor.config.ts").isFile)
        assertTrue("the walk reaches into src/test", files.none { it.path.contains("src/test") })
        assertTrue(matches(Regex("""manifest\.json"""), files).any { it.contains("InstallStore.kt:") })
    }

    @Test
    fun `no shipped file names a personal install host`() {
        assertEquals(emptyList<String>(), matches(PERSONAL_HOST, shippedFiles()))
    }
}
