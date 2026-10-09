package com.koboai.burrow.shortcuts

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import androidx.core.graphics.createBitmap
import androidx.core.graphics.drawable.IconCompat

/**
 * A one-letter avatar for a person or a conversation. The push payload has
 * no avatar URL, so this is the only picture Burrow can give a sender or a
 * conversation shortcut (a photo avatar is a recorded follow-up).
 */
object Monogram {
    private const val SIZE = 216

    // Burrow palette tones that carry white text: orange, cyan, ink, muted.
    private val BACKGROUNDS = intArrayOf(0xFFAD4B07.toInt(), 0xFF0E7382.toInt(), 0xFF221F1B.toInt(), 0xFF635B53.toInt())

    /** The first letter of [name], upper-cased, or `?` when it has none. */
    fun letter(name: String?): String {
        val text = name?.trim().orEmpty()
        val first = text.firstOrNull { it.isLetterOrDigit() } ?: return "?"
        return first.uppercaseChar().toString()
    }

    /** A square bitmap: [letter] centred on a palette colour picked from [name]. */
    fun bitmap(
        name: String?,
        circle: Boolean,
    ): Bitmap {
        val bitmap = createBitmap(SIZE, SIZE)
        val canvas = Canvas(bitmap)
        val fill =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = BACKGROUNDS[Math.floorMod((name ?: "").hashCode(), BACKGROUNDS.size)]
            }
        if (circle) {
            canvas.drawCircle(SIZE / 2f, SIZE / 2f, SIZE / 2f, fill)
        } else {
            canvas.drawRect(0f, 0f, SIZE.toFloat(), SIZE.toFloat(), fill)
        }
        val text =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xFFFBFAF9.toInt()
                textAlign = Paint.Align.CENTER
                typeface = Typeface.DEFAULT_BOLD
                // An adaptive icon shows its middle 72 of 108: keep the letter inside.
                textSize = SIZE * if (circle) 0.5f else 0.33f
            }
        val baseline = SIZE / 2f - (text.descent() + text.ascent()) / 2f
        canvas.drawText(letter(name), SIZE / 2f, baseline, text)
        return bitmap
    }

    /** A round icon for a [androidx.core.app.Person]. */
    fun personIcon(name: String?): IconCompat = IconCompat.createWithBitmap(bitmap(name, circle = true))

    /** An adaptive icon for a conversation shortcut (the launcher masks it). */
    fun shortcutIcon(name: String?): IconCompat = IconCompat.createWithAdaptiveBitmap(bitmap(name, circle = false))
}
