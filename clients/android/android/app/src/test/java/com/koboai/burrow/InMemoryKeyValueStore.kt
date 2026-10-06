package com.koboai.burrow

/** A [KeyValueStore] in memory, for the JVM tests. */
class InMemoryKeyValueStore : KeyValueStore {
    private val map = linkedMapOf<String, Any>()

    override fun getString(key: String): String? = map[key] as? String

    override fun putString(
        key: String,
        value: String,
    ) {
        map[key] = value
    }

    override fun getBoolean(key: String): Boolean = map[key] as? Boolean ?: false

    override fun putBoolean(
        key: String,
        value: Boolean,
    ) {
        map[key] = value
    }

    override fun remove(key: String) {
        map.remove(key)
    }

    override fun keys(): Set<String> = map.keys.toSet()

    /** Raw values, for tests that assert what is (not) stored. */
    fun rawValues(): Collection<Any> = map.values.toList()

    override fun toString(): String = "InMemoryKeyValueStore(${map.size} keys)"
}
