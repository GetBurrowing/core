package com.koboai.burrow.shortcuts

import androidx.core.app.Person
import com.koboai.burrow.ApiException
import com.koboai.burrow.share.ShareClient
import com.koboai.burrow.share.ShareSpace

/** One recipient of a sent message, as 01a111bb's `native_donate` names it. */
data class Recipient(
    val type: String,
    val id: String,
)

/** The outcome of noting a conversation. */
sealed class NoteResult {
    data class Noted(
        val shortcutId: String,
    ) : NoteResult()

    data class Rejected(
        val code: String,
    ) : NoteResult()
}

/** What `donate` drives for `message_sent`; [ConversationNoter] in the app, a recorder in tests. */
fun interface Noter {
    fun note(
        host: String?,
        spaceId: String,
        recipients: List<Recipient>,
    ): NoteResult
}

/**
 * Turns "the person sent a message in this space" (the web view's
 * `native_donate` with kind `message_sent`) into a used conversation
 * shortcut. The donation carries ids only, so the space's name, kind and
 * path come from `GET /api/app/spaces` on the install's own bearer, cached
 * per host for [CACHE_MILLIS] with one refetch on a miss (a space created
 * since the last fetch).
 *
 * Blocks on the network: call it off the main thread.
 */
class ConversationNoter(
    private val client: ShareClient,
    private val shortcuts: ConversationShortcuts,
    private val clock: () -> Long = System::currentTimeMillis,
) : Noter {
    private class Cached(
        val at: Long,
        val spaces: List<ShareSpace>,
    )

    private val cache = mutableMapOf<String, Cached>()

    override fun note(
        host: String?,
        spaceId: String,
        recipients: List<Recipient>,
    ): NoteResult {
        if (!ID.matches(spaceId)) return NoteResult.Rejected(BAD_SPACE)
        if (host == null || !client.isSignedIn(host)) return NoteResult.Rejected(NOT_SIGNED_IN)
        val space =
            try {
                find(host, spaceId)
            } catch (_: ApiException) {
                return NoteResult.Rejected(SPACES_FAILED)
            } ?: return NoteResult.Rejected(UNKNOWN_SPACE)
        val isGroup = space.kind != "dm"
        val persons =
            recipients
                .filter { it.type in TYPES && ID.matches(it.id) }
                .map { r ->
                    Person
                        .Builder()
                        .setKey("$host|${r.type}:${r.id}")
                        // A dm's name is the other person's (GET /api/app/spaces names a dm after them).
                        .apply { if (!isGroup) setName(space.name) }
                        .build()
                }
        val id =
            shortcuts.noteUsed(
                host = host,
                spaceId = space.id,
                name = space.name,
                path = "/chat/${space.pathSegment ?: space.id}",
                persons = persons,
                isGroup = isGroup,
            ) ?: return NoteResult.Rejected(NO_ROOM)
        return NoteResult.Noted(id)
    }

    private fun find(
        host: String,
        spaceId: String,
    ): ShareSpace? {
        val now = clock()
        val cached = synchronized(cache) { cache[host] }?.takeIf { now - it.at < CACHE_MILLIS }
        cached?.spaces?.firstOrNull { it.id == spaceId }?.let { return it }
        // Stale, absent, or a miss on a fresh list: fetch once.
        val spaces = client.spaces(host)
        synchronized(cache) { cache[host] = Cached(now, spaces) }
        return spaces.firstOrNull { it.id == spaceId }
    }

    companion object {
        const val CACHE_MILLIS = 10 * 60 * 1000L
        const val BAD_SPACE = "bad_space"
        const val NOT_SIGNED_IN = "not_signed_in"
        const val UNKNOWN_SPACE = "unknown_space"
        const val SPACES_FAILED = "spaces_failed"
        const val NO_ROOM = "no_room"
        private val TYPES = setOf("user", "agent")
        private val ID = Regex("^[A-Za-z0-9_-]{1,128}$")
    }
}

/**
 * `SuiteNative.donate(detail)`, without the plugin: only `message_sent`
 * does anything (it notes the conversation). Every other kind, known
 * (`task_created`, `approval_acted`, `meeting_started`) or not, resolves ok
 * and touches nothing. The detail is ids only; nothing here reads text.
 */
object DonateDispatch {
    const val MESSAGE_SENT = "message_sent"

    sealed class Outcome {
        object Ok : Outcome()

        data class Rejected(
            val code: String,
        ) : Outcome()
    }

    fun dispatch(
        kind: String?,
        spaceId: String?,
        recipients: List<Recipient>,
        host: String?,
        noter: Noter,
    ): Outcome {
        if (kind != MESSAGE_SENT) return Outcome.Ok
        if (spaceId == null) return Outcome.Rejected(ConversationNoter.BAD_SPACE)
        return when (val result = noter.note(host, spaceId, recipients)) {
            is NoteResult.Noted -> Outcome.Ok
            is NoteResult.Rejected -> Outcome.Rejected(result.code)
        }
    }
}
