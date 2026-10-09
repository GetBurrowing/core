package com.koboai.burrow

import android.content.Intent
import com.koboai.burrow.push.PushPayload

/**
 * Routes the intents that reach [MainActivity], cold ([onLaunch]) and warm
 * ([onNewIntent]), to the shell. Kept apart from the activity so the
 * dispatch is testable without booting Capacitor.
 *
 * Order on both paths: a notification's Open, then a conversation
 * shortcut's open, then the launcher's "Switch install" shortcut, then the login callback, then (cold only) the
 * confirmed install or the picker.
 */
class LaunchRouter(
    private val shell: Shell,
) {
    /** What the router drives; [MainActivity] in the app. */
    interface Shell {
        /** True when [intent] was a notification's Open and was handled. */
        fun openFromNotification(intent: Intent): Boolean

        /**
         * A conversation shortcut: [host] (normalized, or null when it was not
         * a host) at [path] (already guarded).
         */
        fun openConversation(
            host: String?,
            path: String,
        )

        /** The picker, for a login callback that cannot be completed. */
        fun presentPicker()

        /** The launcher's "Switch install" picker: back returns to the current install. */
        fun presentSwitchPicker()

        /** The confirmed install, or the picker when there is none. */
        fun startWithSelection()

        /** Finishes the sign-in that is waiting for this login callback code. */
        fun completeSignIn(code: String)
    }

    /**
     * The intent that started the activity (null when there is none).
     * [restored] is true when onCreate has a saved state: Recents restoring
     * the activity after process death. getIntent() is then the ORIGINAL
     * launch intent (clearing its action did not survive the process), so a
     * one-shot action (a notification's Open, the shortcut) was already
     * handled and must not run again: the restore opens the selection.
     */
    fun onLaunch(
        intent: Intent?,
        restored: Boolean,
    ) {
        when {
            restored -> shell.startWithSelection()
            intent != null && shell.openFromNotification(intent) -> Unit
            intent != null && openConversation(intent) -> Unit
            intent != null && switchInstall(intent) -> Unit
            // A callback that cold-started the app: the verifier died with
            // the old process, so the code cannot be used. Start over.
            intent != null && AuthCallback.code(intent.dataString) != null -> shell.presentPicker()
            else -> shell.startWithSelection()
        }
    }

    /** An intent delivered to the running activity (launchMode singleTask). */
    fun onNewIntent(intent: Intent) {
        if (shell.openFromNotification(intent)) return
        if (openConversation(intent)) return
        if (switchInstall(intent)) return
        val code = AuthCallback.code(intent.dataString) ?: return
        shell.completeSignIn(code)
    }

    /**
     * The launcher shortcut. A relaunch from Recents after process death
     * re-delivers the original intent with FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY;
     * that one opens the last install, not the picker again.
     */
    private fun switchInstall(intent: Intent): Boolean {
        if (intent.action != ACTION_SWITCH_INSTALL) return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        // Consumed: a recreated activity must not replay it.
        intent.action = null
        shell.presentSwitchPicker()
        return true
    }

    /**
     * A conversation shortcut (ConversationShortcuts). Like the Switch
     * install shortcut, a relaunch from Recents does not re-navigate: it
     * falls through to the last install.
     */
    private fun openConversation(intent: Intent): Boolean {
        if (intent.action != ACTION_OPEN_CONVERSATION) return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        val host = intent.getStringExtra(EXTRA_CONVERSATION_HOST)?.let { InstallStore.normalizeHost(it) }
        val path = PushPayload.safePath(intent.getStringExtra(EXTRA_CONVERSATION_PATH))
        // Consumed: a recreated activity must not replay it.
        intent.action = null
        shell.openConversation(host, path)
        return true
    }

    companion object {
        /** A conversation shortcut's intent action (shortcuts.ConversationShortcuts). */
        const val ACTION_OPEN_CONVERSATION = "com.koboai.burrow.action.OPEN_CONVERSATION"
        const val EXTRA_CONVERSATION_HOST = "com.koboai.burrow.extra.HOST"
        const val EXTRA_CONVERSATION_PATH = "com.koboai.burrow.extra.PATH"

        /** The shortcut's intent action (res/xml/shortcuts.xml). */
        const val ACTION_SWITCH_INSTALL = "com.koboai.burrow.action.SWITCH_INSTALL"
    }
}
