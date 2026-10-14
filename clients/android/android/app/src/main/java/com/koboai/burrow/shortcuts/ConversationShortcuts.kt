package com.koboai.burrow.shortcuts

import android.content.Context
import android.content.Intent
import android.os.PersistableBundle
import androidx.core.app.Person
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.koboai.burrow.InstallStore
import com.koboai.burrow.KeyValueStore
import com.koboai.burrow.LaunchRouter
import com.koboai.burrow.MainActivity
import com.koboai.burrow.SharedPreferencesStore
import com.koboai.burrow.push.BurrowPush
import com.koboai.burrow.push.PushPayload

/**
 * Long-lived conversation shortcuts, one per chat space per install, so
 * Android treats a chat notification as a conversation (the Conversations
 * section, people and priority settings, and the share sheet's direct
 * targets).
 *
 * The id is `<host>|<spaceId>`, so two installs never share one; a
 * notification's shortcutId and locusId are that same id.
 *
 * Shortcut count: the launcher caps shortcuts per activity, and the static
 * `switch_install` entry counts toward that cap. Dynamic shortcuts are
 * therefore capped at `max - manifest`. A registry (prefs file
 * [PREFS_FILE], excluded from backup) records when each id was last used,
 * and the least recently used is evicted first. Only ids from the registry
 * are ever removed: never `switch_install`, never every dynamic shortcut.
 */
