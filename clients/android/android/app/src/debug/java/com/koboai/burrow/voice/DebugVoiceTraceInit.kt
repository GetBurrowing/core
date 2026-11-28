package com.koboai.burrow.voice

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.util.Log

/**
 * DEBUG BUILDS ONLY (task 01a21e4a stage 5). Installs the [VoiceTrace] sink
 * at process start, so the emulator run can read ids and timings with
 * `adb logcat -s BurrowVoiceTrace`. Not exported; it answers no queries.
 */
class DebugVoiceTraceInit : ContentProvider() {
    override fun onCreate(): Boolean {
        VoiceTrace.sink = { line -> Log.i(TAG, line) }
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        const val TAG = "BurrowVoiceTrace"
    }
}
