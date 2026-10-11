package com.koboai.burrow.shortcuts

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.icu.text.BreakIterator
import android.os.Build
import androidx.core.graphics.createBitmap
import androidx.core.graphics.drawable.IconCompat

/**
 * Burrow's avatar renderer for notifications and conversation shortcuts
 * (task 01a12773 stage 3; design canvas 01a12774, "sender avatars in push
 * notifications"). The push carries the sender's picture url
 * (`author_avatar_url`, fetched by push/AvatarFetcher.kt) and a fallback
 * tone (`author_avatar_tone`). Source order: the fetched picture, flattened
 * onto an OPAQUE base-100 fill and circle-cropped ([fromImage]); otherwise
 * the letter disc ([fallback]). Never blank, never a grey silhouette, no
 * ring and no badge.
 *
 * The disc is built to the IN-APP renderer (`PlatformWeb.AvatarComponents`),
 * not to the canvas's palette row, because the canvas's stated reason is
 * parity with the app:
 * - an agent (tone `agent`): ONE initial, primary on base-300, bold;
 * - a person (tone `0`..`7`): up to TWO initials, the `.avatar-fallback-N`
 *   pair from app.css, semibold;
 * - initials are the first grapheme of each whitespace-separated word
 *   (an emoji or an accented letter is never split), upper-cased; no
 *   letters at all is `U`, as in the app.
 *
 * The 8 fallback pairs are app.css's oklch values converted to sRGB; every
 * pair is at least 6:1 (MonogramTest checks 4.5:1).
 *
 * [letter], [bitmap] and [shortcutIcon] are the older one-letter monogram,
 * still drawn for a channel or group shortcut (the canvas: never the latest
 * sender's face; the install's logo is not cached on the phone, so the
 * space-name monogram stands in for it).
 */
object Monogram {
    private const val SIZE = 216

    /** Glyph height as a share of the disc's diameter. */
    private const val GLYPH = 0.45f

    /** An adaptive icon shows its middle 72 of 108: the face stays inside. */
    private const val SAFE_ZONE = 72f / 108f

    /** The daisyUI theme tokens the in-app avatar uses, from app.css. */
    class Theme(
        val base100: Int,
        val base300: Int,
        val primary: Int,
    )

    val LIGHT = Theme(base100 = 0xFFFBFAF9.toInt(), base300 = 0xFFEFEBE7.toInt(), primary = 0xFFAD4B07.toInt())
    val DARK = Theme(base100 = 0xFF191B20.toInt(), base300 = 0xFF25272B.toInt(), primary = 0xFFF47721.toInt())

    /** `.avatar-fallback-0..7` backgrounds (app.css oklch, as sRGB). */
    val FALLBACK_BACKGROUNDS =
        intArrayOf(
            0xFFFB979A.toInt(),
            0xFFF3B680.toInt(),
            0xFFA5D086.toInt(),
            0xFF80D1B5.toInt(),
            0xFF73CFF1.toInt(),
            0xFFAEB8FE.toInt(),
            0xFFE3A9EB.toInt(),
            0xFFE8B5BA.toInt(),
        )

    /** `.avatar-fallback-0..7` text colours (app.css oklch, as sRGB). */
    val FALLBACK_FOREGROUNDS =
        intArrayOf(
            0xFF572125.toInt(),
            0xFF542D00.toInt(),
            0xFF293F17.toInt(),
            0xFF093F31.toInt(),
            0xFF003F53.toInt(),
            0xFF30335C.toInt(),
            0xFF4B2850.toInt(),
            0xFF4A2F32.toInt(),
        )

    const val AGENT_TONE = "agent"

    // Burrow palette tones that carry white text: orange, cyan, ink, muted.
    private val BACKGROUNDS = intArrayOf(0xFFAD4B07.toInt(), 0xFF0E7382.toInt(), 0xFF221F1B.toInt(), 0xFF635B53.toInt())

    /** The install theme the app is showing: dark when the system is in night mode. */
    fun theme(context: Context): Theme {
        val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        return if (night == Configuration.UI_MODE_NIGHT_YES) DARK else LIGHT
    }

    /**
     * The in-app initials: the first grapheme of each of the first [count]
     * whitespace-separated words, upper-cased; `U` when there are none.
     */
    fun initials(
        name: String?,
        count: Int,
    ): String {
        val words =
            name
                ?.trim()
                .orEmpty()
                .split(Regex("\\s+"))
                .filter { it.isNotEmpty() }
        val text = words.take(count).joinToString("") { firstGrapheme(it).uppercase() }
        return text.ifEmpty { "U" }
    }

    private fun firstGrapheme(word: String): String {
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(word)
        val end = iterator.next()
        return if (end == BreakIterator.DONE) word else word.substring(0, end)
    }

