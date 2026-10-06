package com.koboai.burrow.push

import android.content.Context
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import java.io.IOException
import java.util.concurrent.TimeUnit

/** This phone's push registration token. Blocks: run off the main thread. */
fun interface PushTokenSource {
    @Throws(Exception::class)
    fun token(): String
}

/** FCM. Needs the default FirebaseApp, which exists only when the build had google-services.json. */
class FirebaseTokenSource : PushTokenSource {
    // Deprecated in firebase-messaging 25 (see BurrowMessagingService.onNewToken).
    @Suppress("DEPRECATION")
    override fun token(): String = Tasks.await(FirebaseMessaging.getInstance().token, 30, TimeUnit.SECONDS)
}

/** A token handed in by `onNewToken`. */
class FixedTokenSource(
    private val value: String,
) : PushTokenSource {
    override fun token(): String = value

    override fun toString(): String = "FixedTokenSource(<redacted>)"
}

object PushTokenSources {
    /**
     * Firebase when the build is configured for it. Otherwise the build
     * type's fallback: [DebugTokenSource] in a debug build (so registration
     * works against a dev server and `fcm_stub.py` without Firebase), none
     * in release, where `enablePush` then rejects `token_failed`.
     */
    fun forContext(context: Context): PushTokenSource {
        if (FirebaseApp.getApps(context).isNotEmpty()) return FirebaseTokenSource()
        return BuildTypeTokenSource.fallback(context) ?: PushTokenSource { throw IOException("Firebase is not configured") }
    }
}
