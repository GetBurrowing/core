package com.koboai.burrow.shortcuts

import androidx.core.app.Person
import com.koboai.burrow.InMemoryKeyValueStore
import com.koboai.burrow.LaunchRouter
import com.koboai.burrow.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class ConversationShortcutsTest {
    private val context = RuntimeEnvironment.getApplication()
    private val registry = InMemoryKeyValueStore()
    private var now = 1_000L

    private fun shortcuts(sink: RecordingShortcutSink) = ConversationShortcuts(context, sink, registry) { now++ }

    private val harper =
        Person
            .Builder()
            .setName("Harper")
            .setKey("suite.example.com|user:u1")
            .build()

    private fun ConversationShortcuts.publish(
        host: String,
        space: String,
    ) = publish(host, space, "Space $space", "/chat/$space", listOf(harper))

    @Test
    fun `(a) the id is host-scoped and parse round-trips`() {
        assertEquals("suite.example.com|0192-s", ConversationShortcuts.shortcutId("Suite.example.com", "0192-s"))
        assertEquals("suite.example.com" to "0192-s", ConversationShortcuts.parse("suite.example.com|0192-s"))
        // The same space id on two installs is two shortcuts.
        val other = ConversationShortcuts.shortcutId("suite.milv.life", "0192-s")
        assertNotEquals(other, ConversationShortcuts.shortcutId("suite.example.com", "0192-s"))
        assertNull(ConversationShortcuts.shortcutId("not a host", "0192-s"))
        assertNull(ConversationShortcuts.shortcutId("suite.example.com", "../x"))
        assertNull(ConversationShortcuts.parse("switch_install"))
        assertNull(ConversationShortcuts.parse("0192-s"))
        assertNull(ConversationShortcuts.parse("suite.example.com|a|b"))
    }

    @Test
    fun `(b) removeForHost removes only that host, not a host it prefixes`() {
        val sink = RecordingShortcutSink()
        val s = shortcuts(sink)
        s.publish("10.0.2.2", "a")
        s.publish("10.0.2.20", "b")
        s.publish("suite.milv.life", "c")

        s.removeForHost("10.0.2.2")

        assertEquals(listOf("10.0.2.2|a"), sink.removedDynamic)
        assertEquals(setOf("10.0.2.20|b", "suite.milv.life|c"), sink.dynamic.keys)
        assertEquals(setOf("10.0.2.20|b", "suite.milv.life|c"), registry.keys())
    }

    @Test
    fun `a removal drops both the dynamic and the long-lived shortcut`() {
        val sink = RecordingShortcutSink()
        val s = shortcuts(sink)
        s.publish("suite.example.com", "a")
        s.removeForHost("suite.example.com")
        assertEquals(listOf("suite.example.com|a"), sink.removedDynamic)
        assertEquals(listOf("suite.example.com|a"), sink.removedLongLived)
    }

    @Test
    fun `(c) the static shortcut counts toward the cap and the least recently used is evicted`() {
        val sink = RecordingShortcutSink(max = 5, manifest = 1)
        val s = shortcuts(sink)
        for (i in 1..4) s.publish("suite.example.com", "s$i")
        // s1 is used again, so s2 is now the least recently used.
        s.publish("suite.example.com", "s1")
        s.publish("suite.example.com", "s5")

        assertEquals(4, sink.dynamic.size)
        assertEquals(4, registry.keys().size)
        assertEquals(listOf("suite.example.com|s2"), sink.removedDynamic)
        assertEquals(listOf("suite.example.com|s2"), sink.removedLongLived)
        assertFalse(sink.removedDynamic.contains(ConversationShortcuts.SWITCH_INSTALL_ID))
        assertFalse(sink.removedLongLived.contains(ConversationShortcuts.SWITCH_INSTALL_ID))
    }

    @Test
    fun `no room at all publishes nothing`() {
        val sink = RecordingShortcutSink(max = 1, manifest = 1)
        assertNull(shortcuts(sink).publish("suite.example.com", "a"))
        assertTrue(sink.pushed.isEmpty())
    }

    @Test
    fun `(d) a published shortcut is a long-lived conversation that opens the space`() {
        val sink = RecordingShortcutSink()
        val id = shortcuts(sink).publish("suite.example.com", "0192-s", "Internal Fabrikam SXI", "/chat/internal-fabrikam-sxi", listOf(harper))
        assertEquals("suite.example.com|0192-s", id)
        val shortcut = sink.pushed.single()

        assertEquals(id, shortcut.id)
        assertTrue(shortcut.longLivedForTest)
        assertEquals(setOf(ConversationShortcuts.CATEGORY_CONVERSATION, ConversationShortcuts.CATEGORY_SHARE_TARGET), shortcut.categories)
        assertEquals(id, shortcut.locusId!!.id)
        assertEquals("Internal Fabrikam SXI", shortcut.shortLabel.toString())
        assertEquals(
            "Harper",
            shortcut.personsForTest
                .single()
                .name
                .toString(),
        )
        assertNotNull(shortcut.icon)

        val intent = shortcut.intent
        assertEquals(LaunchRouter.ACTION_OPEN_CONVERSATION, intent.action)
        assertEquals(MainActivity::class.java.name, intent.component!!.className)
        assertEquals("suite.example.com", intent.getStringExtra(LaunchRouter.EXTRA_CONVERSATION_HOST))
        assertEquals("/chat/internal-fabrikam-sxi", intent.getStringExtra(LaunchRouter.EXTRA_CONVERSATION_PATH))
    }

    @Test
    fun `the conversation path strips the query and refuses anything that is not a chat path`() {
        assertEquals("/chat/internal-fabrikam-sxi", ConversationShortcuts.conversationPath("/chat/internal-fabrikam-sxi?message=0192-m", "s"))
        assertEquals("/chat/s", ConversationShortcuts.conversationPath("//evil.example/chat/x", "s"))
        assertEquals("/chat/s", ConversationShortcuts.conversationPath("/chat", "s"))
        assertEquals("/chat/s", ConversationShortcuts.conversationPath(null, "s"))
    }

    @Test
    fun `Monogram takes the first letter`() {
        assertEquals("J", Monogram.letter(" harper"))
        assertEquals("?", Monogram.letter(null))
        assertEquals("?", Monogram.letter("  "))
    }
}
