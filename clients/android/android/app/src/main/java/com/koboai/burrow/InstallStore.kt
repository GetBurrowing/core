package com.koboai.burrow

import com.koboai.burrow.push.UnreadStore
import java.security.MessageDigest
import java.util.UUID

/**
 * One Burrow install the app can open. Each install has its own spaces and
 * its own sign-in, so the host is the identity of everything per install:
 * the Keystore entry for its bearer, the WebView's origin, and the
 * `install_host` a push payload routes by. Mirrors iOS `Install`.
 */
data class Install(
    val host: String,
    /** The install's own app name from `/manifest.json`, once fetched. */
    val name: String? = null,
) {
    val displayName: String get() = name ?: host
    val baseUrl: String get() = "https://$host/"
    val manifestUrl: String get() = "https://$host/manifest.json"
    val healthUrl: String get() = "https://$host/health"
    val iconUrl: String get() = "https://$host/branding/current/apple_touch"
}

/**
 * The saved install list and the current selection, in a private
 * SharedPreferences file. Mirrors `clients/ios/ios/Shared/InstallStore.swift`.
 *
 * The app ships no install list: a fresh install starts empty and the person
 * adds their own. Once `installs.v1` is written the saved list is
 * authoritative: an install the person removed stays removed.
 *
 * Migration from builds that listed built-in installs (task 01a12787). Those
 * rows were virtual (shown whenever `installs.v1` was absent, never written),
 * so the first read of an absent key runs a one-shot migration and persists
 * the result, so it never runs again:
 *
 * - A preseeded row cannot be told apart from a user-saved one without
 *   shipping the hostnames, and the app must not ship them. So the store keys
 *   on evidence of USE instead: a stored bearer (signed in) or an explicit
 *   selection.
 * - LEGACY means the old build ran: `installs.confirmed.v1` is true or
 *   `installs.selected.v1` is set. A legacy store adopts the selected host
 *   plus every host holding a bearer ([tokenHosts]), normalized and
 *   de-duplicated in that order. A store that is not legacy is a fresh
 *   install and starts empty.
 * - A saved list (anyone who ever added, renamed or removed an install) is
 *   kept WHOLE, including any built-in rows it materialised. Those people were
 *   internal testers and can remove the rows by hand: the price of never
 *   deleting a saved install.
 * - The one case that loses a row: a legacy person who only pressed Continue
 *   on the implicit first row and never signed in. They hold no bearer and no
 *   explicit selection, so there is nothing to sign out of, and they land on
 *   the add-your-install flow.
 * - The LEGACY gate exists on iOS because Keychain items survive app deletion.
 *   On Android the bearer prefs file `burrow_bearer_tokens` is excluded from
 *   backup and dies with app data, so here the gate guards against restored
 *   install prefs instead. It is kept for parity.
 * - Old builds also WROTE the built-in rows: their picker refreshed each
 *   row's name on first display, which saved the virtual list. So a saved
 *   list made only of the old built-in hosts, none of which holds a bearer,
 *   is treated as never saved: it, the selection and the confirmation are
 *   cleared once, and that person lands on the add-your-install flow. Any list
 *   with another host, or with a bearer for any built-in host, is kept WHOLE.
 *   The built-in hosts are recognised by the SHA-256 of the normalized host
 *   ([LEGACY_DEFAULT_HOST_HASHES]), never by name, so no hostname ships. A
 *   renamed built-in row cannot be told from a probed one; the bearer, not
 *   the name, is the signal of real use. [KEY_DEFAULTS_CHECKED] makes this
 *   run once, so an install added afterwards (even a built-in host) stays.
 * - The push service constructs this store too. The migration is a pure
 *   function of (install prefs, bearer hosts), so whichever runs first writes
 *   the same list.
 *
 * [device] holds the app install id. It lives in its own file because that
 * file is excluded from backup: a phone restored from another phone's backup
 * must not claim the old phone's device row on the server.
 */
