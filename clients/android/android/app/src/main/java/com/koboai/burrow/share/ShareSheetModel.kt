package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import com.koboai.burrow.shortcuts.ConversationShortcuts

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
    /** Where a file over the multipart threshold goes (task 01a120be): WorkManager in the app. */
    private val enqueuer: LargeUploadEnqueuer = LargeUploadEnqueuer { _, _, _, _ -> throw java.io.IOException("no uploader") },
    /** After a successful send: the conversation was used (publish and report). Last, so a trailing lambda binds it. */
    private val onSent: (host: String, space: ShareSpace) -> Unit = { _, _ -> },
) {
    /**
     * HANDED_OFF: at least one large file went to the background uploader;
     * the sheet says [HANDED_OFF_TEXT] and closes at once. The server posts
     * each such message when its last chunk lands.
     */
    enum class Phase { LOADING_SPACES, NOT_SIGNED_IN, READY, SENDING, SENT, HANDED_OFF }

    /** The install's limits (`GET /api/app/upload_config`); null on a server that predates it. */
    var uploadConfig: UploadConfig? = null
        private set

    enum class Banner(
        val text: String,
    ) {
        SEND_FAILED("Couldn't send. Your item is still here. Try again."),
        SPACES_FAILED("Couldn't load your spaces. Check your connection and try again."),

        /** The install answered with a redirect: it moved. [bannerText] names where. */
        INSTALL_MOVED("This Suite has moved. Open Burrow and sign in to its new address, then share again."),
    }

    /** The host a redirecting install points at, when [Banner.INSTALL_MOVED] knows it. */
    var movedTo: String? = null
        private set

    /** What the banner says: [Banner.text], with a moved install's new host filled in. */
    val bannerText: String?
        get() {
            val b = banner ?: return null
            val to = movedTo
            return if (b == Banner.INSTALL_MOVED && to != null) {
                "This Suite moved to $to. Open Burrow, add $to and sign in there, then share again."
            } else {
                b.text
            }
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

    /**
     * With the space list unreachable and no [uploadConfig], the sheet never
     * heard from the install, so it makes no claim about its limits: the "8 MB"
     * copy is for a server that predates `upload_config`, not one we could not
     * reach. Nothing is sendable then anyway (no space can be chosen).
     */
    val size: SizeCheck
        get() {
            val unreachable = banner == Banner.SPACES_FAILED || banner == Banner.INSTALL_MOVED
            if (unreachable && uploadConfig == null) return SizeCheck(files, emptyList(), null, false, "Send")
            return SizeCheck.of(files, uploadConfig) { file, first -> form(file, first).contentLength() }
        }

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
        if (banner == Banner.SPACES_FAILED || banner == Banner.INSTALL_MOVED) banner = null
        movedTo = null
        try {
            spaces = client.spaces(host)
            if (selectedSpaceId == null) {
                selectedSpaceId =
                    preselectSpaceId?.takeIf { id -> spaces.any { it.id == id } }
                        ?: spaces.singleOrNull()?.id
            }
        } catch (e: ApiException) {
            if (signedOut(e)) {
                phase = Phase.NOT_SIGNED_IN
                return
            }
            if (e.kind == ApiException.Kind.STATUS && e.status in 300..399) {
                banner = Banner.INSTALL_MOVED
                movedTo = e.movedTo
            } else {
                banner = Banner.SPACES_FAILED
            }
        }
        // Asked whether or not the space list loaded: one failed call must not
        // turn into a wrong "8 MB" limit on an install that takes 1 GB.
        uploadConfig = client.uploadConfig(host)
        phase = Phase.READY
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
        val chunked = size.chunked
        var handedOff = false
        return try {
            for (form in requests()) {
                val file = form.file
                if (file != null && file in chunked) {
                    // Over the multipart threshold: reserve, then the
                    // background uploader PATCHes the chunks.
                    val reservation =
                        client.reserveUpload(host, space.id, file, form.field("text"), form.field("agent_id"))
                    enqueuer.enqueue(host, reservation, file, space.name)
                    handedOff = true
                } else {
                    client.send(host, space.id, form)
                }
                if (file != null) sentFiles++ else textSent = true
            }
            phase = if (handedOff) Phase.HANDED_OFF else Phase.SENT
            onSent(host, space)
            true
        } catch (_: java.io.IOException) {
            banner = Banner.SEND_FAILED
            phase = Phase.READY
            false
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

        /** Design canvas 01a120be-f336, share sheet. */
        const val HANDED_OFF_TEXT = "Uploading in the background. You can close this."
    }
}

/**
 * Which files can be sent, and how, decided before Send is enabled.
 *
 * With the server's [UploadConfig] (task 01a120be): a file over its
 * `max_upload_bytes` is over, named with the server's label; a file whose
 * multipart REQUEST would pass `multipart_max_bytes` is [chunked] (sent by
 * the background uploader); the rest keep the multipart POST. The
 * threshold counts the whole request body (Plug.Parsers' multipart
 * `:length`), so routing measures the request, not just the file.
 *
 * Without it (a server that predates `upload_config`) only the multipart
 * path exists: a file whose request would pass [MAX_REQUEST_BYTES] is over,
 * with the "8 MB" copy (canvas 01a10d91).
 */
data class SizeCheck(
    val sendable: List<SharedFile>,
    val oversized: List<SharedFile>,
    /** The notice line, or null when nothing is over. */
    val notice: String?,
    /** True when nothing can be sent because every file is over. */
    val blocked: Boolean,
    val sendLabel: String,
    /** The sendable files that go the chunked way. */
    val chunked: List<SharedFile> = emptyList(),
) {
    companion object {
        /** The multipart transport threshold only (Plug.Parsers' `:length`), never the per-file limit. */
        const val MAX_REQUEST_BYTES: Long = 8_000_000L

        fun of(
            files: List<SharedFile>,
            config: UploadConfig?,
            requestBytes: (SharedFile, Boolean) -> Long,
        ): SizeCheck {
            // A file's request carries the text only when it is the first sendable one;
            // measure each WITH the text, the larger case.
            val multipartMax = config?.multipartMaxBytes ?: MAX_REQUEST_BYTES
            val over =
                if (config == null) {
                    files.filter { requestBytes(it, true) > multipartMax }
                } else {
                    files.filter { it.size > config.maxUploadBytes }
                }
            val ok = files.filter { it !in over }
            val chunked = if (config == null) emptyList() else ok.filter { requestBytes(it, true) > multipartMax }
            val n = files.size
            val k = over.size
            val limit = config?.maxUploadLabel ?: "8 MB"
            return when {
                k == 0 -> SizeCheck(ok, over, null, false, "Send", chunked)
                n == 1 ->
                    SizeCheck(
                        ok,
                        over,
                        if (config == null) {
                            "${over.single().name} is ${ByteLabel.format(over.single().size)}. Burrow can send files up to 8 MB each."
                        } else {
                            "${over.single().name} is ${ByteLabel.format(over.single().size)}. This Suite accepts files up to $limit."
                        },
                        true,
                        "Send",
                        chunked,
                    )
                k == n ->
                    SizeCheck(
                        ok,
                        over,
                        if (config == null) {
                            "These files are each over 8 MB. Burrow can send files up to 8 MB each."
                        } else {
                            "These files are each over $limit. This Suite accepts files up to $limit."
                        },
                        true,
                        "Send",
                        chunked,
                    )
                else -> SizeCheck(ok, over, "$k of $n files are over $limit and won't be sent.", false, "Send ${n - k}", chunked)
            }
        }
    }
}
