package com.koboai.burrow.push

import com.koboai.burrow.ApiException
import com.koboai.burrow.AppApiClient

/**
 * Why push could not be registered. [code] is the rejection code
 * `push_subscribe.js` reports. The message is the code only: never a
 * token, a bearer or a response body.
 */
class PushError(
    val code: String,
) : Exception(code) {
    companion object {
        const val NOT_SIGNED_IN = "not_signed_in"
        const val TOKEN_FAILED = "token_failed"
        const val REGISTRATION_FAILED = "registration_failed"
    }
}

/**
 * Gets this phone's push token and stores it on one install
 * (`POST /api/app/devices`). Returns normally ONLY when that POST answered
 * 2xx; every other outcome throws [PushError], so a caller can never report
 * "granted" for a device row the server does not have (the honesty rule in
 * `push_subscribe.js`).
 *
 * A transport failure (no response at all) is retried after [backoffMillis]
 * (0.5 s, 2 s, 5 s); an HTTP status is an answer and is not retried.
 *
 * Blocks: run off the main thread.
 */
class PushRegistrar(
    private val client: AppApiClient,
    private val tokens: PushTokenSource,
    private val packageName: String,
    private val appInstallId: String,
    private val backoffMillis: List<Long> = DEFAULT_BACKOFF_MILLIS,
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
    /** [host]'s push public key (PushKeyStore.publicKey), or null to register without one. */
    private val publicKey: (String) -> String? = { null },
) {
    fun register(host: String) {
        if (!client.isSignedIn(host)) throw PushError(PushError.NOT_SIGNED_IN)
        val token =
            try {
                tokens.token()
            } catch (_: Exception) {
                throw PushError(PushError.TOKEN_FAILED)
            }
        // Created (once) before the POST: the install seals this phone's
        // previews to it. A keystore failure registers without a key.
        val key = publicKey(host)
        var attempt = 0
        while (true) {
            try {
                client.registerDevice(host, token, packageName, appInstallId, key)
                return
            } catch (e: ApiException) {
                when {
                    e.kind == ApiException.Kind.NOT_SIGNED_IN -> throw PushError(PushError.NOT_SIGNED_IN)
                    e.kind == ApiException.Kind.NETWORK && attempt < backoffMillis.size -> sleep(backoffMillis[attempt++])
                    else -> throw PushError(PushError.REGISTRATION_FAILED)
                }
            }
        }
    }

    /** [register] as the answer `enablePush` gives: Registered only when the POST answered 2xx. */
    fun outcome(host: String): EnableOutcome =
        try {
            register(host)
            EnableOutcome.Registered
        } catch (e: PushError) {
            EnableOutcome.Failed(e.code)
        }

    companion object {
        val DEFAULT_BACKOFF_MILLIS = listOf(500L, 2_000L, 5_000L)
    }
}

/** What `enablePush` answers. */
sealed class EnableOutcome {
    /** `{registered: true, state: "granted"}`: the device row is stored. */
    object Registered : EnableOutcome()

    /** `{registered: false, state: "denied"}`: the person said no. */
    object Denied : EnableOutcome()

    /** A rejection with [code] (`not_signed_in`, `token_failed`, `registration_failed`). */
    data class Failed(
        val code: String,
    ) : EnableOutcome()
}
