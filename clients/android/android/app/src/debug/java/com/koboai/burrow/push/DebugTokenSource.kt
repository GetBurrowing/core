package com.koboai.burrow.push

import android.content.Context
import com.koboai.burrow.InstallStore
import com.koboai.burrow.SharedPreferencesStore
import java.security.MessageDigest
import java.util.Base64

/**
 * DEBUG BUILDS ONLY (this file is in `src/debug`). A stable fake token
 * shaped like an FCM registration token (`<22-char instance id>:APA91b<body>`,
 * base64url), derived from the app install id, so a debug build without
 * Firebase can register against a dev server and `fcm_stub.py`. Real FCM
 * would refuse it; the stub records it and DebugPushReceiver replays.
 */
class DebugTokenSource(
    private val appInstallId: String,
) : PushTokenSource {
    override fun token(): String {
        val id = digest("instance:$appInstallId").take(INSTANCE_ID_LENGTH)
        val body = (1..4).joinToString("") { digest("body$it:$appInstallId") }.take(BODY_LENGTH)
        return "$id:APA91b$body"
    }

    override fun toString(): String = "DebugTokenSource(<redacted>)"

    private fun digest(value: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(
            MessageDigest.getInstance("SHA-256").digest(("burrow-debug-fcm:$value").toByteArray(Charsets.UTF_8)),
        )

    companion object {
        const val INSTANCE_ID_LENGTH = 22
        const val BODY_LENGTH = 134
    }
}

/** The debug build's fallback when Firebase is not configured. */
object BuildTypeTokenSource {
    fun fallback(context: Context): PushTokenSource? {
        val store =
            InstallStore(
                SharedPreferencesStore(context, InstallStore.PREFS_FILE),
                SharedPreferencesStore(context, InstallStore.DEVICE_FILE),
            )
        return DebugTokenSource(store.appInstallId)
    }
}
