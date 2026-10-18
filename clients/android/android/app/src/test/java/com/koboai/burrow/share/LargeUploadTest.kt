package com.koboai.burrow.share

import com.koboai.burrow.ApiException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream

/**
 * Task 01a120be stage 5: the share sheet routes by the server's
 * upload_config. At or under multipart_max_bytes the multipart POST stays;
 * above it the file is reserved and handed to the background uploader; over
 * max_upload_bytes it is refused with the server's label before any upload.
 */
class LargeUploadTest {
    private val host = "burrow.example.com"
    private val space = ShareSpace("0192-s1", "design-review", "design-review", emptyList())
    private val oneGb = UploadConfig(1_000_000_000, "1 GB", 33_554_432, 8_000_000)

    private fun file(
        name: String,
        bytes: Long,
    ) = SharedFile(name, "video/quicktime", bytes) { ByteArrayInputStream(ByteArray(0)) }

    private class FakeClient(
        val config: UploadConfig?,
    ) : ShareClient {
        val sent = mutableListOf<MultipartForm>()
        val reserved = mutableListOf<Pair<SharedFile, String?>>()

        override fun isSignedIn(host: String) = true

        override fun spaces(host: String) = listOf(ShareSpace("0192-s1", "design-review", "design-review", emptyList()))

        override fun send(
            host: String,
            spaceId: String,
            form: MultipartForm,
        ) {
            sent.add(form)
        }

        override fun uploadConfig(host: String) = config

        override fun reserveUpload(
            host: String,
            spaceId: String,
            file: SharedFile,
            text: String?,
            agentId: String?,
        ): UploadReservation {
            reserved.add(file to text)
            return UploadReservation("r${reserved.size}", "/chat/attachments/upload/t${reserved.size}", 100, 0)
        }
    }

    private class FakeEnqueuer : LargeUploadEnqueuer {
        val enqueued = mutableListOf<Pair<UploadReservation, SharedFile>>()

        override fun enqueue(
            host: String,
            reservation: UploadReservation,
            file: SharedFile,
            spaceName: String,
        ) {
            enqueued.add(reservation to file)
        }
    }

    private fun model(
        files: List<SharedFile>,
        client: FakeClient,
        enqueuer: FakeEnqueuer = FakeEnqueuer(),
    ) = ShareSheetModel(host, client, files, null, enqueuer = enqueuer).also {
        it.start()
        it.selectedSpaceId = space.id
    }

    // Routing on the multipart REQUEST size, exactly at the threshold.

    @Test
    fun `8_000_000 request bytes stay multipart, 8_000_001 go chunked`() {
        val f = file("a.mov", 7_999_000)
        val at = SizeCheck.of(listOf(f), oneGb) { _, _ -> 8_000_000 }
        assertEquals(listOf(f), at.sendable)
        assertTrue(at.chunked.isEmpty())
        val over = SizeCheck.of(listOf(f), oneGb) { _, _ -> 8_000_001 }
        assertEquals(listOf(f), over.sendable)
        assertEquals(listOf(f), over.chunked)
        assertNull(over.notice)
        assertFalse(over.blocked)
    }

    @Test
    fun `over the server max is refused with the server's label`() {
        val big = file("quarterly-raw.mov", 1_153_433_600)
        val m = model(listOf(big), FakeClient(oneGb))
        assertEquals("quarterly-raw.mov is 1.2 GB. This Burrow accepts files up to 1 GB.", m.size.notice)
        assertTrue(m.size.blocked)
        assertFalse(m.canSend)
    }

    @Test
    fun `a changed server max changes the decision`() {
        val big = file("quarterly-raw.mov", 1_153_433_600)
        val raised = model(listOf(big), FakeClient(UploadConfig(2_000_000_000, "2 GB", 33_554_432, 8_000_000)))
        assertNull(raised.size.notice)
        assertEquals(listOf(big), raised.size.chunked)
        val lowered = model(listOf(file("clip.mov", 600_000_000)), FakeClient(UploadConfig(500_000_000, "500 MB", 1, 8_000_000)))
        assertEquals("clip.mov is 600 MB. This Burrow accepts files up to 500 MB.", lowered.size.notice)
    }

    @Test
    fun `k of n over uses the server's label`() {
        val m = model(listOf(file("a.mov", 1_153_433_600), file("b.pdf", 1_000)), FakeClient(oneGb))
        assertEquals("1 of 2 files are over 1 GB and won't be sent.", m.size.notice)
        assertEquals("Send 1", m.sendLabel)
    }

