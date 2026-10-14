package com.koboai.burrow.push

import com.koboai.burrow.InstallStore
import com.koboai.burrow.shortcuts.ConversationShortcuts

/**
 * One push, parsed from the FCM `message.data` map the server builds in
 * `Platform.Push.Notification.to_fcm_payload/1`. FCM data values are always
 * strings, and the server drops nil and empty values, so every field but
 * [kind] is optional here.
 *
 * Routing is by [installHost]: the bearer for a reply, the channel group,
 * the group key and the install Open switches to all come from it.
 */
data class PushPayload(
    val kind: String,
    val title: String?,
    val body: String?,
    val url: String?,
    val spaceId: String?,
    val messageId: String?,
    val taskId: String?,
    val inboxItemId: String?,
    val installHost: String?,
    val authorName: String?,
    val spaceName: String?,
    /** The space's kind (`dm`, `group`, `channel`, ...); FCM only (task 01a116c4). */
    val spaceKind: String? = null,
    /** The author participant's id (task 01a111bb), id-shaped or null. */
    val authorId: String? = null,
    /** `user` or `agent`; anything else is null. */
    val authorType: String? = null,
    /**
     * The sender's picture (task 01a12773): an absolute https url, or null.
     * On the install's own host it takes the bearer; anywhere else it is
     * fetched with none (push/AvatarFetcher.kt).
     */
    val authorAvatarUrl: String? = null,
    /** The letter disc's colour: `agent`, or the in-app palette index `0`..`7`; else null. */
    val authorAvatarTone: String? = null,
) {
    val isMention: Boolean get() = kind == KIND_MENTION

    /**
     * A chat message: a mention, or any other message the server pushes
     * (`chat_message`, for the `:all`, `:active` and `:here` reasons). Both
     * are conversations with a sender and a Reply.
     */
    val isChat: Boolean get() = kind in CHAT_KINDS
    val isApproval: Boolean get() = kind in APPROVAL_KINDS

    /** Reply needs a host to post to, a space and the message replied to. */
    val canReply: Boolean get() = isChat && installHost != null && spaceId != null && messageId != null

    /**
     * The conversation shortcut's id (`<host>|<spaceId>`), for a chat push
     * that names both. A redacted push has no space_id, so it has none.
     */
    val shortcutId: String?
        get() = if (isChat && installHost != null && spaceId != null) ConversationShortcuts.shortcutId(installHost, spaceId) else null

    /** The path Open loads: the server-built url when it is local, else `/`. */
    val openPath: String get() = safePath(url)

    /**
     * Notifications in one group stack together: mentions per space,
     * approvals together, both per install. Anything else is not grouped.
     */
    val groupKey: String?
        get() =
            when {
                isChat && spaceId != null -> "mentions:${installHost.orEmpty()}:$spaceId"
                isApproval -> "approvals:${installHost.orEmpty()}"
                else -> null
            }

    /** Identifies this notification within the app, so a reply updates it in place. */
    val tag: String
        get() {
            val id = messageId ?: inboxItemId ?: taskId ?: spaceId ?: (title.orEmpty() + body.orEmpty()).hashCode().toString()
            return "$kind:${installHost.orEmpty()}:$id"
        }

    /** The data map back again (for intents), with only the keys that were present. */
    fun toData(): Map<String, String> =
        listOf(
            "kind" to kind,
            "title" to title,
            "body" to body,
            "url" to url,
            "space_id" to spaceId,
            "message_id" to messageId,
            "task_id" to taskId,
            "inbox_item_id" to inboxItemId,
            "install_host" to installHost,
            "author_name" to authorName,
            "space_name" to spaceName,
            "space_kind" to spaceKind,
            "author_id" to authorId,
            "author_type" to authorType,
            "author_avatar_url" to authorAvatarUrl,
            "author_avatar_tone" to authorAvatarTone,
        ).mapNotNull { (k, v) -> v?.let { k to it } }.toMap()

    /** Field names and the kind only: a body or title can be private. */
    override fun toString(): String = "PushPayload(kind=$kind, keys=${toData().keys.sorted()})"

    companion object {
        const val KIND_MENTION = "chat_mention"
        const val KIND_MESSAGE = "chat_message"
        val CHAT_KINDS = setOf(KIND_MENTION, KIND_MESSAGE)
        val AUTHOR_TYPES = setOf("user", "agent")
        val AVATAR_TONES = setOf("agent") + (0..7).map { it.toString() }
        private const val MAX_URL = 2_048
        val APPROVAL_KINDS = setOf("task_plan_review", "review_request_pending")

        // Ids go into a request path (`/api/app/spaces/<space_id>/messages`):
        // anything but an id-shaped value is dropped, never interpolated.
        private val ID = Regex("^[A-Za-z0-9_-]{1,128}$")

        /** An absolute https url of sane length; anything else is no picture. */
        private fun isAvatarUrl(url: String): Boolean = url.startsWith("https://", ignoreCase = true) && url.length <= MAX_URL

        /** Parses an FCM data map. A blank value counts as missing. */
        fun from(data: Map<String, String?>): PushPayload {
            fun value(key: String): String? = data[key]?.trim()?.ifEmpty { null }
            return PushPayload(
                kind = value("kind") ?: "generic",
                title = value("title"),
                body = value("body"),
                url = value("url"),
                spaceId = value("space_id")?.takeIf { ID.matches(it) },
                messageId = value("message_id")?.takeIf { ID.matches(it) },
                taskId = value("task_id"),
                inboxItemId = value("inbox_item_id"),
                installHost = value("install_host")?.let { InstallStore.normalizeHost(it) },
                authorName = value("author_name"),
                spaceName = value("space_name"),
                spaceKind = value("space_kind"),
                authorId = value("author_id")?.takeIf { ID.matches(it) },
                authorType = value("author_type")?.takeIf { it in AUTHOR_TYPES },
                authorAvatarUrl = value("author_avatar_url")?.takeIf { isAvatarUrl(it) },
                authorAvatarTone = value("author_avatar_tone")?.takeIf { it in AVATAR_TONES },
            )
        }

        /**
         * The Open guard. Only a path on the install itself is loaded: it must
         * start with exactly one `/`. `//evil` (protocol-relative), `/\evil`
         * (browsers read `\` as `/`), an absolute URL, whitespace or a control
         * character all fall back to `/`. The app never builds a URL from a
         * slug: the server's `url` is used as is.
         */
        fun safePath(url: String?): String {
            if (url == null) return "/"
            if (!url.startsWith("/")) return "/"
            if (url.length > 1 && (url[1] == '/' || url[1] == '\\')) return "/"
            if (url.any { it.isWhitespace() || it.isISOControl() || it == '\\' }) return "/"
            return url
        }

        /** "3 approvals"; "4 new in Internal Fabrikam SXI". */
        fun summaryText(
            payload: PushPayload,
            count: Int,
        ): String =
            if (payload.isApproval) {
                if (count == 1) "1 approval" else "$count approvals"
            } else {
                "$count new in ${payload.spaceName ?: "Burrow"}"
            }
    }
}