class ConversationShortcuts(
    private val context: Context,
    private val sink: ShortcutSink,
    private val registry: KeyValueStore,
    /**
     * The install's name when two or more installs are signed in, else null
     * (BurrowPush.installLabel). Android 11+ draws a conversation
     * notification's title from its shortcut's label, so the label is where
     * `launch · B` has to live (task 01a1261e, measured on API 35).
     */
    private val installLabel: (String) -> String? = { null },
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** What the shortcut system does; [SystemShortcutSink] in the app, a recorder in tests. */
    interface ShortcutSink {
        fun push(shortcut: ShortcutInfoCompat)

        fun removeDynamic(ids: List<String>)

        fun removeLongLived(ids: List<String>)

        fun reportUsed(id: String)

        fun maxPerActivity(): Int

        fun manifestCount(): Int
    }

    /**
     * Publishes (or refreshes) the conversation shortcut for [spaceId] on
     * [host] and returns its id, or null when it cannot be published (a bad
     * host or id, or no room). Call it before posting the notification that
     * names the id. [icon] is a DM's sender face (task 01a12773); null keeps
     * the space-name monogram, which every channel and group uses.
     */
    fun publish(
        host: String,
        spaceId: String,
        name: String,
        path: String,
        persons: List<Person>,
        isGroup: Boolean = true,
        icon: IconCompat? = null,
    ): String? {
        val id = shortcutId(host, spaceId) ?: return null
        val cap = maxOf(0, sink.maxPerActivity() - sink.manifestCount())
        if (cap == 0) return null
        registry.putString(id, clock().toString())
        evictBeyond(cap)
        sink.push(build(id, host, name, path, persons, isGroup, icon))
        return id
    }

    /**
     * The person just used this conversation (sent into it from the web
     * view, a Reply or a share): [publish] it, then report the use so the
     * launcher and share sheet rank it. Returns the id, or null.
     */
    fun noteUsed(
        host: String,
        spaceId: String,
        name: String,
        path: String,
        persons: List<Person>,
        isGroup: Boolean = true,
        icon: IconCompat? = null,
    ): String? {
        val id = publish(host, spaceId, name, path, persons, isGroup, icon) ?: return null
        sink.reportUsed(id)
        return id
    }

    /** Removes every conversation shortcut of [host] (after a sign-out). */
    fun removeForHost(host: String) {
        val normalized = InstallStore.normalizeHost(host) ?: return
        val prefix = "$normalized$SEPARATOR"
        remove(registry.keys().filter { it.startsWith(prefix) })
    }

    internal fun build(
        id: String,
        host: String,
        name: String,
        path: String,
        persons: List<Person>,
        isGroup: Boolean = true,
        icon: IconCompat? = null,
    ): ShortcutInfoCompat {
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(LaunchRouter.ACTION_OPEN_CONVERSATION)
                .putExtra(LaunchRouter.EXTRA_CONVERSATION_HOST, host)
                .putExtra(LaunchRouter.EXTRA_CONVERSATION_PATH, path)
        return ShortcutInfoCompat
            .Builder(context, id)
            .setShortLabel(label(host, name))
            .setLongLived(true)
            .setLocusId(LocusIdCompat(id))
            // SHARE_TARGET: the share sheet's direct-share row (API 29+; the
            // <share-target> in shortcuts.xml names the same category).
            .setCategories(setOf(CATEGORY_CONVERSATION, CATEGORY_SHARE_TARGET))
            .setPersons(persons.toTypedArray())
            .setExtras(PersistableBundle().apply { putBoolean(EXTRA_IS_GROUP, isGroup) })
            .setIcon(icon ?: Monogram.shortcutIcon(name))
            .setIntent(intent)
            .build()
    }

    /** `<name> · <install>` with two or more installs signed in, else [name]. */
    internal fun label(
        host: String,
        name: String,
    ): String = installLabel(host)?.let { "$name · $it" } ?: name

    private fun evictBeyond(cap: Int) {
        val used = registry.keys().associateWith { registry.getString(it)?.toLongOrNull() ?: 0L }
        val excess = used.size - cap
        if (excess <= 0) return
        remove(
            used.entries
                .sortedBy { it.value }
                .take(excess)
                .map { it.key },
        )
    }

    private fun remove(ids: List<String>) {
        val removable = ids.filter { it != SWITCH_INSTALL_ID && parse(it) != null }
        if (removable.isEmpty()) return
        removable.forEach { registry.remove(it) }
        sink.removeDynamic(removable)
        sink.removeLongLived(removable)
    }

    companion object {
        const val PREFS_FILE = "burrow_shortcuts"
        const val CATEGORY_CONVERSATION = "android.shortcut.conversation"

        /** The `<share-target>` category in res/xml/shortcuts.xml (both variants). */
        const val CATEGORY_SHARE_TARGET = "com.koboai.burrow.category.SHARE_TARGET"
        const val EXTRA_IS_GROUP = "com.koboai.burrow.extra.IS_GROUP"

        /** The static launcher shortcut (res/xml/shortcuts.xml); never removed here. */
        const val SWITCH_INSTALL_ID = "switch_install"
        private const val SEPARATOR = "|"
        private val ID = Regex("^[A-Za-z0-9_-]{1,128}$")

        /** `<host>|<spaceId>`, or null when either part is not valid. */
        fun shortcutId(
            host: String,
            spaceId: String,
        ): String? {
            val normalized = InstallStore.normalizeHost(host) ?: return null
            if (!ID.matches(spaceId)) return null
            return "$normalized$SEPARATOR$spaceId"
        }

        /** The (host, spaceId) of a [shortcutId], or null for anything else. */
        fun parse(id: String): Pair<String, String>? {
            val host = id.substringBefore(SEPARATOR, missingDelimiterValue = "")
            val spaceId = id.substringAfter(SEPARATOR, missingDelimiterValue = "")
            if (host.isEmpty() || shortcutId(host, spaceId) != id) return null
            return host to spaceId
        }

        /**
         * The conversation's `/chat/<segment>` path, query stripped, from the
         * server's url; `/chat/<spaceId>` when the url is not a chat path.
         */
        fun conversationPath(
            url: String?,
            spaceId: String,
        ): String {
            val path = PushPayload.safePath(url).substringBefore('?').substringBefore('#')
            val segment = path.removePrefix("/chat/")
            return if (path.startsWith("/chat/") && segment.isNotEmpty() && '/' !in segment) path else "/chat/$spaceId"
        }

        fun forContext(context: Context): ConversationShortcuts {
            val app = context.applicationContext
            return ConversationShortcuts(
                app,
                sinkOverride ?: SystemShortcutSink(app),
                SharedPreferencesStore(app, PREFS_FILE),
                installLabel = { host -> BurrowPush.installLabel(app, host) },
            )
        }

        /** Tests swap in a recorder. */
        @Volatile
        internal var sinkOverride: ShortcutSink? = null
    }
}

/** The real shortcut system. */
class SystemShortcutSink(
    private val context: Context,
) : ConversationShortcuts.ShortcutSink {
    override fun push(shortcut: ShortcutInfoCompat) {
        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }

    override fun removeDynamic(ids: List<String>) {
        ShortcutManagerCompat.removeDynamicShortcuts(context, ids)
    }

    override fun removeLongLived(ids: List<String>) {
        ShortcutManagerCompat.removeLongLivedShortcuts(context, ids)
    }

    override fun reportUsed(id: String) {
        ShortcutManagerCompat.reportShortcutUsed(context, id)
    }

    override fun maxPerActivity(): Int = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)

    override fun manifestCount(): Int = ShortcutManagerCompat.getShortcuts(context, ShortcutManagerCompat.FLAG_MATCH_MANIFEST).size
}
