package com.koboai.burrow.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.HttpTransport
import com.koboai.burrow.InstallProbe
import java.io.IOException
import java.net.URI
import java.time.Instant
import java.util.Base64
import java.util.concurrent.Executors

/**
 * DEBUG BUILDS ONLY (task 01a1261e stage 5). Puts per-install unread in a
 * given state on an emulator that has no install servers, for evidence
 * frames. Nothing leaves the device: every answer is in-process.
 *
 *   am broadcast -a com.koboai.burrow.debug.UNREAD \
 *     -n com.koboai.burrow.debug/com.koboai.burrow.push.DebugUnreadReceiver \
 *     --es installs 'burrow-a.localhost=A,burrow-b.localhost=B' \
 *     --es counts 'burrow-a.localhost=0,burrow-b.localhost=3' \
 *     --es push_key 'burrow-b.localhost=<base64url X25519 private key>'
 *
 * - `installs`: adds each host with that name and stores a stand-in bearer
 *   (as DebugWidgetReceiver does), so it counts as signed in, and selects
 *   the first. The picker's probe answers reachable with that name.
 *   `--ez only true` removes every other install.
 * - `counts`: `host=<n>` answers that host's `GET /api/app/counts` with
 *   `unread` n and `as_of` now; `host=fail` answers with a transport
 *   failure. Then the REAL [UnreadReconciler] runs and the shell is told
 *   (`burrowInstallBadges`, picker redraw), exactly as after onResume.
 * - `push_key` stores a private key for a host (the shared test fixture's,
 *   so a recorded sealed push opens); `remove_key` deletes one.
 *
 * DUMP-protected like DebugPushReceiver. Logs nothing.
 */
class DebugUnreadReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != ACTION) return
        val app = context.applicationContext
        val pending = goAsync()
        Executors.newSingleThreadExecutor().execute {
            try {
                val seeded = pairs(intent.getStringExtra("installs"))
                seeded.forEach { (host, name) ->
                    names[host] = name
                    BurrowPush.installs(app).add(host, name)
                    BurrowPush.tokens(app).store(host, STAND_IN_BEARER)
                }
                if (seeded.isNotEmpty()) {
                    val installs = BurrowPush.installs(app)
                    // `--ez only true`: the seeded installs are the whole list.
                    if (intent.getBooleanExtra("only", false)) {
                        installs.installs
                            .map { it.host }
                            .filter { h -> seeded.none { it.first == h } }
                            .forEach { installs.remove(it) }
                    }
                    installs.select(seeded.first().first)
                }
                InstallProbe.probeOverride = { host -> names[host]?.let { InstallProbe.Result(it) } }
                pairs(intent.getStringExtra("push_key")).forEach { (host, key) ->
                    BurrowPush.pushKeys(app).put(host, Base64.getUrlDecoder().decode(key))
                }
                intent.getStringExtra("remove_key")?.let { BurrowPush.pushKeys(app).remove(it) }
                val counts = pairs(intent.getStringExtra("counts"))
                if (counts.isNotEmpty()) {
                    answers.putAll(counts)
                    BurrowPush.transportOverride = transport
                    BurrowPush.reconciler(app).reconcile(BurrowPush.signedInHosts(app))
                }
                Handler(Looper.getMainLooper()).post { BurrowPush.unreadChanged?.invoke() }
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION = "com.koboai.burrow.debug.UNREAD"
        private const val STAND_IN_BEARER = "debug-unread-stub"
        private val names = java.util.concurrent.ConcurrentHashMap<String, String>()
        private val answers = java.util.concurrent.ConcurrentHashMap<String, String>()

        private val transport =
            HttpTransport { request ->
                val uri = URI(request.url)
                val answer = answers[uri.host]
                when {
                    uri.path != UnreadReconciler.COUNTS_PATH || answer == null -> HttpResponse(404, "{}")
                    answer == "fail" -> throw IOException("debug: unreachable")
                    else -> HttpResponse(200, """{"approvals":0,"tasks":0,"unread":$answer,"as_of":"${Instant.now()}"}""")
                }
            }

        private fun pairs(value: String?): List<Pair<String, String>> =
            value
                ?.split(',')
                ?.mapNotNull { part ->
                    val host = part.substringBefore('=', "").trim()
                    val rest = part.substringAfter('=', "").trim()
                    if (host.isEmpty() || rest.isEmpty()) null else host to rest
                }.orEmpty()
    }
}
