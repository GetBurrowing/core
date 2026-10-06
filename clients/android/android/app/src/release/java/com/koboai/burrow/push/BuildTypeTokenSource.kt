package com.koboai.burrow.push

import android.content.Context

/** Release builds have no fake token: without Firebase there is no push. */
object BuildTypeTokenSource {
    @Suppress("UNUSED_PARAMETER")
    fun fallback(context: Context): PushTokenSource? = null
}
