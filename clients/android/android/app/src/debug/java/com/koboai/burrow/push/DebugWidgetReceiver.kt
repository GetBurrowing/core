package com.koboai.burrow.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.koboai.burrow.widgets.Counts
import com.koboai.burrow.widgets.DataStoreCountsStore
import com.koboai.burrow.widgets.WidgetRefresh
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * DEBUG BUILDS ONLY. Puts the widgets in a state without a server, for
 * screenshots on an emulator that cannot sign in (the IdP is passkey-first):
 *
 *   am broadcast -a com.koboai.burrow.debug.WIDGET \
 *     -n com.koboai.burrow.debug/com.koboai.burrow.push.DebugWidgetReceiver \
 *     --ez signed_in true --ei approvals 3 --ei tasks 0 --ei age_minutes 0
 *
 * `signed_in true` stores a stand-in bearer for the selected install
 * (false removes it); the counts are written with `fetched_at = now -
 * age_minutes`; `--ez never_loaded true` clears them. DUMP-protected like
 * DebugPushReceiver.
 */
class DebugWidgetReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != ACTION) return
        val app = context.applicationContext
        val host = BurrowPush.installs(app).selectedInstall?.host ?: return
        val tokens = BurrowPush.tokens(app)
        if (intent.getBooleanExtra("signed_in", true)) tokens.store(host, "debug-widget-stub") else tokens.remove(host)
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val store = DataStoreCountsStore(app)
                if (intent.getBooleanExtra("never_loaded", false)) {
                    store.remove(host)
                } else {
                    val age = intent.getIntExtra("age_minutes", 0) * 60_000L
                    store.write(
                        host,
                        Counts(intent.getIntExtra("approvals", 3), intent.getIntExtra("tasks", 0), System.currentTimeMillis() - age),
                    )
                }
                WidgetRefresh.render(app)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION = "com.koboai.burrow.debug.WIDGET"
    }
}
