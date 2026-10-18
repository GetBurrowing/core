package com.koboai.burrow.push

import android.app.Application
import android.app.Notification
import androidx.core.app.NotificationCompat
import com.koboai.burrow.BurrowNativePlugin
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.push.PushTestSupport.active
import com.koboai.burrow.push.PushTestSupport.posted
import com.koboai.burrow.shortcuts.ConversationShortcuts
import com.koboai.burrow.shortcuts.RecordingShortcutSink
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Relay-mode pushes (task 01a1261e stage 5): data-only maps with no `kind`, opened on the phone. */
@RunWith(RobolectricTestRunner::class)
class RelayedPushTest {
    private lateinit var app: Application
    private val b = SealFixture.host
    private val a = "burrow-a.localhost"
    private lateinit var sink: RecordingShortcutSink

    private fun label(): String {
        val last = sink.pushed.last()
        return last.shortLabel.toString()
    }

    @Before
    fun setUp() {
        app = PushTestSupport.app()
        BurrowPush.pushKeyCipherOverride = FakeTokenCipher()
        sink = RecordingShortcutSink()
        ConversationShortcuts.sinkOverride = sink
        BurrowPush.installs(app).add(b, "B")
        BurrowPush.tokens(app).store(b, PushTestSupport.BEARER)
        BurrowPush.pushKeys(app).put(b, SealFixture.privateKey)
    }

    @After
    fun tearDown() {
        BurrowPush.pushKeyCipherOverride = null
        PushTestSupport.reset()
    }

    private fun signInA() {
        BurrowPush.installs(app).add(a, "A")
        BurrowPush.tokens(app).store(a, PushTestSupport.BEARER)
    }

    private val tag get() = PushPayload.from(SealFixture.innerData).tag

    private fun only(): Notification = active(app).single { it.id == NotificationPresenter.NOTIFICATION_ID }.notification

    private fun replyLabel(n: Notification): String? {
        val inputs = n.actions.firstOrNull()?.remoteInputs ?: return null
        return inputs.single().label?.toString()
    }

    private fun describe(n: Notification): List<Any?> {
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!
        return listOf(
            n.channelId,
            n.group,
            n.shortcutId,
            n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            n.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
            style.conversationTitle?.toString(),
            style.isGroupConversation,
            style.messages.map { listOf(it.text.toString(), it.person?.name?.toString(), it.person?.key) },
            n.actions.map { it.title.toString() },
            replyLabel(n),
            n.category,
        )
    }

    @Test
    fun `a relayed push builds the same MessagingStyle notification as its plaintext data map`() {
        NotificationPresenter.present(app, SealFixture.innerData)
        val direct = describe(posted(app, tag))
        app.getSystemService(android.app.NotificationManager::class.java).cancelAll()

        NotificationPresenter.present(app, SealFixture.relayed())
        val relayed = describe(posted(app, tag))

        assertEquals(direct, relayed)
        // Not vacuous: both are the real conversation, not two fallbacks.
        assertEquals("launch", relayed[6])
        val message = listOf("@Robin can you check the deck before 3?", "Dana", "$b|user:01a1261e-0000-7000-8000-00000000000c")
        assertEquals(listOf(message), relayed[8])
    }

    @Test
    fun `the decrypted notification is never the relay's constant or ciphertext`() {
        NotificationPresenter.present(app, SealFixture.relayed())
        val text = PushTestSupport.text(posted(app, tag))
        assertFalse(text.contains(SealFixture.sealed.take(16)))
        assertFalse(text.contains("New notification"))
        assertTrue(text.contains("@Robin can you check the deck before 3?"))
    }

