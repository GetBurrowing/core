package com.koboai.burrow.push

import org.json.JSONObject
import java.util.Base64

/** The shared cross-language fixture `push_seal_v1.json` (server, iOS and Android copies are byte-identical). */
object SealFixture {
    private val json: JSONObject by lazy {
        val stream =
            requireNotNull(SealFixture::class.java.getResourceAsStream("/push_seal_v1.json")) {
                "push_seal_v1.json not on the test classpath"
            }
        JSONObject(stream.bufferedReader().use { it.readText() })
    }

    /** The sealed value's raw bytes (a fresh copy). */
    fun blob(): ByteArray = Base64.getUrlDecoder().decode(sealed)

    val host: String get() = json.getString("install_host")
    val sealed: String get() = json.getString("sealed")
    val plaintext: String get() = json.getString("plaintext")
    val info: String get() = json.getString("info")
    val recipientPublicKey: String get() = json.getString("recipient_public_key")
    val privateKey: ByteArray get() = Base64.getUrlDecoder().decode(json.getString("recipient_private_key"))

    /** The inner data map as the server put it under FCM `data`. */
    val innerData: Map<String, String> get() {
        val inner = JSONObject(plaintext)
        return inner.keys().asSequence().associateWith { inner.getString(it) }
    }

    /** What the relay sends to FCM for this push: routing keys and the blob, no `kind`. */
    fun relayed(
        installHost: String = host,
        sealed: String? = this.sealed,
    ): Map<String, String?> =
        mapOf(
            "install_host" to installHost,
            "unread_count" to "3",
            "unread_as_of" to "2026-10-10T15:00:00Z",
            "sealed" to sealed,
        )
}
