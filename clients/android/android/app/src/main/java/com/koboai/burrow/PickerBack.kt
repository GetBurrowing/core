package com.koboai.burrow

/** What back does while the install picker is showing. */
enum class PickerBack {
    /** The picker's own Add / Can't-reach screen is up: back closes it. */
    CLOSE_SUB_SCREEN,

    /** An install is on screen under the picker: back returns to it. */
    DISMISS_TO_CURRENT,

    /**
     * A cold "Switch install" shortcut launch: nothing is loaded yet, so back
     * opens the install that was current before the shortcut.
     */
    OPEN_RESTORED,

    /** Nothing to return to (first launch, signed out, sign-in failed): the system's back. */
    SYSTEM,
    ;

    companion object {
        fun decide(
            hasSubScreen: Boolean,
            currentHost: String?,
            restoreHost: String?,
        ): PickerBack =
            when {
                hasSubScreen -> CLOSE_SUB_SCREEN
                currentHost != null -> DISMISS_TO_CURRENT
                restoreHost != null -> OPEN_RESTORED
                else -> SYSTEM
            }
    }
}

/**
 * The install a "Switch install" picker goes back to. A row tap in
 * [InstallPickerView] selects at once, before Continue, so backing out of
 * the picker must put the selection back: the current install stays
 * selected until the person picks another with Continue.
 *
 * Only the switch picker remembers. The other pickers (first launch, sign-in
 * failed, signed out, the web's switchInstall) keep today's back.
 */
class PickerReturn(
    private val store: InstallStore,
) {
    /** The confirmed install when the switch picker opened; null otherwise. */
    var restoreHost: String? = null
        private set

    /**
     * Called each time the picker is presented. [switching] is true only for
     * the launcher shortcut. A picker that is already a switch picker keeps
     * its install (a row may have been tapped since).
     */
    fun onPresent(switching: Boolean) {
        if (switching && restoreHost == null && store.hasConfirmedSelection) restoreHost = store.selectedHost
    }

    /** The picker is gone, or an install was opened. */
    fun clear() {
        restoreHost = null
    }

    fun decide(
        hasSubScreen: Boolean,
        currentHost: String?,
    ): PickerBack {
        // An install removed from the picker meanwhile is nothing to go back to.
        val restorable = restoreHost?.takeIf { host -> store.installs.any { it.host == host } }
        return PickerBack.decide(hasSubScreen, currentHost, restorable)
    }

    /** Puts the selection back on the install the picker opened over; that install, or null. */
    fun restoreSelection(): Install? {
        val host = restoreHost ?: return null
        store.select(host)
        return store.installs.firstOrNull { it.host == host }
    }
}
