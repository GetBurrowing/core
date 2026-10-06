package com.koboai.burrow

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/**
 * The few SharedPreferences operations the stores use, behind an interface
 * so the JVM unit tests run them against [InMemoryKeyValueStore] without an
 * Android runtime.
 */
interface KeyValueStore {
    fun getString(key: String): String?

    fun putString(
        key: String,
        value: String,
    )

    fun getBoolean(key: String): Boolean

    fun putBoolean(
        key: String,
        value: Boolean,
    )

    fun remove(key: String)

    fun keys(): Set<String>
}

/** A private SharedPreferences file. */
class SharedPreferencesStore(
    private val prefs: SharedPreferences,
) : KeyValueStore {
    constructor(context: Context, name: String) : this(context.getSharedPreferences(name, Context.MODE_PRIVATE))

    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(
        key: String,
        value: String,
    ) {
        prefs.edit { putString(key, value) }
    }

    override fun getBoolean(key: String): Boolean = prefs.getBoolean(key, false)

    override fun putBoolean(
        key: String,
        value: Boolean,
    ) {
        prefs.edit { putBoolean(key, value) }
    }

    override fun remove(key: String) {
        prefs.edit { remove(key) }
    }

    override fun keys(): Set<String> = prefs.all.keys

    /** Names only, never values: some files hold ciphertext. */
    override fun toString(): String = "SharedPreferencesStore(${prefs.all.size} keys)"
}
