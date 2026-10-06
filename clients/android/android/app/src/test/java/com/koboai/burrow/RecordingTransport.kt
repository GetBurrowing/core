package com.koboai.burrow

import java.io.IOException

/** Records requests and answers from a script keyed by "METHOD path". */
class RecordingTransport(
    private val responses: Map<String, HttpResponse> = emptyMap(),
    private val failing: Set<String> = emptySet(),
) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()

    override fun execute(request: HttpRequest): HttpResponse {
        requests.add(request)
        val key = "${request.method} ${java.net.URI(request.url).path}"
        if (key in failing) throw IOException("offline")
        return responses[key] ?: HttpResponse(404, "{}")
    }
}
