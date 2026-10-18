package com.koboai.burrow.shortcuts

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import com.koboai.burrow.push.AvatarServer
import com.koboai.burrow.push.AvatarServer.Companion.near
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.GraphicsMode
import kotlin.math.pow

/** The avatar renderer (task 01a12773 stage 3): in-app letter rules, colours and the opaque flatten. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MonogramTest {
    private fun luminance(color: Int): Double {
        fun channel(c: Int): Double {
            val v = c / 255.0
            return if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * channel(Color.red(color)) + 0.7152 * channel(Color.green(color)) + 0.0722 * channel(Color.blue(color))
    }

    private fun contrast(
        a: Int,
        b: Int,
    ): Double {
        val (hi, lo) = listOf(luminance(a), luminance(b)).sortedDescending()
        return (hi + 0.05) / (lo + 0.05)
    }

    private fun decoded(bytes: ByteArray): Bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)

    @Test
    fun `a person gets up to two initials, an agent one, first grapheme of each word`() {
        assertEquals("SL", Monogram.initials("Sam Lee", 2))
        assertEquals("AB", Monogram.initials("  ada   bea  cy ", 2))
        assertEquals("O", Monogram.initials("Octavius Bot", 1))
        assertEquals("ÉD", Monogram.initials("élodie durand", 2))
        // A ZWJ emoji is ONE grapheme: never split into its code points.
        assertEquals("👩‍💻D", Monogram.initials("👩‍💻 dev", 2))
        assertEquals("U", Monogram.initials("   ", 2))
        assertEquals("U", Monogram.initials(null, 1))
    }

    @Test
    fun `every fallback pair, and the agent pair in both themes, passes AA`() {
        for (i in Monogram.FALLBACK_BACKGROUNDS.indices) {
            val ratio = contrast(Monogram.FALLBACK_BACKGROUNDS[i], Monogram.FALLBACK_FOREGROUNDS[i])
            assertTrue("avatar-fallback-$i is $ratio:1", ratio >= 4.5)
        }
        for (theme in listOf(Monogram.LIGHT, Monogram.DARK)) {
            val ratio = contrast(theme.base300, theme.primary)
            assertTrue("agent disc is $ratio:1", ratio >= 4.5)
        }
    }

    @Test
    fun `the tone picks the colours, an agent gets base-300 and primary`() {
        assertEquals(Monogram.FALLBACK_BACKGROUNDS[5] to Monogram.FALLBACK_FOREGROUNDS[5], Monogram.colors("5", "Sam", Monogram.LIGHT))
        assertEquals(Monogram.LIGHT.base300 to Monogram.LIGHT.primary, Monogram.colors("agent", "Octavius", Monogram.LIGHT))
        assertEquals(Monogram.DARK.base300 to Monogram.DARK.primary, Monogram.colors("agent", "Octavius", Monogram.DARK))
        // An unknown tone still picks a stable palette pair from the name.
        assertEquals(Monogram.colors(null, "Sam", Monogram.LIGHT), Monogram.colors("9", "Sam", Monogram.LIGHT))
    }

    @Test
    fun `the disc is filled in the tone's colour inside the circle and transparent outside it`() {
        val disc = Monogram.fallback("Sam Lee", "3", Monogram.LIGHT, size = 200)
        // Inside the circle, above the glyphs.
        assertTrue(near(Monogram.FALLBACK_BACKGROUNDS[3], disc.getPixel(100, 14)))
        assertEquals(0, Color.alpha(disc.getPixel(2, 2)))
        // The glyphs are drawn: some pixel in the middle band is the text colour.
        val ink = (40 until 160).any { x -> near(Monogram.FALLBACK_FOREGROUNDS[3], disc.getPixel(x, 100), 40) }
        assertTrue("no initials drawn", ink)
    }

    @Test
    fun `a transparent picture is flattened onto opaque base-100, in both themes`() {
        val clear = decoded(AvatarServer.png(Color.TRANSPARENT))
        for (theme in listOf(Monogram.LIGHT, Monogram.DARK)) {
            val round = Monogram.fromImage(clear, theme, size = 200)
            val centre = round.getPixel(100, 100)
            assertEquals(255, Color.alpha(centre))
            assertTrue(near(theme.base100, centre))
        }
    }

    @Test
    fun `a picture fills the circle and the corners stay clear`() {
        val round = Monogram.fromImage(decoded(AvatarServer.png(Color.RED, 80, 40)), Monogram.LIGHT, size = 200)
        assertTrue(near(Color.RED, round.getPixel(100, 100)))
        assertTrue(near(Color.RED, round.getPixel(100, 6)))
        assertEquals(0, Color.alpha(round.getPixel(1, 1)))
    }

    @Test
    fun `a DM shortcut keeps the face inside the adaptive safe zone, on an opaque fill`() {
        val context = RuntimeEnvironment.getApplication()
        val icon = Monogram.personShortcutIcon("Sam", "1", decoded(AvatarServer.png(Color.RED)), Monogram.LIGHT)
        val bitmap = AvatarServer.bitmapOf(icon, context)
        val size = bitmap.width
        assertTrue(near(Color.RED, bitmap.getPixel(size / 2, size / 2)))
        // Outside the 72/108 safe zone: the opaque base-100 fill, never the face.
        val corner = bitmap.getPixel(size / 20, size / 20)
        assertEquals(255, Color.alpha(corner))
        assertTrue(near(Monogram.LIGHT.base100, corner))
        assertTrue(near(Monogram.LIGHT.base100, bitmap.getPixel(size / 2, size / 12)))
    }
}
