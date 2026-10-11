package com.koboai.burrow.push

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.BitmapDrawable
import androidx.core.graphics.drawable.IconCompat
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import java.io.ByteArrayOutputStream
import javax.net.ssl.SSLSocketFactory

/**
 * Shared setup for the sender-avatar tests (task 01a12773 stage 3): a TLS
 * MockWebServer on `localhost` and real PNG bytes. Needs Robolectric's
 * NATIVE graphics, so the bitmaps are real pixels.
 */
class AvatarServer {
    val server = MockWebServer()
    val clientSockets: SSLSocketFactory

    init {
        val localhost = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCerts = HandshakeCertificates.Builder().heldCertificate(localhost).build()
        val trusted =
            HandshakeCertificates
                .Builder()
                .addTrustedCertificate(localhost.certificate)
                .build()
        clientSockets = trusted.sslSocketFactory()
        server.useHttps(serverCerts.sslSocketFactory(), false)
        server.start()
    }

    /** `localhost:<port>`, the install host a same-host url matches. */
    val authority: String get() = "localhost:${server.port}"

    fun url(path: String = "/api/app/agents/a1/avatar?v=c0ffee12"): String = "https://$authority$path"

    /**
     * Stops the server. A test that holds a response open on purpose (a
     * 10 s body delay) leaves MockWebServer unable to drain it in time:
     * that is the scenario under test, not a failure, so it is ignored.
     */
    fun shutdown() {
        try {
            server.shutdown()
        } catch (_: java.io.IOException) {
            // The held-open response; see above.
        } catch (_: InterruptedException) {
            // JUnit's timeout thread interrupted the wait; same cause.
        }
    }

    companion object {
        /** A solid [color] PNG; [Color.TRANSPARENT] gives a fully transparent one. */
        fun png(
            color: Int = Color.RED,
            width: Int = 64,
            height: Int = 64,
        ): ByteArray {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(color)
            return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        }

        /** A PNG of random pixels: it does not compress, so it is about 4 bytes a pixel. */
        fun noisePng(
            width: Int = 96,
            height: Int = 96,
        ): ByteArray {
            val random = java.util.Random(7)
            val pixels = IntArray(width * height) { 0xFF000000.toInt() or random.nextInt(0xFFFFFF) }
            val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
            return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        }

        fun image(bytes: ByteArray = png()): MockResponse =
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "image/png")
                .setBody(Buffer().write(bytes))

        /** The pixels behind a bitmap icon. */
        fun bitmapOf(
            icon: IconCompat,
            context: Context,
        ): Bitmap {
            val drawable = icon.loadDrawable(context)
            return when (drawable) {
                is BitmapDrawable -> drawable.bitmap
                is AdaptiveIconDrawable -> (drawable.foreground as BitmapDrawable).bitmap
                else -> error("not a bitmap icon: $drawable")
            }
        }

        /** True when [actual] is within a few levels of [expected] on every channel. */
        fun near(
            expected: Int,
            actual: Int,
            tolerance: Int = 6,
        ): Boolean =
            Math.abs(Color.alpha(expected) - Color.alpha(actual)) <= tolerance &&
                Math.abs(Color.red(expected) - Color.red(actual)) <= tolerance &&
                Math.abs(Color.green(expected) - Color.green(actual)) <= tolerance &&
                Math.abs(Color.blue(expected) - Color.blue(actual)) <= tolerance
    }
}
