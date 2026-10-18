package com.koboai.burrow.push

import android.app.Application
import android.app.Notification
import android.graphics.Bitmap
import android.graphics.Color
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import com.google.crypto.tink.hybrid.internal.TestPushSealer
import com.koboai.burrow.FakeTokenCipher
import com.koboai.burrow.push.AvatarServer.Companion.bitmapOf
import com.koboai.burrow.push.AvatarServer.Companion.image
import com.koboai.burrow.push.AvatarServer.Companion.near
import com.koboai.burrow.push.PushTestSupport.mention
import com.koboai.burrow.push.PushTestSupport.posted
import com.koboai.burrow.shortcuts.ConversationShortcuts
import com.koboai.burrow.shortcuts.Monogram
import com.koboai.burrow.shortcuts.RecordingShortcutSink
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode
import java.util.Base64
import java.util.concurrent.TimeUnit

/**
 * The sender's avatar on a posted notification (task 01a12773 stage 3):
 * the fetched picture when it arrives in time, the in-app letter disc on
 * every failure, and never a late or missing notification.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AvatarPresentTest {
    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var app: Application
    private lateinit var avatars: AvatarServer
    private lateinit var sink: RecordingShortcutSink

    @Before
    fun setUp() {
        app = PushTestSupport.app()
        PushTestSupport.signIn(app)
        sink = RecordingShortcutSink()
        ConversationShortcuts.sinkOverride = sink
        avatars = AvatarServer()
        BurrowPush.avatarFetcherOverride = AvatarFetcher(BurrowPush.tokens(app), folder.root, avatars.clientSockets)
    }

    @After
    fun tearDown() {
        avatars.shutdown()
        BurrowPush.pushKeyCipherOverride = null
        PushTestSupport.reset()
    }

    private fun withAvatar(
        data: Map<String, String?> = mention,
        url: String = avatars.url("/idp/sam.png"),
        tone: String = "4",
    ): Map<String, String?> = data + ("author_avatar_url" to url) + ("author_avatar_tone" to tone)

    private fun senderIcon(data: Map<String, String?>): Bitmap {
        val n = posted(app, PushPayload.from(data).tag)
        val person = senderOf(n)
        return bitmapOf(person.icon!!, app)
    }

    private fun senderOf(n: Notification): Person {
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!
        return style.messages.single().person!!
    }

    /** A point inside the disc, above the initials: the disc's fill. */
    private fun fill(bitmap: Bitmap): Int = bitmap.getPixel(bitmap.width / 2, bitmap.height / 14)

    @Test(timeout = 10_000)
    fun `the fetched picture is the sender's icon`() {
        avatars.server.enqueue(image())
        val data = withAvatar()

        NotificationPresenter.present(app, data)

        val icon = senderIcon(data)
        assertTrue(near(Color.RED, icon.getPixel(icon.width / 2, icon.height / 2)))
        // A url on another host than the install: no bearer went with it.
        assertNull(avatars.server.takeRequest().getHeader("Authorization"))
    }

    @Test(timeout = 10_000)
    fun `a slow avatar host still posts on time, with the letter disc in the tone's colour`() {
        avatars.server.enqueue(image().setBodyDelay(10, TimeUnit.SECONDS))
        val data = withAvatar(tone = "4")

        val start = System.nanoTime()
        NotificationPresenter.present(app, data)
        val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)

        assertTrue("took $elapsed ms", elapsed < 3_000)
        val icon = senderIcon(data)
        assertTrue(near(Monogram.FALLBACK_BACKGROUNDS[4], fill(icon)))
    }

    @Test(timeout = 10_000)
    fun `no avatar url draws the letter disc and makes no request`() {
        NotificationPresenter.present(app, mention + ("author_avatar_tone" to "2"))

        assertEquals(0, avatars.server.requestCount)
        assertTrue(near(Monogram.FALLBACK_BACKGROUNDS[2], fill(senderIcon(mention))))
    }

    @Test(timeout = 10_000)
    fun `an agent with no picture gets the base-300 disc`() {
        val agent = mention + ("author_type" to "agent") + ("author_avatar_tone" to "agent")
        NotificationPresenter.present(app, agent)
        assertTrue(near(Monogram.LIGHT.base300, fill(senderIcon(agent))))
    }

    @Test(timeout = 10_000)
    fun `two pushes from one sender fetch the picture once`() {
        avatars.server.enqueue(image())
        val first = withAvatar()
        val second = withAvatar(mention + ("message_id" to "0192-m2"))

        NotificationPresenter.present(app, first)
        NotificationPresenter.present(app, second)

        assertEquals(1, avatars.server.requestCount)
        val icon = senderIcon(second)
        assertTrue(near(Color.RED, icon.getPixel(icon.width / 2, icon.height / 2)))
    }

    @Test(timeout = 10_000)
    fun `the reply path reuses the cached picture and makes no request`() {
        avatars.server.enqueue(image())
        val data = withAvatar()
        NotificationPresenter.present(app, data)
        assertEquals(1, avatars.server.requestCount)

        NotificationPresenter.showReplySent(app, PushPayload.from(data), "on it")
        NotificationPresenter.restore(app, PushPayload.from(data))

        assertEquals(1, avatars.server.requestCount)
    }

    @Test(timeout = 10_000)
    fun `a relayed push carries the url inside the sealed blob and shows the picture`() {
        BurrowPush.pushKeyCipherOverride = FakeTokenCipher()
        val host = SealFixture.host
        BurrowPush.installs(app).add(host, "B")
        BurrowPush.tokens(app).store(host, PushTestSupport.BEARER)
        BurrowPush.pushKeys(app).put(host, SealFixture.privateKey)
        avatars.server.enqueue(image())

        val url = avatars.url("/api/app/agents/agent-1/avatar?v=sealed")
        val inner = JSONObject(SealFixture.plaintext).put("author_avatar_url", url).put("author_avatar_tone", "agent")
        val sealed =
            TestPushSealer.seal(
                inner.toString(),
                Base64.getUrlDecoder().decode(SealFixture.recipientPublicKey),
                host,
                PushSeal.INFO,
            )
        val relayed = SealFixture.relayed(sealed = sealed)
        // The url is NOT in what the relay delivered, only inside the blob.
        assertTrue(relayed.values.none { it?.contains("/api/app/agents/") == true })

        NotificationPresenter.present(app, relayed)

        assertEquals(1, avatars.server.requestCount)
        val opened = PushPayload.from(SealFixture.innerData)
        val n = posted(app, opened.tag)
        val person = senderOf(n)
        val icon = bitmapOf(person.icon!!, app)
        assertTrue(near(Color.RED, icon.getPixel(icon.width / 2, icon.height / 2)))
    }

    @Test(timeout = 10_000)
    fun `a dm's shortcut is the sender's face, a channel's never is`() {
        avatars.server.enqueue(image())
        val dm = withAvatar(mention + ("space_kind" to "dm") + ("space_id" to "0192-dm"))
        NotificationPresenter.present(app, dm)
        val dmIcon = bitmapOf(sink.pushed.last().icon!!, app)
        assertTrue(near(Color.RED, dmIcon.getPixel(dmIcon.width / 2, dmIcon.height / 2)))

        // A channel push from the same sender, picture cached: the shortcut
        // keeps the space-name monogram.
        val channel = withAvatar(mention + ("message_id" to "0192-m3"))
        NotificationPresenter.present(app, channel)
        val channelIcon = bitmapOf(sink.pushed.last().icon!!, app)
        assertTrue(!near(Color.RED, channelIcon.getPixel(channelIcon.width / 2, channelIcon.height / 2)))
        assertNotNull(sink.pushed.last().icon)
    }
}
