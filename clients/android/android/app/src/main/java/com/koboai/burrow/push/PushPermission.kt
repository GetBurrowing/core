package com.koboai.burrow.push

import com.koboai.burrow.KeyValueStore

/**
 * What this DEVICE has asked, in the private prefs file [FILE] (excluded
 * from backup, so a new phone restored from an old one is still asked).
 * Never stored on the server: the web banner's dismissal is per USER
 * (PR #1190), and someone who dismissed it on a desktop must still be asked
 * on a new phone. Nothing here reads the banner state.
 */
class PushPrefs(
    private val store: KeyValueStore,
) {
    /** The explainer has been shown at least once (so pushState stops saying "prompt"). */
    var explainerShown: Boolean
        get() = store.getBoolean(KEY_EXPLAINER_SHOWN)
        set(value) = store.putBoolean(KEY_EXPLAINER_SHOWN, value)

    /** Android's own POST_NOTIFICATIONS prompt has been shown at least once. */
    var systemAsked: Boolean
        get() = store.getBoolean(KEY_SYSTEM_ASKED)
        set(value) = store.putBoolean(KEY_SYSTEM_ASKED, value)

    companion object {
        const val FILE = "burrow_push"
        private const val KEY_EXPLAINER_SHOWN = "explainer_shown.v1"
        private const val KEY_SYSTEM_ASKED = "system_asked.v1"
    }
}

/** What `enablePush` does next. */
enum class PermissionStep {
    /** Notifications are on: get the token and register. */
    REGISTER,

    /** Android 13+, the system prompt can still be shown: the explainer first. */
    EXPLAIN,

    /** Android 13+, denied twice, so Android will not prompt again: the settings variant. */
    EXPLAIN_DENIED_PERMANENTLY,

    /** Off, and there is nothing the app may ask (Android 12 and earlier). */
    DENIED,
}

/** The permission rules, as pure functions of what Android reports. */
object PushPermission {
    const val TIRAMISU = 33

    /**
     * `pushState` (the `push_subscribe.js` contract): "granted" when
     * notifications are on; "prompt" on Android 13+ when this device has never
     * shown the explainer; "denied" otherwise. Below Android 13 notifications
     * are on by default, so off means the person switched them off.
     */
    fun state(
        sdk: Int,
        notificationsEnabled: Boolean,
        explainerShown: Boolean,
    ): String =
        when {
            notificationsEnabled -> "granted"
            sdk >= TIRAMISU && !explainerShown -> "prompt"
            else -> "denied"
        }

    /**
     * The next step of `enablePush`. [canAskAgain] is Android's
     * `shouldShowRequestPermissionRationale`: true after exactly one denial.
     * A system prompt that was shown and is no longer allowed means "denied
     * permanently". Re-asking happens only because the person asked (the
     * web's /inbox settings row, which offers a button inside the Android app
     * because the hook reports `native_platform: "android"`, or the banner
     * calls enablePush); nothing re-asks on a
     * timer, and `pushState` reports "denied" after the first ask so the web
     * never auto-calls again.
     */
    fun nextStep(
        sdk: Int,
        notificationsEnabled: Boolean,
        systemAsked: Boolean,
        canAskAgain: Boolean,
    ): PermissionStep =
        when {
            notificationsEnabled -> PermissionStep.REGISTER
            sdk < TIRAMISU -> PermissionStep.DENIED
            systemAsked && !canAskAgain -> PermissionStep.EXPLAIN_DENIED_PERMANENTLY
            else -> PermissionStep.EXPLAIN
        }
}