class InstallStore(
    private val prefs: KeyValueStore,
    private val device: KeyValueStore,
    /** The unread counts file ([com.koboai.burrow.push.UnreadStore.FILE]); [remove] clears the host's entry. */
    private val unread: KeyValueStore? = null,
    /** The hosts holding a bearer, read only by the legacy migration. */
    private val tokenHosts: () -> Set<String> = { emptySet() },
) {
    companion object {
        const val PREFS_FILE = "burrow_installs"
        const val DEVICE_FILE = "burrow_device"

        private const val KEY_INSTALLS = "installs.v1"
        private const val KEY_SELECTED = "installs.selected.v1"
        private const val KEY_CONFIRMED = "installs.confirmed.v1"
        private const val KEY_APP_INSTALL_ID = "app_install_id.v1"
        private const val KEY_DEFAULTS_CHECKED = "installs.defaults_checked.v1"

        /**
         * SHA-256 (lowercase hex) of each normalized pre-2026-10 built-in
         * install host. Hashes, not names: the app ships no hostname.
         */
        val LEGACY_DEFAULT_HOST_HASHES =
            setOf(
                "bf8aedd7f65fd728e9ebfec07705bc51e26ae0f54a35e00e8b2ed514b2bb664e",
                "11a3b9f3cee6dab41a8d8ded38d71da667774c858c9eb82c3c596b21b6273717",
                "c3d59dfdd4a743b27afbfd9fe449cbe919dd425ac7dcabee8790365371c2dde3",
            )

        fun hostHash(host: String): String =
            MessageDigest
                .getInstance("SHA-256")
                .digest(host.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        /** True for a pre-2026-10 built-in install host. */
        fun isLegacyDefault(host: String): Boolean = normalizeHost(host)?.let { hostHash(it) in LEGACY_DEFAULT_HOST_HASHES } == true

        private val LABEL = Regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

        /**
         * Turns what someone typed after the fixed `https://` prefix into a
         * bare lowercase host. Rejects anything that is not a plausible DNS
         * name: the picker only ever talks HTTPS to a host, never to a path
         * or a port.
         */
        fun normalizeHost(input: String): String? {
            var text = input.trim().lowercase()
            for (prefix in listOf("https://", "http://")) {
                if (text.startsWith(prefix)) text = text.removePrefix(prefix)
            }
            text = text.substringBefore('/')
            text = text.removeSuffix(".")
            if (text.length > 253) return null
            val labels = text.split('.')
            if (labels.size < 2) return null
            if (!labels.all { LABEL.matches(it) }) return null
            return text
        }

        // One install per line: host, then a tab, then the name. Hosts are
        // normalized (no tab or newline); names have both replaced.
        internal fun encode(list: List<Install>): String =
            list.joinToString("\n") { install ->
                val name = install.name?.replace('\t', ' ')?.replace('\n', ' ')
                if (name == null) install.host else "${install.host}\t$name"
            }

        internal fun decode(text: String): List<Install> =
            text
                .split('\n')
                .filter { it.isNotBlank() }
                .mapNotNull { line ->
                    val host = normalizeHost(line.substringBefore('\t')) ?: return@mapNotNull null
                    val name = if ('\t' in line) line.substringAfter('\t').ifEmpty { null } else null
                    Install(host, name)
                }
    }

    val installs: List<Install>
        get() {
            val saved = prefs.getString(KEY_INSTALLS) ?: return clearUntouchedDefaults(migrateLegacyInstalls())
            val list = decode(saved)
            return if (prefs.getBoolean(KEY_DEFAULTS_CHECKED)) list else clearUntouchedDefaults(list)
        }

    /**
     * Once per store: a list made only of old built-in hosts, none holding a
     * bearer, is treated as never saved. See the class KDoc.
     */
    private fun clearUntouchedDefaults(list: List<Install>): List<Install> {
        val signedIn = tokenHosts().mapNotNull { normalizeHost(it) }.toSet()
        val untouched = list.isNotEmpty() && list.all { isLegacyDefault(it.host) } && list.none { it.host in signedIn }
        val result =
            if (untouched) {
                save(emptyList())
                prefs.remove(KEY_SELECTED)
                prefs.remove(KEY_CONFIRMED)
                emptyList()
            } else {
                list
            }
        prefs.putBoolean(KEY_DEFAULTS_CHECKED, true)
        return result
    }

    /** Runs when `installs.v1` is absent. See the class KDoc. */
    private fun migrateLegacyInstalls(): List<Install> {
        val selected = prefs.getString(KEY_SELECTED)
        val legacy = prefs.getBoolean(KEY_CONFIRMED) || selected != null
        val adopted =
            if (legacy) {
                (listOfNotNull(selected) + tokenHosts())
                    .mapNotNull { normalizeHost(it) }
                    .distinct()
                    .map { Install(it) }
            } else {
                emptyList()
            }
        save(adopted)
        return adopted
    }

    val selectedHost: String?
        get() {
            val list = installs
            val host = prefs.getString(KEY_SELECTED)
            if (host != null && list.any { it.host == host }) return host
            return list.firstOrNull()?.host
        }

    val selectedInstall: Install?
        get() = selectedHost?.let { host -> installs.firstOrNull { it.host == host } }

    /** True once the person has pressed Continue at least once. */
    val hasConfirmedSelection: Boolean get() = prefs.getBoolean(KEY_CONFIRMED)

    /** A stable per-device id the server keys this app's session and device row on. Not a secret. */
    val appInstallId: String
        get() {
            device.getString(KEY_APP_INSTALL_ID)?.let { return it }
            val id = UUID.randomUUID().toString().lowercase()
            device.putString(KEY_APP_INSTALL_ID, id)
            return id
        }

    fun select(host: String) {
        if (installs.none { it.host == host }) return
        prefs.putString(KEY_SELECTED, host)
    }

    fun confirmSelection() {
        prefs.putBoolean(KEY_CONFIRMED, true)
    }

    /** Adds (or keeps) an install and selects it. Null when [rawHost] is not a host. */
    fun add(
        rawHost: String,
        name: String? = null,
    ): Install? {
        val host = normalizeHost(rawHost) ?: return null
        val list = installs.toMutableList()
        val index = list.indexOfFirst { it.host == host }
        if (index >= 0) {
            if (name != null) list[index] = list[index].copy(name = name)
        } else {
            list.add(Install(host, name))
        }
        save(list)
        select(host)
        return list.first { it.host == host }
    }

    fun updateName(
        name: String?,
        host: String,
    ) {
        val list = installs.toMutableList()
        val index = list.indexOfFirst { it.host == host }
        if (index < 0 || list[index].name == name) return
        list[index] = list[index].copy(name = name)
        save(list)
    }

    fun remove(host: String) {
        save(installs.filter { it.host != host })
        if (prefs.getString(KEY_SELECTED) == host) prefs.remove(KEY_SELECTED)
        // A removed install must not keep a count (or the icon badge) up.
        unread?.let { UnreadStore.clear(it, host) }
    }

    private fun save(list: List<Install>) {
        prefs.putString(KEY_INSTALLS, encode(list))
    }
}