    /** True for an agent's tone. */
    fun isAgent(tone: String?): Boolean = tone == AGENT_TONE

    /**
     * (background, text) for [tone]: base-300/primary for an agent, the
     * palette pair for `0`..`7`. Any other tone (an older server sent none)
     * picks a palette pair from [name], so the colour is at least stable.
     */
    fun colors(
        tone: String?,
        name: String?,
        theme: Theme,
    ): Pair<Int, Int> {
        if (isAgent(tone)) return theme.base300 to theme.primary
        val index =
            tone?.toIntOrNull()?.takeIf { it in FALLBACK_BACKGROUNDS.indices }
                ?: Math.floorMod((name ?: "").hashCode(), FALLBACK_BACKGROUNDS.size)
        return FALLBACK_BACKGROUNDS[index] to FALLBACK_FOREGROUNDS[index]
    }

    /** The letter disc: a circle on a transparent square. */
    fun fallback(
        name: String?,
        tone: String?,
        theme: Theme = LIGHT,
        size: Int = SIZE,
    ): Bitmap {
        val (background, foreground) = colors(tone, name, theme)
        val bitmap = createBitmap(size, size)
        val canvas = Canvas(bitmap)
        val radius = size / 2f
        canvas.drawCircle(radius, radius, radius, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = background })
        val agent = isAgent(tone)
        val glyphs = initials(name, if (agent) 1 else 2)
        val text =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = foreground
                textAlign = Paint.Align.CENTER
                typeface = typeface(if (agent) 700 else 600)
                textSize = size * GLYPH
            }
        // Two initials must still fit inside the circle.
        val maxWidth = size * 0.72f
        val width = text.measureText(glyphs)
        if (width > maxWidth) text.textSize *= maxWidth / width
        // Optically centred: on the glyphs' own ink, not the font's line box.
        val bounds = Rect()
        text.getTextBounds(glyphs, 0, glyphs.length, bounds)
        canvas.drawText(glyphs, radius, radius - bounds.exactCenterY(), text)
        return bitmap
    }

    /**
     * A fetched picture as a round avatar: centre-cropped to a square,
     * drawn over an OPAQUE [Theme.base100] fill (so a transparent PNG never
     * shows the shade through it), then circle-cropped.
     */
    fun fromImage(
        image: Bitmap,
        theme: Theme = LIGHT,
        size: Int = SIZE,
    ): Bitmap {
        val square = createBitmap(size, size)
        Canvas(square).apply {
            drawColor(theme.base100)
            val side = minOf(image.width, image.height).toFloat()
            val scale = size / side
            val matrix =
                Matrix().apply {
                    postTranslate(-(image.width - side) / 2f, -(image.height - side) / 2f)
                    postScale(scale, scale)
                }
            drawBitmap(image, matrix, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
        }
        val round = createBitmap(size, size)
        val shader = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = BitmapShader(square, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }
        Canvas(round).drawOval(RectF(0f, 0f, size.toFloat(), size.toFloat()), shader)
        return round
    }

    /** The round avatar for a sender: [image] when there is one, else the letter disc. */
    fun avatar(
        name: String?,
        tone: String?,
        image: Bitmap?,
        theme: Theme,
    ): Bitmap = image?.let { fromImage(it, theme) } ?: fallback(name, tone, theme)

    /** A [androidx.core.app.Person] icon for a sender. */
    fun personIcon(
        name: String?,
        tone: String?,
        image: Bitmap?,
        theme: Theme,
    ): IconCompat = IconCompat.createWithBitmap(avatar(name, tone, image, theme))

    /**
     * An adaptive icon for a DM's conversation shortcut: the sender's round
     * avatar on an opaque base-100 square, sized to the 72/108 safe zone so
     * the launcher's mask never cuts the face.
     */
    fun personShortcutIcon(
        name: String?,
        tone: String?,
        image: Bitmap?,
        theme: Theme,
    ): IconCompat {
        val face = avatar(name, tone, image, theme)
        val bitmap = createBitmap(SIZE, SIZE)
        Canvas(bitmap).apply {
            drawColor(theme.base100)
            val inset = SIZE * (1f - SAFE_ZONE) / 2f
            drawBitmap(
                face,
                null,
                RectF(inset, inset, SIZE - inset, SIZE - inset),
                Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG),
            )
        }
        return IconCompat.createWithAdaptiveBitmap(bitmap)
    }

    private fun typeface(weight: Int): Typeface =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Typeface.create(Typeface.DEFAULT, weight, false)
        } else {
            Typeface.create("sans-serif-medium", if (weight >= 700) Typeface.BOLD else Typeface.NORMAL)
        }

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

    /** An adaptive icon for a channel or group shortcut (the launcher masks it). */
    fun shortcutIcon(name: String?): IconCompat = IconCompat.createWithAdaptiveBitmap(bitmap(name, circle = false))
}
