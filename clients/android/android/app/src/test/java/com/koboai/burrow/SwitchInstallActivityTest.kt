package com.koboai.burrow

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/** The shortcut trampoline forwards "Switch install" to MainActivity without CLEAR_TASK, and finishes. */
@RunWith(RobolectricTestRunner::class)
class SwitchInstallActivityTest {
    @Test
    fun `forwards the switch action to MainActivity with NEW_TASK only and finishes`() {
        // As the launcher starts a static shortcut: NEW_TASK | CLEAR_TASK.
        val shortcut =
            Intent(LaunchRouter.ACTION_SWITCH_INSTALL)
                .setClassName(BuildConfig.APPLICATION_ID, SwitchInstallActivity::class.java.name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        val activity = Robolectric.buildActivity(SwitchInstallActivity::class.java, shortcut).create().get()
        val forwarded = shadowOf(RuntimeEnvironment.getApplication()).nextStartedActivity
        assertEquals(LaunchRouter.ACTION_SWITCH_INSTALL, forwarded.action)
        assertEquals(MainActivity::class.java.name, forwarded.component?.className)
        assertEquals(BuildConfig.APPLICATION_ID, forwarded.component?.packageName)
        assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK, forwarded.flags)
        assertTrue(activity.isFinishing)
    }
}
