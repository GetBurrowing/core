package com.koboai.burrow

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
 * First launch pre-lists the three internal installs with suite.example.com
 * selected. After that the saved list is authoritative: a default the person
 * removed stays removed.
 *
 * [device] holds the app install id. It lives in its own file because that
 * file is excluded from backup: a phone restored from another phone's backup
 * must not claim the old phone's device row on the server.
 */
class InstallStore(
    private val prefs: KeyValueStore,
    private val device: KeyValueStore,
) {
    companion object {
        const val PREFS_FILE = "burrow_installs"
        const val DEVICE_FILE = "burrow_device"
        val DEFAULT_HOSTS = listOf("suite.example.com", "suite.example.com", "suite.milv.life")

        private const val KEY_INSTALLS = "installs.v1"
        private const val KEY_SELECTED = "installs.selected.v1"
        private const val KEY_CONFIRMED = "installs.confirmed.v1"
        private const val KEY_APP_INSTALL_ID = "app_install_id.v1"

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
            val saved = prefs.getString(KEY_INSTALLS) ?: return DEFAULT_HOSTS.map { Install(it) }
            return decode(saved)
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
    }

    private fun save(list: List<Install>) {
        prefs.putString(KEY_INSTALLS, encode(list))
    }
}
