package com.koboai.burrow

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * The launcher shortcut's target (res/xml/shortcuts.xml): a no-UI
 * trampoline that forwards "Switch install" to [MainActivity] and finishes.
 *
 * Android starts every static (manifest) shortcut intent with
 * FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK. Aimed at MainActivity,
 * that destroys the running activity (and the page in its WebView) instead
 * of delivering onNewIntent. This activity has its own empty task affinity
 * (AndroidManifest.xml), so CLEAR_TASK clears only its own throwaway task.
 * The forward carries NEW_TASK alone, so the singleTask MainActivity is
 * brought forward and gets onNewIntent, or starts cold if it is not running.
 */
class SwitchInstallActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Theme.NoDisplay: finish before onResume.
        startActivity(forward(this))
        finish()
    }

    companion object {
        fun forward(context: Context): Intent =
            Intent(LaunchRouter.ACTION_SWITCH_INSTALL)
                .setClass(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