    @Test
    fun `a blob sealed for another install (aad mismatch) reads New message in, never ciphertext`() {
        signInA()
        // A holds the same private key, so ONLY the aad differs.
        BurrowPush.pushKeys(app).put(a, SealFixture.privateKey)
        NotificationPresenter.present(app, SealFixture.relayed(installHost = a))
        val n = only()
        assertEquals("mentions:$a", n.channelId)
        assertEquals("New message in A", n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
        assertFalse(PushTestSupport.text(n).contains(SealFixture.sealed.take(16)))
    }

    @Test
    fun `a null sealed reads New message in, never blank`() {
        NotificationPresenter.present(app, SealFixture.relayed(sealed = null))
        val n = only()
        assertEquals("New message in B", n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
    }

    @Test
    fun `no key on this phone reads New message in`() {
        BurrowPush.pushKeys(app).remove(b)
        NotificationPresenter.present(app, SealFixture.relayed())
        assertEquals("New message in B", only().extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
    }

    @Test
    fun `every push writes its unread count, relayed or direct`() {
        NotificationPresenter.present(app, SealFixture.relayed())
        assertEquals(InstallUnread(3, 1_791_644_400_000L, false), BurrowPush.unread(app).entry(b))
        // An older direct push does not bring back a different count.
        val older = PushTestSupport.mention + ("install_host" to b) + ("unread_count" to "9") + ("unread_as_of" to "2026-10-10T14:00:00Z")
        NotificationPresenter.present(app, older)
        assertEquals(3, BurrowPush.unread(app).entry(b)!!.count)
    }

    @Test
    fun `the install name is the subtext only when two installs are signed in`() {
        NotificationPresenter.present(app, SealFixture.relayed())
        assertNull(posted(app, tag).extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
        signInA()
        NotificationPresenter.present(app, SealFixture.relayed())
        assertEquals("B", posted(app, tag).extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString())
    }

    @Test
    fun `with two installs the conversation title names the install, because API 35 does not draw the subtext there`() {
        NotificationPresenter.present(app, SealFixture.relayed())
        val single = posted(app, tag)
        assertEquals("launch", NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(single)!!.conversationTitle)
        signInA()
        NotificationPresenter.present(app, SealFixture.relayed())
        val n = posted(app, tag)
        assertEquals("launch · B", NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!.conversationTitle)
        assertEquals("launch · B", n.extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString())
        // The subtext stays for the layouts that draw it.
        assertEquals("B", n.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString())
    }

    @Test
    fun `the conversation shortcut's label names the install too, since API 35 titles the shade from it`() {
        NotificationPresenter.present(app, SealFixture.relayed())
        assertEquals("launch", label())
        signInA()
        NotificationPresenter.present(app, SealFixture.relayed())
        assertEquals("launch · B", label())
    }

    @Test
    fun `a dm with no space name is titled sender · install`() {
        signInA()
        val dm = SealFixture.innerData - "space_name" + ("space_kind" to "dm")
        NotificationPresenter.present(app, dm)
        val n = posted(app, PushPayload.from(dm).tag)
        assertEquals("Dana · B", NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!.conversationTitle)
    }

    @Test
    fun `the fallback keeps Burrow • install via the subtext and no conversation title`() {
        signInA()
        NotificationPresenter.present(app, SealFixture.relayed(sealed = null))
        val n = only()
        assertEquals("B", n.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString())
        assertNull(n.extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE))
    }

    @Test
    fun `installBadges answers others_unread for the install showing`() {
        signInA()
        NotificationPresenter.present(app, SealFixture.relayed())
        val unread = BurrowPush.unread(app)
        assertEquals("""{"others_unread":true}""", BurrowNativePlugin.installBadgesAnswer(unread.othersUnread(a)).toString())
        assertEquals("""{"others_unread":false}""", BurrowNativePlugin.installBadgesAnswer(unread.othersUnread(b)).toString())
    }

    @Test
    fun `a group summary carries the install's unread as its number`() {
        val payload = PushPayload.from(SealFixture.innerData)
        val summary = NotificationPresenter.buildSummary(app, payload, payload.groupKey!!, 2, "B", 3)
        assertEquals(3, summary.number)
        assertEquals("B", summary.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString())
    }
}
