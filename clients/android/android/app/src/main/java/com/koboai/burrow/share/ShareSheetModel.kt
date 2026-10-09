package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import com.koboai.burrow.shortcuts.ConversationShortcuts
import java.util.Locale

/**
 * The share sheet's state with no UI in it, so every state is testable.
 * Mirrors `clients/ios/ios/Shared/ShareSheetModel.swift`; the size copy is
 * canvas 01a10d91 "Share target", verbatim.
 *
 * Every call is synchronous and may block on the network: [ShareActivity]
 * runs them off the main thread and renders the result.
 */
class ShareSheetModel(
    /** The selected install, or null when the app has none. */
    val host: String?,
    private val client: ShareClient,
    /** Files shared in; each becomes its own message. */
    val files: List<SharedFile>,
    /** A shared link or text, sent in the first message's `text`. */
    val sharedText: String?,
    /**
     * The space a direct-share target (a conversation shortcut) named, to
     * select once the spaces load. Ignored when that space is not listed.
     */
    val preselectSpaceId: String? = null,
    /** After a successful send: the conversation was used (publish and report). */
    private val onSent: (host: String, space: ShareSpace) -> Unit = { _, _ -> },
) {
    enum class Phase { LOADING_SPACES, NOT_SIGNED_IN, READY, SENDING, SENT }

    enum class Banner(
        val text: String,
    ) {
        SEND_FAILED("Couldn't send. Your item is still here. Try again."),
        SPACES_FAILED("Couldn't load your spaces. Check your connection and try again."),
    }

    var phase: Phase = Phase.LOADING_SPACES
        private set
    var spaces: List<ShareSpace> = emptyList()
        private set
    var selectedSpaceId: String? = null
        set(value) {
            if (field != value) selectedAgentId = null
            field = value
        }
    var selectedAgentId: String? = null
    var message: String = ""
    var banner: Banner? = null
        private set

    /** Files already accepted by the server, so a retry after a partial failure sends only the rest. */
    var sentFiles: Int = 0
        private set

    val selectedSpace: ShareSpace? get() = spaces.firstOrNull { it.id == selectedSpaceId }

    /** Back with something typed asks "Discard this share?"; with nothing typed it closes. */
    val hasTypedText: Boolean get() = message.isNotBlank()

    val size: SizeCheck get() = SizeCheck.of(files) { file, first -> form(file, first).contentLength() }

    val sendLabel: String get() = size.sendLabel

    val canSend: Boolean
        get() {
            if (phase != Phase.READY || selectedSpace == null) return false
            if (size.blocked) return false
            return size.sendable.isNotEmpty() || firstText().isNotEmpty()
        }

    /** Checks for a bearer BEFORE any request: signed out makes no network call. */
    fun start() {
        val host = host
        if (host == null || !client.isSignedIn(host)) {
            phase = Phase.NOT_SIGNED_IN
            return
        }
        loadSpaces()
    }

    fun loadSpaces() {
        val host = host ?: return
        phase = Phase.LOADING_SPACES
        if (banner == Banner.SPACES_FAILED) banner = null
        try {
            spaces = client.spaces(host)
            if (selectedSpaceId == null) {
                selectedSpaceId =
                    preselectSpaceId?.takeIf { id -> spaces.any { it.id == id } }
                        ?: spaces.singleOrNull()?.id
            }
            phase = Phase.READY
        } catch (e: ApiException) {
            if (signedOut(e)) {
                phase = Phase.NOT_SIGNED_IN
            } else {
                banner = Banner.SPACES_FAILED
                phase = Phase.READY
            }
        }
    }

    /**
     * Sends one message per sendable file (the controller takes one `file`
     * per request), `text` and the agent on the FIRST request only, so the
     * note and the mention appear once. With no file, one text message.
     * Oversized files are never uploaded. True when everything was sent.
     */
    fun send(): Boolean {
        if (!canSend) return false
        val host = host ?: return false
        val space = selectedSpace ?: return false
        banner = null
        phase = Phase.SENDING
        return try {
            for (form in requests()) {
                client.send(host, space.id, form)
                if (form.file != null) sentFiles++ else textSent = true
            }
            phase = Phase.SENT
            onSent(host, space)
            true
        } catch (e: ApiException) {
            if (signedOut(e)) {
                phase = Phase.NOT_SIGNED_IN
            } else {
                banner = Banner.SEND_FAILED
                phase = Phase.READY
            }
            false
        }
    }

    private var textSent = false

    /** The requests [send] makes, in order, for what is still unsent. */
    fun requests(): List<MultipartForm> {
        val remaining = size.sendable.drop(sentFiles)
        val textFirst = sentFiles == 0 && !textSent
        if (remaining.isEmpty()) {
            return if (textFirst && firstText().isNotEmpty()) listOf(form(null, true)) else emptyList()
        }
        return remaining.mapIndexed { i, file -> form(file, i == 0 && textFirst) }
    }

    /** The message, then the shared link or text on its own line (iOS `SharePayload.form`). */
    fun firstText(): String = listOf(message.trim(), sharedText?.trim().orEmpty()).filter { it.isNotEmpty() }.joinToString("\n")

    private fun form(
        file: SharedFile?,
        first: Boolean,
    ): MultipartForm {
        val fields = mutableListOf<Pair<String, String>>()
        if (first) {
            firstText().takeIf { it.isNotEmpty() }?.let { fields.add("text" to it) }
            selectedAgentId?.takeIf { it.isNotEmpty() }?.let { fields.add("agent_id" to it) }
        }
        return MultipartForm(fields, file)
    }

    private fun signedOut(e: ApiException) =
        e.kind == ApiException.Kind.NOT_SIGNED_IN || (e.kind == ApiException.Kind.STATUS && e.status == 401)

    companion object {
        /**
         * Which install and space a share opens on. A direct-share target
         * carries its shortcut id (`<host>|<spaceId>`): when that parses and
         * its host is signed in, the share goes to THAT host with the space
         * preselected. Anything else is today's behaviour: the selected
         * install, nothing preselected.
         */
        fun target(
            shortcutId: String?,
            selectedHost: String?,
            isSignedIn: (String) -> Boolean,
        ): Pair<String?, String?> {
            val parsed = shortcutId?.let { ConversationShortcuts.parse(it) } ?: return selectedHost to null
            val (host, spaceId) = parsed
            return if (isSignedIn(host)) host to spaceId else selectedHost to null
        }

        const val NOT_SIGNED_IN_TEXT = "Sign in to Burrow first. Open the Burrow app, sign in, then share again."

        /** "12.4 MB": decimal megabytes, one decimal place, as the canvas copy reads. */
        fun megabytes(bytes: Long): String = String.format(Locale.US, "%.1f MB", bytes / 1_000_000.0)

        /** A preview row's size: kB under 1 MB (so a note does not read "0.0 MB"), else [megabytes]. */
        fun rowSize(bytes: Long): String = if (bytes < 1_000_000) "${(bytes + 999) / 1000} kB" else megabytes(bytes)
    }
}

