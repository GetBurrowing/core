package com.koboai.burrow.shortcuts

import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat

/** Records every call; the dynamic set is what the launcher would hold. */
class RecordingShortcutSink(
    private val max: Int = 15,
    private val manifest: Int = 1,
) : ConversationShortcuts.ShortcutSink {
    val pushed = mutableListOf<ShortcutInfoCompat>()
    val removedDynamic = mutableListOf<String>()
    val removedLongLived = mutableListOf<String>()
    val reported = mutableListOf<String>()
    val dynamic = linkedMapOf<String, ShortcutInfoCompat>()

    override fun push(shortcut: ShortcutInfoCompat) {
        pushed.add(shortcut)
        dynamic[shortcut.id] = shortcut
    }

    override fun removeDynamic(ids: List<String>) {
        removedDynamic.addAll(ids)
        ids.forEach { dynamic.remove(it) }
    }

    override fun removeLongLived(ids: List<String>) {
        removedLongLived.addAll(ids)
    }

    override fun reportUsed(id: String) {
        reported.add(id)
    }

    override fun maxPerActivity(): Int = max

    override fun manifestCount(): Int = manifest
}

/**
 * ShortcutInfoCompat has no public getter for these two; read the fields the
 * builder sets (androidx.core 1.17).
 */
val ShortcutInfoCompat.longLivedForTest: Boolean
    get() =
        ShortcutInfoCompat::class.java
            .getDeclaredField("mIsLongLived")
            .apply { isAccessible = true }
            .getBoolean(this)

@Suppress("UNCHECKED_CAST")
val ShortcutInfoCompat.personsForTest: List<Person>
    get() =
        (
            ShortcutInfoCompat::class.java
                .getDeclaredField("mPersons")
                .apply { isAccessible = true }
                .get(this) as Array<Person>?
        )?.toList()
            .orEmpty()
