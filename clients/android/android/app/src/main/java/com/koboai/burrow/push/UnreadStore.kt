package com.koboai.burrow.push

import com.koboai.burrow.KeyValueStore
import java.time.Instant

/** One install's unread count as this phone last learned it. */
data class InstallUnread(
    /** The install's Chat unread total (`Chat.total_unread_for_viewer/1`). */
    val count: Int,
    /** The server's time for that count, epoch millis. Only a NEWER count replaces a stored one. */
    val asOfMillis: Long,
    /** The last refresh of this install failed; [count] is the last one known. */
    val stale: Boolean = false,
)

/**
 * Per-install unread counts (task 01a1261e stage 5), in the private prefs
 * file [FILE] (excluded from backup: a restored count is a wrong count).
 * Mirrors iOS `InstallUnreadStore`.
 *
 * - Pushes (`unread_count` / `unread_as_of`) and the reconcile on open
 *   (`GET /api/app/counts` `unread` / `as_of`) both write here. A write
 *   lands only when its as-of is newer than the stored one, so a late,
 *   older push cannot bring back a count the API already cleared.
 * - [total] and [othersUnread] read only [hosts], the signed-in installs,
 *   so a removed or signed-out install cannot keep a badge up;
 *   `InstallStore.remove` also clears its entry ([clear]).
 * - The one source for the unread number on this phone; the widgets'
 *   approvals/tasks cache (`CountsRepository`) is separate.
 */
class UnreadStore(
    private val prefs: KeyValueStore,
    private val hosts: () -> List<String>,
) {
    companion object {
        const val FILE = "burrow_unread"
        private const val PREFIX = "unread.v1."

        private fun key(host: String) = PREFIX + host.lowercase()

        /** Clears [host]'s entry in [prefs] (for `InstallStore.remove`). */
        fun clear(
            prefs: KeyValueStore,
            host: String,
        ) {
            prefs.remove(key(host))
        }

        /** The server's ISO-8601 time (`2026-10-10T15:00:00.123456Z`), epoch millis, or null. */
        fun parseAsOf(value: String?): Long? {
            if (value.isNullOrBlank()) return null
            return try {
                Instant.parse(value.trim()).toEpochMilli()
            } catch (_: Exception) {
                null
            }
        }

        /** A count from an FCM string value; negative or non-numeric is null. */
        fun parseCount(value: String?): Int? = value?.trim()?.toIntOrNull()?.takeIf { it >= 0 }
    }

    fun entry(host: String): InstallUnread? {
        val parts = prefs.getString(key(host))?.split('|') ?: return null
        if (parts.size != 3) return null
        val count = parts[0].toIntOrNull() ?: return null
        val asOf = parts[1].toLongOrNull() ?: return null
        return InstallUnread(count, asOf, parts[2] == "1")
    }

    /**
     * Stores [count] for [host] when [asOfMillis] is newer than what is
     * stored; returns whether it did. A count that loses still clears
     * `stale` when [clearStale] is set: a refresh that answered proves the
     * install is reachable, even if a push beat it.
     */
    fun write(
        host: String,
        count: Int,
        asOfMillis: Long,
        clearStale: Boolean = false,
    ): Boolean {
        val current = entry(host)
        if (current != null && asOfMillis <= current.asOfMillis) {
            if (clearStale && current.stale) save(host, current.copy(stale = false))
            return false
        }
        save(host, InstallUnread(maxOf(0, count), asOfMillis))
        return true
    }

    /** The last refresh of [host] failed: keep its count, mark it stale. */
    fun markStale(host: String) {
        val current = entry(host) ?: return
        save(host, current.copy(stale = true))
    }

    fun remove(host: String) = clear(prefs, host)

    /** The sum over signed-in installs. */
    val total: Int get() = hosts().sumOf { entry(it)?.count ?: 0 }

    /** Whether any signed-in install OTHER than [selectedHost] has unread: the shell's switcher dot. */
    fun othersUnread(selectedHost: String?): Boolean = hosts().any { it != selectedHost && (entry(it)?.count ?: 0) > 0 }

    /** Every signed-in install's entry, by host. */
    fun entries(): Map<String, InstallUnread> = hosts().mapNotNull { host -> entry(host)?.let { host to it } }.toMap()

    private fun save(
        host: String,
        value: InstallUnread,
    ) {
        prefs.putString(key(host), "${value.count}|${value.asOfMillis}|${if (value.stale) 1 else 0}")
    }

    override fun toString(): String = "UnreadStore(${prefs.keys().count { it.startsWith(PREFIX) }} hosts)"
}
