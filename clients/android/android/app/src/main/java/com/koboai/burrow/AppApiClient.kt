package com.koboai.burrow

import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocketFactory

/** One HTTP request. [toString] never prints headers or the body. */
class HttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: String? = null,
) {
    override fun toString(): String = "HttpRequest($method ${URI(url).path})"
}

class HttpResponse(
    val status: Int,
    val body: String,
) {
    override fun toString(): String = "HttpResponse($status)"
}

/** The network, behind an interface so tests can record requests. */
fun interface HttpTransport {
    @Throws(IOException::class)
    fun execute(request: HttpRequest): HttpResponse
}

/**
 * HttpURLConnection, HTTPS only. [sslSocketFactory] is for tests, which run
 * a TLS MockWebServer with their own certificate; the app never sets it.
 */
class UrlConnectionTransport(
    private val timeoutMillis: Int = 20_000,
    private val sslSocketFactory: SSLSocketFactory? = null,
) : HttpTransport {
    override fun execute(request: HttpRequest): HttpResponse {
        val url = URL(request.url)
        if (url.protocol != "https") throw IOException("refusing a non-HTTPS request")
        val connection = url.openConnection() as HttpURLConnection
        try {
            if (sslSocketFactory != null && connection is HttpsURLConnection) connection.sslSocketFactory = sslSocketFactory
            connection.requestMethod = request.method
            connection.connectTimeout = timeoutMillis
            connection.readTimeout = timeoutMillis
            connection.instanceFollowRedirects = false
            request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            request.body?.let { body ->
                connection.doOutput = true
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            return HttpResponse(status, text)
        } finally {
            connection.disconnect()
        }
    }
}

/**
 * A failed `/api/app` call. The message names the route and the status
 * only: never a token, a code, a verifier or a response body.
 */
class ApiException(
    val kind: Kind,
    val status: Int = 0,
    route: String = "",
) : Exception("${kind.name.lowercase()}${if (status != 0) " $status" else ""}${if (route.isNotEmpty()) " on $route" else ""}") {
    enum class Kind { NOT_SIGNED_IN, STATUS, BAD_RESPONSE, NETWORK }
}

/** What `POST /api/app/session` returns. [toString] hides the token. */
class SessionGrant(
    val token: String,
    val handoffUrl: String,
) {
    override fun toString(): String = "SessionGrant(token=<redacted>)"
}

/**
 * Calls to an install's `/api/app/` routes. Mirrors iOS `SuiteAPIClient`:
 * the bearer is looked up by the SAME host the request is built for, at the
 * moment it is built, in one place ([authorized]), so install A's bearer is
 * never sent to install B. A host with no bearer fails NOT_SIGNED_IN before
 * any request exists.
 *
 * Every call blocks: run it off the main thread.
 */
class AppApiClient(
    private val tokens: TokenStore,
    private val transport: HttpTransport = UrlConnectionTransport(),
) {
    companion object {
        const val SESSION_PATH = "/api/app/session"
        const val HANDOFF_PATH = "/api/app/handoff"
        const val DEVICES_PATH = "/api/app/devices"

        fun messagesPath(spaceId: String) = "/api/app/spaces/$spaceId/messages"

        fun devicePath(appInstallId: String) = "/api/app/devices/$appInstallId"

        private fun sameHost(
            url: String,
            host: String,
        ): Boolean =
            try {
                val uri = URI(url)
                uri.scheme.equals("https", ignoreCase = true) && uri.host.equals(host, ignoreCase = true)
            } catch (_: Exception) {
                false
            }
    }

    fun isSignedIn(host: String): Boolean = tokens.token(host) != null

    /**
     * `POST /api/app/session`: swaps the login code plus its PKCE verifier
     * for a bearer and a one-time `handoff_url` on [host].
     */
    fun exchangeSession(
        host: String,
        code: String,
        verifier: String,
        appInstallId: String,
        deviceName: String,
    ): SessionGrant {
        val body =
            JSONObject()
                .put("code", code)
                .put("code_verifier", verifier)
                .put("app_install_id", appInstallId)
                .put("device_name", deviceName)
                .toString()
        val response =
            send(
                HttpRequest(
                    "POST",
                    "https://$host$SESSION_PATH",
                    mapOf("Content-Type" to "application/json", "Accept" to "application/json"),
                    body,
                ),
                SESSION_PATH,
            )
        val json = parse(response, SESSION_PATH)
        val token = json.optString("token").ifEmpty { throw ApiException(ApiException.Kind.BAD_RESPONSE, route = SESSION_PATH) }
        val handoff = json.optString("handoff_url")
        if (!sameHost(handoff, host)) throw ApiException(ApiException.Kind.BAD_RESPONSE, route = SESSION_PATH)
        return SessionGrant(token, handoff)
    }

    /**
     * `POST /api/app/handoff`: a fresh one-time URL that signs the WebView in
     * as the bearer's user (the WebView's session cookie does not outlive
     * the app process). [path] is where it lands. A URL on any host other
     * than [host] is refused.
     */
    fun handoff(
        host: String,
        path: String?,
    ): String {
        val body = JSONObject().apply { if (path != null) put("path", path) }.toString()
        val response = send(authorized(host, "POST", HANDOFF_PATH, body), HANDOFF_PATH)
        val url = parse(response, HANDOFF_PATH).optString("handoff_url")
        if (!sameHost(url, host)) throw ApiException(ApiException.Kind.BAD_RESPONSE, route = HANDOFF_PATH)
        return url
    }

    /**
     * `POST /api/app/devices`: registers this phone's FCM token for [host]'s
     * signed-in user. Returns only when the server answered 2xx (the
     * honesty rule: push is "granted" only once the row is stored); any
     * other status throws STATUS and a transport failure throws NETWORK.
     */
    fun registerDevice(
        host: String,
        token: String,
        packageName: String,
        appInstallId: String,
    ) {
        val body =
            JSONObject()
                .put("token", token)
                .put("platform", "android")
                .put("package_name", packageName)
                .put("app_install_id", appInstallId)
                .toString()
        send(authorized(host, "POST", DEVICES_PATH, body), DEVICES_PATH)
    }

    /**
     * `POST /api/app/spaces/:space_id/messages` with `text` and `reply_to`
     * (a notification Reply). There is deliberately no thread field: the
     * server posts top-level when [replyTo] is top-level and in its thread
     * when it is in one.
     */
    fun postReply(
        host: String,
        spaceId: String,
        text: String,
        replyTo: String,
    ) {
        val path = messagesPath(spaceId)
        val body = JSONObject().put("text", text).put("reply_to", replyTo).toString()
        send(authorized(host, "POST", path, body), path)
    }

    /** A bearer `GET` of [path] on [host]; the body of a 2xx, else throws. */
    fun getJson(
        host: String,
        path: String,
    ): String = send(authorized(host, "GET", path, null), path).body

    /** A bearer `DELETE` (`/api/app/session`, `/api/app/devices/:id`). */
    fun delete(
        host: String,
        path: String,
    ) {
        send(authorized(host, "DELETE", path, null), path)
    }

    /** The only place a bearer is attached to a request. */
    internal fun authorized(
        host: String,
        method: String,
        path: String,
        body: String?,
    ): HttpRequest {
        val token = tokens.token(host) ?: throw ApiException(ApiException.Kind.NOT_SIGNED_IN, route = path)
        val headers =
            mutableMapOf("Authorization" to "Bearer $token", "Accept" to "application/json")
        if (body != null) headers["Content-Type"] = "application/json"
        return HttpRequest(method, "https://$host$path", headers, body)
    }

    private fun send(
        request: HttpRequest,
        route: String,
    ): HttpResponse {
        val response =
            try {
                transport.execute(request)
            } catch (_: IOException) {
                throw ApiException(ApiException.Kind.NETWORK, route = route)
            }
        if (response.status !in 200..299) throw ApiException(ApiException.Kind.STATUS, response.status, route)
        return response
    }

    private fun parse(
        response: HttpResponse,
        route: String,
    ): JSONObject =
        try {
            JSONObject(response.body)
        } catch (_: JSONException) {
            throw ApiException(ApiException.Kind.BAD_RESPONSE, route = route)
        }
}
