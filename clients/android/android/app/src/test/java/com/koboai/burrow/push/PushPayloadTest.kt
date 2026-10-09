package com.koboai.burrow.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PushPayloadTest {
    private val mention =
        mapOf(
            "kind" to "chat_mention",
            "title" to "Harper in Internal Fabrikam SXI",
            "body" to "@Marlowe can you check the banner copy",
            "url" to "/chat/internal-fabrikam-sxi?message=0192-m",
            "category" to "SUITE_MENTION",
            "thread_id" to "0192-s",
            "space_id" to "0192-s",
            "message_id" to "0192-m",
            "install_host" to "suite.example.com",
            "author_name" to "Harper",
            "space_name" to "Internal Fabrikam SXI",
        )

    @Test
    fun `parses every field from FCM string values`() {
        val p = PushPayload.from(mention)
        assertEquals("chat_mention", p.kind)
        assertEquals("Harper in Internal Fabrikam SXI", p.title)
        assertEquals("@Marlowe can you check the banner copy", p.body)
        assertEquals("/chat/internal-fabrikam-sxi?message=0192-m", p.url)
        assertEquals("0192-s", p.spaceId)
        assertEquals("0192-m", p.messageId)
        assertEquals("suite.example.com", p.installHost)
        assertEquals("Harper", p.authorName)
        assertEquals("Internal Fabrikam SXI", p.spaceName)
        assertTrue(p.isMention)
        assertTrue(p.canReply)
    }

    @Test
    fun `missing optional keys are null, a blank value is missing, and kind defaults to generic`() {
        val p = PushPayload.from(mapOf("title" to "Hello", "body" to "  "))
        assertEquals("generic", p.kind)
        assertEquals("Hello", p.title)
        assertNull(p.body)
        assertNull(p.url)
        assertNull(p.installHost)
        assertNull(p.spaceId)
        assertNull(p.groupKey)
        assertFalse(p.canReply)
        assertEquals("/", p.openPath)
    }

    @Test
    fun `a mention without a message id cannot reply`() {
        assertFalse(PushPayload.from(mention - "message_id").canReply)
        assertFalse(PushPayload.from(mention - "install_host").canReply)
    }

    @Test
    fun `ids that are not id-shaped are dropped, never put in a path`() {
        val p = PushPayload.from(mention + ("space_id" to "../../session") + ("message_id" to "a/b"))
        assertNull(p.spaceId)
        assertNull(p.messageId)
        assertFalse(p.canReply)
    }

    @Test
    fun `the install host is normalised and a non-host is dropped`() {
        assertEquals("suite.example.com", PushPayload.from(mention + ("install_host" to "Suite.example.com")).installHost)
        assertNull(PushPayload.from(mention + ("install_host" to "not a host")).installHost)
    }

    @Test
    fun `group keys are per install and space for mentions, per install for approvals`() {
        assertEquals("mentions:suite.example.com:0192-s", PushPayload.from(mention).groupKey)
        val review = PushPayload.from(mapOf("kind" to "review_request_pending", "install_host" to "suite.example.com", "task_id" to "t1"))
        val plan = PushPayload.from(mapOf("kind" to "task_plan_review", "install_host" to "suite.example.com", "task_id" to "t2"))
        assertEquals("approvals:suite.example.com", review.groupKey)
        assertEquals(review.groupKey, plan.groupKey)
        val other = PushPayload.from(mapOf("kind" to "task_plan_review", "install_host" to "suite.milv.life"))
        assertNotEquals(review.groupKey, other.groupKey)
        assertNull(PushPayload.from(mapOf("kind" to "chat_message", "install_host" to "suite.example.com")).groupKey)
    }

    @Test
    fun `summary text`() {
        val review = PushPayload.from(mapOf("kind" to "review_request_pending"))
        assertEquals("3 approvals", PushPayload.summaryText(review, 3))
        assertEquals("4 new in Internal Fabrikam SXI", PushPayload.summaryText(PushPayload.from(mention), 4))
    }

    @Test
    fun `the Open guard keeps a local path and sends anything else to the root`() {
        assertEquals("/chat/0192-s?message=m", PushPayload.safePath("/chat/0192-s?message=m"))
        assertEquals("/chat/internal-fabrikam-sxi?message=0192-m", PushPayload.from(mention).openPath)
        assertEquals("/", PushPayload.safePath("https://evil.example/chat"))
        assertEquals("/", PushPayload.safePath("//evil.example/chat"))
        assertEquals("/", PushPayload.safePath("/\\evil.example"))
        assertEquals("/", PushPayload.safePath("javascript:alert(1)"))
        assertEquals("/", PushPayload.safePath("chat/x"))
        assertEquals("/", PushPayload.safePath("/chat/x\nLocation: //evil"))
        assertEquals("/", PushPayload.safePath(""))
        assertEquals("/", PushPayload.safePath(null))
        assertEquals("/", PushPayload.safePath("/"))
    }

    @Test
    fun `tags differ per message so each notification is its own`() {
        val a = PushPayload.from(mention)
        val b = PushPayload.from(mention + ("message_id" to "0192-n"))
        assertNotEquals(a.tag, b.tag)
        assertEquals(a.tag, PushPayload.from(a.toData()).tag)
    }

    @Test
    fun `toString names keys, never content`() {
        val text = PushPayload.from(mention).toString()
        assertFalse(text.contains("banner copy"))
        assertFalse(text.contains("Harper"))
    }

    // Task 01a116c4.

    @Test
    fun `isChat covers chat_mention and chat_message only`() {
        assertTrue(PushPayload.from(mention).isChat)
        assertTrue(PushPayload.from(mention + ("kind" to "chat_message")).isChat)
        assertTrue(PushPayload.from(mention + ("kind" to "chat_message")).canReply)
        assertFalse(PushPayload.from(mention + ("kind" to "task_plan_review")).isChat)
        assertFalse(PushPayload.from(mapOf("kind" to "generic")).isChat)
    }

    @Test
    fun `space kind and author identity are parsed, a bad author id or type is dropped`() {
        val p = PushPayload.from(mention + ("space_kind" to "dm") + ("author_id" to "0192-u") + ("author_type" to "agent"))
        assertEquals("dm", p.spaceKind)
        assertEquals("0192-u", p.authorId)
        assertEquals("agent", p.authorType)
        assertEquals(p, PushPayload.from(p.toData()))

        val bad = PushPayload.from(mention + ("author_id" to "../x") + ("author_type" to "admin"))
        assertNull(bad.authorId)
        assertNull(bad.authorType)
    }

    @Test
    fun `a chat push with host and space has a shortcut id, a redacted one does not`() {
        assertEquals("suite.example.com|0192-s", PushPayload.from(mention).shortcutId)
        assertNull(PushPayload.from(mention - "space_id").shortcutId)
        assertNull(PushPayload.from(mention - "install_host").shortcutId)
        assertNull(
            PushPayload
                .from(
                    mapOf("kind" to "review_request_pending", "install_host" to "suite.example.com", "space_id" to "s"),
                ).shortcutId,
        )
    }
}
