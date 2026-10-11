package com.koboai.burrow.push

import com.koboai.burrow.Install
import com.koboai.burrow.InstallStore

/**
 * What [NotificationPresenter.present] does to every data-only push BEFORE
 * the existing build path (task 01a1261e stage 5; iOS
 * `PushContentPreparer`). No network and no logging: never a title, a body,
 * a blob or a key.
 *
 * 1. A relayed push carries no `kind` (the relay sends only
 *    `install_host`, `unread_count`, `unread_as_of` and `sealed`): open
 *    `sealed` with that install's key and present the inner data map, so a
 *    relayed push builds the very notification its plaintext map would. If
 *    `sealed` is missing or does not open, the body reads `New message in
 *    <install>`: never ciphertext, never blank.
 * 2. Any push carrying `unread_count` / `unread_as_of` (relayed or direct)
 *    updates [UnreadStore].
 * 3. With two or more installs signed in, [Prepared.subText] is the
 *    install's name, which Android draws as `Burrow • <install>`.
 */
class PushContentPreparer(
    private val privateKey: (String) -> ByteArray?,
    private val unread: UnreadStore,
    private val installs: () -> List<Install>,
    private val signedInHosts: () -> List<String>,
    /** `New message in %1$s` (R.string.push_fallback_body). */
    private val fallbackBody: (String) -> String,
) {
    /** The map to present, the subtext, and the install's unread after this push. */
    data class Prepared(
        val data: Map<String, String?>,
        val subText: String?,
        val installHost: String?,
        val installUnread: Int?,
    ) {
        // The data can carry a title and a body: keys only.
        override fun toString(): String = "Prepared(keys=${data.keys.sorted()}, subText=${subText != null})"
    }

    fun prepare(data: Map<String, String?>): Prepared {
        val host = data["install_host"]?.let { InstallStore.normalizeHost(it) }
        val name = host?.let { h -> installs().firstOrNull { it.host == h }?.displayName ?: h }
        val relayed = host != null && data["kind"].isNullOrBlank()
        val presented = if (relayed) reveal(data, host!!, name!!) else data

        if (host != null) {
            val count = UnreadStore.parseCount(data["unread_count"])
            val asOf = UnreadStore.parseAsOf(data["unread_as_of"])
            if (count != null && asOf != null) unread.write(host, count, asOf)
        }
        val subText = if (host != null && signedInHosts().size >= 2) name else null
        return Prepared(presented, subText, host, host?.let { unread.entry(it)?.count })
    }

    private fun reveal(
        data: Map<String, String?>,
        host: String,
        name: String,
    ): Map<String, String?> {
        val sealed = data["sealed"]
        val key = privateKey(host)
        val inner = if (!sealed.isNullOrEmpty() && key != null) PushSeal.open(sealed, host, key) else null
        if (inner == null) {
            return mapOf("kind" to KIND_FALLBACK, "body" to fallbackBody(name), "install_host" to host)
        }
        // The install drops `body` to fit the 3,072-byte cap: still never blank.
        val body = inner["body"]?.takeIf { it.isNotBlank() } ?: fallbackBody(name)
        return inner - ROUTING_KEYS + ("body" to body) + ("install_host" to host)
    }

    companion object {
        /** Not a server kind: the generic layout, one per install (its tag repeats). */
        const val KIND_FALLBACK = "relay_fallback"

        /** The outer payload's routing keys win over the inner map's copies. */
        private val ROUTING_KEYS = setOf("install_host", "unread_count", "unread_as_of", "sealed")
    }
}