    @Test
    fun `a large file is reserved with the text and handed off, a small one stays multipart`() {
        val client = FakeClient(oneGb)
        val enqueuer = FakeEnqueuer()
        val large = file("launch-walkthrough.mov", 900_000_000)
        val small = file("notes.pdf", 2_000)
        val m = model(listOf(large, small), client, enqueuer)
        m.message = "the walkthrough"
        assertTrue(m.canSend)

        assertTrue(m.send())

        assertEquals(ShareSheetModel.Phase.HANDED_OFF, m.phase)
        assertEquals(listOf(large to "the walkthrough"), client.reserved)
        assertEquals(
            "r1",
            enqueuer.enqueued
                .single()
                .first.id,
        )
        // The small file went multipart, without the text (it rode the first request).
        assertEquals(small, client.sent.single().file)
        assertTrue(
            client.sent
                .single()
                .fields
                .none { it.first == "text" },
        )
        assertEquals("Uploading in the background. You can close this.", ShareSheetModel.HANDED_OFF_TEXT)
    }

    @Test
    fun `without upload_config only the multipart path exists`() {
        val m = model(listOf(file("big.mov", 9_000_000)), FakeClient(null))
        assertEquals("big.mov is 9 MB. Burrow can send files up to 8 MB each.", m.size.notice)
        assertTrue(m.size.chunked.isEmpty())
    }

    @Test
    fun `a 413 on reservation keeps the share and shows the send failure`() {
        val client =
            object : ShareClient by FakeClient(oneGb) {
                override fun reserveUpload(
                    host: String,
                    spaceId: String,
                    file: SharedFile,
                    text: String?,
                    agentId: String?,
                ): UploadReservation = throw ApiException(ApiException.Kind.STATUS, 413, "uploads")
            }
        val m = ShareSheetModel(host, client, listOf(file("x.mov", 900_000_000)), null)
        m.start()
        m.selectedSpaceId = space.id
        assertFalse(m.send())
        assertEquals(ShareSheetModel.Banner.SEND_FAILED, m.banner)
        assertEquals(ShareSheetModel.Phase.READY, m.phase)
    }

    @Test
    fun `byte labels follow the shared decimal rule`() {
        // The example table in the task's shared brief, verbatim: every surface pins it.
        assertEquals("1 GB", ByteLabel.format(1_000_000_000))
        assertEquals("1.1 GB", ByteLabel.format(1_073_741_824))
        assertEquals("899.1 MB", ByteLabel.format(899_109_076))
        assertEquals("900 MB", ByteLabel.format(900_000_000))
        assertEquals("1.2 GB", ByteLabel.format(1_153_433_600))
        assertEquals("8 MB", ByteLabel.format(8_000_000))
        assertEquals("33.6 MB", ByteLabel.format(33_554_432))
        assertEquals("1 GB", ByteLabel.format(999_960_000))
        assertEquals("512 bytes", ByteLabel.format(512))
        assertEquals("412 of 900 MB", ByteLabel.progress(412_000_000, 900_000_000))
        assertEquals("416 of 899.1 MB", ByteLabel.progress(416_000_000, 899_109_076))
    }

    @Test
    fun `byte label edges - unit boundaries, half-up, rollover, clamping`() {
        assertEquals("999 bytes", ByteLabel.format(999))
        assertEquals("1 KB", ByteLabel.format(1_000))
        assertEquals("1 KB", ByteLabel.format(1_049))
        // Half-up, never banker's: 1.05 KB reads 1.1, 1.25 KB reads 1.3.
        assertEquals("1.1 KB", ByteLabel.format(1_050))
        assertEquals("1.3 KB", ByteLabel.format(1_250))
        assertEquals("1 MB", ByteLabel.format(999_950))
        assertEquals("999.9 KB", ByteLabel.format(999_949))
        assertEquals("1 TB", ByteLabel.format(1_000_000_000_000))
        assertEquals("1000 TB", ByteLabel.format(999_999_999_999_999))
        assertEquals("900 of 900 MB", ByteLabel.progress(1_000_000_000, 900_000_000))
        assertEquals("0.4 of 1 GB", ByteLabel.progress(377_356_288, 1_000_000_000))
        assertEquals("12 of 512 bytes", ByteLabel.progress(12, 512))
    }

    @Test
    fun `upload_config and the reservation parse`() {
        val c =
            UploadConfig.parse(
                """{"max_upload_bytes":1000000000,"max_upload_label":"1 GB",""" +
                    """"chunk_bytes":33554432,"multipart_max_bytes":8000000}""",
            )
        assertEquals(UploadConfig(1_000_000_000, "1 GB", 33_554_432, 8_000_000), c)
        val r = UploadReservation.parse("""{"id":"a1","upload_url":"/chat/attachments/upload/t","chunk_bytes":100,"offset":0}""")
        assertEquals("https://$host/chat/attachments/upload/t", r.absoluteUrl(host))
    }
}