/**
 * Which files can be sent, decided before Send is enabled.
 *
 * A file is over the limit when it is larger than [MAX_SHARE_FILE_BYTES]
 * (8 MiB, the planner's constant) OR when its request would exceed
 * [MAX_REQUEST_BYTES]: the server's Plug.Parsers multipart `:length` is
 * 8_000_000 bytes for the WHOLE body (iOS `SuiteAPIClient.maxRequestBytes`),
 * which is smaller than 8 MiB, so the 8 MiB check alone would let an 8.2 MB
 * file through to a 413. Both are "over 8 MB" in the copy.
 */
data class SizeCheck(
    val sendable: List<SharedFile>,
    val oversized: List<SharedFile>,
    /** The notice line, or null when nothing is over. */
    val notice: String?,
    /** True when nothing can be sent because every file is over. */
    val blocked: Boolean,
    val sendLabel: String,
) {
    companion object {
        const val MAX_SHARE_FILE_BYTES: Long = 8L * 1024 * 1024
        const val MAX_REQUEST_BYTES: Long = 8_000_000L

        fun of(
            files: List<SharedFile>,
            requestBytes: (SharedFile, Boolean) -> Long,
        ): SizeCheck {
            // A file's request carries the text only when it is the first sendable one;
            // measure each WITH the text, the larger case.
            val over = files.filter { it.size > MAX_SHARE_FILE_BYTES || requestBytes(it, true) > MAX_REQUEST_BYTES }
            val ok = files.filter { it !in over }
            val n = files.size
            val k = over.size
            return when {
                k == 0 -> SizeCheck(ok, over, null, false, "Send")
                n == 1 ->
                    SizeCheck(
                        ok,
                        over,
                        "${over.single().name} is ${ShareSheetModel.megabytes(over.single().size)}. Burrow can send files up to 8 MB each.",
                        true,
                        "Send",
                    )
                k == n -> SizeCheck(ok, over, "These files are each over 8 MB. Burrow can send files up to 8 MB each.", true, "Send")
                else -> SizeCheck(ok, over, "$k of $n files are over 8 MB and won't be sent.", false, "Send ${n - k}")
            }
        }
    }
}
