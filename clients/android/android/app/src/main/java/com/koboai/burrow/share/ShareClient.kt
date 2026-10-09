package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import com.koboai.burrow.AppApiClient
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException

/** A space the person can post into (`GET /api/app/spaces`), with its agents. */
data class ShareSpace(
    val id: String,
    val name: String,
    val pathSegment: String?,
    val agents: List<Agent>,
    /** `dm`, `group`, `channel`, ...; null when the server sent none. */
    val kind: String? = null,
) {
    data class Agent(
        val id: String,
        val name: String,
    )
}

/** The share sheet's two calls, behind an interface so the model is testable. */
interface ShareClient {
    fun isSignedIn(host: String): Boolean

    /** Throws [ApiException]. */
    fun spaces(host: String): List<ShareSpace>

    /** One `POST /api/app/spaces/<id>/messages`. Throws [ApiException]. */
    fun send(
        host: String,
        spaceId: String,
        form: MultipartForm,
    )
}

/**
 * [ShareClient] on the app's bearers: the bearer is attached by
 * [AppApiClient.authorized], looked up by the same host the request is for.
 */
class AppShareClient(
    private val api: AppApiClient,
    private val multipart: MultipartTransport = UrlConnectionMultipartTransport(),
) : ShareClient {
    override fun isSignedIn(host: String): Boolean = api.isSignedIn(host)

    override fun spaces(host: String): List<ShareSpace> = parseSpaces(api.getJson(host, SPACES_PATH))

    override fun send(
        host: String,
        spaceId: String,
        form: MultipartForm,
    ) {
        if (!ID.matches(spaceId)) throw ApiException(ApiException.Kind.BAD_RESPONSE, route = "messages")
        val path = AppApiClient.messagesPath(spaceId)
        val base = api.authorized(host, "POST", path, null)
        val headers = base.headers.filterKeys { !it.equals("Content-Type", ignoreCase = true) }
        val response =
            try {
                multipart.post(base.url, headers, form)
            } catch (_: IOException) {
                throw ApiException(ApiException.Kind.NETWORK, route = path)
            }
        if (response.status !in 200..299) throw ApiException(ApiException.Kind.STATUS, response.status, path)
    }

    companion object {
        const val SPACES_PATH = "/api/app/spaces"
        private val ID = Regex("^[A-Za-z0-9_-]{1,128}$")

        /**
         * `{"spaces": [{id, name, path_segment, kind, agents: [{id, name}]}]}`;
         * a space without an id is skipped, and keys this does not read (01a111bb's
         * `org`) are ignored.
         */
        fun parseSpaces(body: String): List<ShareSpace> {
            val list =
                try {
                    JSONObject(body).getJSONArray("spaces")
                } catch (_: JSONException) {
                    throw ApiException(ApiException.Kind.BAD_RESPONSE, route = SPACES_PATH)
                }
            return (0 until list.length()).mapNotNull { i ->
                val o = list.optJSONObject(i) ?: return@mapNotNull null
                val id = o.optString("id").ifEmpty { return@mapNotNull null }
                val agents = o.optJSONArray("agents")
                ShareSpace(
                    id = id,
                    name = o.optString("name").ifEmpty { id },
                    pathSegment = o.optString("path_segment").ifEmpty { null },
                    kind = o.optString("kind").ifEmpty { null },
                    agents =
                        (0 until (agents?.length() ?: 0)).mapNotNull { j ->
                            val a = agents!!.optJSONObject(j) ?: return@mapNotNull null
                            val aid = a.optString("id").ifEmpty { return@mapNotNull null }
                            ShareSpace.Agent(aid, a.optString("name").ifEmpty { aid })
                        },
                )
            }
        }
    }
}
