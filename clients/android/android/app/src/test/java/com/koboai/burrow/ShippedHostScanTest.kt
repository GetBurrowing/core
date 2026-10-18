package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Fails if shipped app code or config names a personal install host (task
 * 01a12787): the app ships no install list. Walks `src/main` (Kotlin and XML)
 * plus `capacitor.config.ts`, never `src/test` or `src/testDebug`, since
 * test code does not ship. The Gradle unit-test working directory is the app
 * module.
 *
 * The hosts are matched by sha256 digest, the rule core's install-identity
 * guard uses (apps/platform/test/support/install_identity_scanner.ex), so this
 * file does not spell them (task 01a14b9e stage 5). A line is tokenised: every
 * `[a-z0-9]+([.-][a-z0-9]+)+` run of the lowercased line and each of its
 * dot-suffixes is a host candidate, and every `[a-z0-9]+` run is a name
 * candidate. The shipped application id is not a host and is not matched: its
 * candidates hash to nothing listed.
 */
class ShippedHostScanTest {
    companion object {
        /** sha256 of the personal install hosts (three domains and one org name). */
        val PERSONAL_HOST =
            setOf(
                "5dea22a579e9477122312d9f7269eabfa8147527a8d24738683f6b6734487560",
                "b29a46a27acbba77b0aaba113e3d343cbd951a3a848f8356c164c3728b1c8e05",
                "b185c3068c145f728a1aab6f00091fb6735ddf72311b368f592cb7b0a2a5f37c",
                "44506f784f8d79f5c01259f925b02d157fc5703fa334313d7575d43f308c9a36",
            )

        private val COMPOUND = Regex("""[a-z0-9]+(?:[.\-][a-z0-9]+)+""")
        private val TOKEN = Regex("""[a-z0-9]+""")

        fun sha256(text: String): String =
            java.security.MessageDigest
                .getInstance("SHA-256")
                .digest(text.toByteArray())
                .joinToString("") { "%02x".format(it) }

        fun candidates(line: String): List<String> {
            val low = line.lowercase()
            val compounds =
                COMPOUND.findAll(low).flatMap { run ->
                    val word = run.value
                    sequenceOf(word) + word.indices.filter { word[it] == '.' }.map { word.substring(it + 1) }
                }
            return (compounds + TOKEN.findAll(low).map { it.value }).toList()
        }

        /** True when a host candidate or name in [line] is a personal install host. */
        fun namesPersonalHost(line: String): Boolean = candidates(line).any { sha256(it) in PERSONAL_HOST }

        fun shippedFiles(): List<File> {
            val main = File("src/main")
            val sources = main.walkTopDown().filter { it.isFile && it.extension in setOf("kt", "xml") }.toList()
            return sources + File("../../capacitor.config.ts")
        }

        fun matches(
            digests: Set<String>,
            files: List<File>,
        ): List<String> =
            files.flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    if (candidates(line).any { sha256(it) in digests }) "${file.path}:${index + 1}" else null
                }
            }
    }

    @Test
    fun `the scanner finds a known shipped string`() {
        // Positive control: the same walk, tokeniser and digest match see a
        // string that IS in a shipped file, so an empty result below is a real
        // absence.
        val files = shippedFiles()
        assertTrue("the walk misses InstallStore.kt", files.any { it.path.endsWith("burrow/InstallStore.kt") })
        assertTrue("the walk misses the manifest", files.any { it.name == "AndroidManifest.xml" })
        assertTrue("capacitor.config.ts is missing", File("../../capacitor.config.ts").isFile)
        assertTrue("the walk reaches into src/test", files.none { it.path.contains("src/test") })
        assertTrue(matches(setOf(sha256("manifest.json")), files).any { it.contains("InstallStore.kt:") })
    }

    @Test
    fun `the tokeniser yields hosts, their dot-suffixes and whole names`() {
        assertEquals(
            listOf("chat.example.com", "example.com", "com", "https", "chat", "example", "com"),
            candidates("https://Chat.Example.com/"),
        )
        assertEquals(64, sha256("x").length)
        assertEquals(4, PERSONAL_HOST.size)
    }

    @Test
    fun `no shipped file names a personal install host`() {
        assertEquals(emptyList<String>(), matches(PERSONAL_HOST, shippedFiles()))
    }
}
