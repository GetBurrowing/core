package com.koboai.burrow.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.koboai.burrow.HttpResponse
import com.koboai.burrow.HttpTransport
import com.koboai.burrow.TokenStore
import org.json.JSONObject
import java.util.Base64

/**
 * DEBUG BUILDS ONLY (`src/debug`, registered in the debug manifest). Takes
 * a base64 JSON extra, [EXTRA_PAYLOAD], and hands its FCM `message.data` to
 * [NotificationPresenter.present], exactly as [BurrowMessagingService] does
 * for a real push. Accepts what `fcm_stub.py` records (`{"message": {"data":
 * {...}}}`), a bare `{"data": {...}}`, or the data object itself.
 * [EXTRA_REPLY_STUB] stands in for the server on Reply.
 */
class DebugPushReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != ACTION) return
        intent.getStringExtra(EXTRA_REPLY_STUB)?.toIntOrNull()?.let { stubReplies(it) }
        val encoded = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        val data = parse(encoded) ?: return
        NotificationPresenter.present(context, data)
    }

    companion object {
        const val ACTION = "com.koboai.burrow.debug.PUSH"
        const val EXTRA_PAYLOAD = "payload"

        /**
         * `--es reply_stub 201` (or 500): until the process dies, every
         * `/api/app` call made through [BurrowPush.client] is answered
         * in-process with that status and a stand-in bearer, so Reply's sent
         * and failed states can be shown on an emulator that cannot sign in
         * (the IdP is passkey-only). Nothing is persisted and no request
         * leaves the device.
         */
        const val EXTRA_REPLY_STUB = "reply_stub"

        /**
         * GET /api/app/spaces answers [STUB_SPACES] (the share sheet's space
         * list); every other call answers [status].
         */
        private fun stubReplies(status: Int) {
            BurrowPush.tokenStoreOverride =
                object : TokenStore {
                    override fun token(host: String): String = "debug-reply-stub"
                }
            BurrowPush.transportOverride =
                HttpTransport { request ->
                    if (request.method == "GET" && request.url.endsWith("/api/app/spaces")) {
                        HttpResponse(200, STUB_SPACES)
                    } else {
                        HttpResponse(status, "{}")
                    }
                }
        }

        private const val STUB_SPACES =
            """{"spaces":[
            {"id":"0192f0a1-s1","name":"Internal Fabrikam SXI","path_segment":"internal-fabrikam-sxi","agents":[{"id":"a1","name":"Higgins"}]},
            {"id":"0192f0a1-s2","name":"Launch room","path_segment":"launch-room","agents":[]}]}"""

        /** The FCM data map from a base64 JSON payload, or null when it is not one. */
        fun parse(encoded: String): Map<String, String>? {
            val json =
                try {
                    JSONObject(String(Base64.getDecoder().decode(encoded.trim()), Charsets.UTF_8))
                } catch (_: Exception) {
                    return null
                }
            val data =
                json.optJSONObject("message")?.optJSONObject("data")
                    ?: json.optJSONObject("data")
                    ?: json
            return data.keys().asSequence().associateWith { data.get(it).toString() }
        }
    }
}
