package com.koboai.burrow

import android.content.Intent
import android.net.Uri
import com.koboai.burrow.push.NotificationPresenter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * MainActivity's intent dispatch, cold (onCreate) and warm (onNewIntent),
 * against a recording shell. Robolectric for a real [Intent].
 */
@RunWith(RobolectricTestRunner::class)
class LaunchRouterTest {
    /** Records each shell call; handles a notification only when it is ACTION_OPEN, like MainActivity. */
    private class FakeShell(
        /** What MainActivity's startWithSelection would find; the router must not consult it. */
        val hasConfirmedSelection: Boolean = true,
    ) : LaunchRouter.Shell {
        val calls = mutableListOf<String>()

        override fun openFromNotification(intent: Intent): Boolean {
            if (intent.action != NotificationPresenter.ACTION_OPEN) return false
            intent.action = null
            calls.add("openFromNotification")
            return true
        }

        override fun openConversation(
            host: String?,
            path: String,
        ) {
            calls.add("openConversation($host,$path)")
        }

        override fun presentPicker() {
            calls.add("presentPicker")
        }

        override fun presentSwitchPicker() {
            calls.add("presentSwitchPicker")
        }

        override fun startWithSelection() {
            calls.add("startWithSelection")
        }

        override fun completeSignIn(code: String) {
            calls.add("completeSignIn($code)")
        }
    }

    private val shell = FakeShell()
    private val router = LaunchRouter(shell)

    private fun shortcut() = Intent(LaunchRouter.ACTION_SWITCH_INSTALL).setClassName("com.koboai.burrow", "com.koboai.burrow.MainActivity")

    private fun launcher() = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)

    private fun callback(code: String) = Intent(Intent.ACTION_VIEW, Uri.parse("burrow://auth/callback?code=$code"))

    @Test
    fun `cold shortcut presents the switch picker, not the confirmed install`() {
        router.onLaunch(shortcut(), restored = false)
        assertEquals(true, shell.hasConfirmedSelection)
        assertEquals(listOf("presentSwitchPicker"), shell.calls)
    }

    @Test
    fun `warm shortcut presents the switch picker and completes no sign-in`() {
        router.onNewIntent(shortcut())
        assertEquals(listOf("presentSwitchPicker"), shell.calls)
    }

    @Test
    fun `the shortcut action is consumed on both paths`() {
        val cold = shortcut()
        router.onLaunch(cold, restored = false)
        assertNull(cold.action)
        val warm = shortcut()
        router.onNewIntent(warm)
        assertNull(warm.action)
    }

    @Test
    fun `a shortcut relaunched from Recents opens the last install`() {
        val relaunch = shortcut().addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        router.onLaunch(relaunch, restored = false)
        assertEquals(listOf("startWithSelection"), shell.calls)
    }

    @Test
    fun `a plain launcher intent starts with the selection cold and does nothing warm`() {
        router.onLaunch(launcher(), restored = false)
        assertEquals(listOf("startWithSelection"), shell.calls)
        shell.calls.clear()
        router.onNewIntent(launcher())
        assertEquals(emptyList<String>(), shell.calls)
    }

    @Test
    fun `a cold launch with no intent starts with the selection`() {
        router.onLaunch(null, restored = false)
        assertEquals(listOf("startWithSelection"), shell.calls)
    }

    @Test
    fun `a notification Open wins on both paths`() {
        router.onLaunch(Intent(NotificationPresenter.ACTION_OPEN), restored = false)
        assertEquals(listOf("openFromNotification"), shell.calls)
        shell.calls.clear()
        router.onNewIntent(Intent(NotificationPresenter.ACTION_OPEN))
        assertEquals(listOf("openFromNotification"), shell.calls)
    }

    @Test
    fun `the login callback completes the sign-in warm and restarts at the picker cold`() {
        router.onNewIntent(callback("x"))
        assertEquals(listOf("completeSignIn(x)"), shell.calls)
        shell.calls.clear()
        router.onLaunch(callback("x"), restored = false)
        assertEquals(listOf("presentPicker"), shell.calls)
    }

    @Test
    fun `a restore after process death opens the selection, not the shortcut's picker again`() {
        // Recents restores the record: getIntent() is the original shortcut
        // intent, without FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY.
        router.onLaunch(shortcut(), restored = true)
        assertEquals(listOf("startWithSelection"), shell.calls)
    }

    @Test
    fun `a restore does not replay a notification's Open`() {
        router.onLaunch(Intent(NotificationPresenter.ACTION_OPEN), restored = true)
        assertEquals(listOf("startWithSelection"), shell.calls)
    }

    private fun conversation(
        host: String = "suite.example.com",
        path: String = "/chat/internal-fabrikam-sxi",
    ) = Intent(LaunchRouter.ACTION_OPEN_CONVERSATION)
        .setClassName("com.koboai.burrow", "com.koboai.burrow.MainActivity")
        .putExtra(LaunchRouter.EXTRA_CONVERSATION_HOST, host)
        .putExtra(LaunchRouter.EXTRA_CONVERSATION_PATH, path)

    @Test
    fun `a conversation shortcut opens the conversation cold and warm and is consumed`() {
        val cold = conversation()
        router.onLaunch(cold, restored = false)
        assertEquals(listOf("openConversation(suite.example.com,/chat/internal-fabrikam-sxi)"), shell.calls)
        assertNull(cold.action)
        shell.calls.clear()
        val warm = conversation()
        router.onNewIntent(warm)
        assertEquals(listOf("openConversation(suite.example.com,/chat/internal-fabrikam-sxi)"), shell.calls)
        assertNull(warm.action)
    }

    @Test
    fun `a conversation shortcut's host and path are guarded`() {
        router.onNewIntent(conversation(host = "not a host", path = "//evil.example"))
        assertEquals(listOf("openConversation(null,/)"), shell.calls)
    }

    @Test
    fun `a conversation shortcut relaunched from Recents opens the last install`() {
        router.onLaunch(conversation().addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY), restored = false)
        assertEquals(listOf("startWithSelection"), shell.calls)
    }

    @Test
    fun `a restore does not replay a conversation shortcut`() {
        router.onLaunch(conversation(), restored = true)
        assertEquals(listOf("startWithSelection"), shell.calls)
    }
}
