package com.koboai.burrow.voice

/** Whether the system's on-device recognizer has a model for the person's language. */
enum class SpeechAssets {
    /** Installed: the recognizer can start now. */
    INSTALLED,

    /** Supported on the device but not downloaded yet (`prepare()` fetches it). */
    DOWNLOADABLE,

    /** No on-device model exists for the language. */
    UNSUPPORTED,

    /** Not known: API 31 and 32 have no `checkRecognitionSupport`, or the check failed. */
    UNKNOWN,
}

/**
 * What decides whether this phone transcribes on the device. Gathered at run
 * time ([SpeechCapabilityProbe]); tests build it by hand. Mirrors iOS
 * `VoiceCapabilityInputs` (`BurrowVoicePlugin.swift`).
 */
data class VoiceCapabilityInputs(
    val sdkInt: Int,
    /** `SpeechRecognizer.isOnDeviceRecognitionAvailable`. */
    val onDeviceAvailable: Boolean = false,
    /** The BCP 47 tag the recognizer will be asked for, or null. */
    val locale: String? = null,
    val assets: SpeechAssets = SpeechAssets.UNKNOWN,
)

/**
 * `capabilities()`: whether the Voice tab may use on-device speech, and if
 * not, why. `reason` is one of [REASONS] (the JS `REASONS` in
 * `assets/js/lib/on_device_voice.js`) or null. Android has no separate
 * speech-recognition permission, so `speech_permission_denied` never comes
 * from here, and the microphone permission is not a reason (the page shows
 * its permission card instead, exactly as on iOS).
 */
data class VoiceCapability(
    val onDeviceSpeech: Boolean,
    val reason: String?,
    val locale: String?,
) {
    companion object {
        /** `createOnDeviceSpeechRecognizer` and `isOnDeviceRecognitionAvailable`. */
        const val MIN_SDK = 31

        /** `checkRecognitionSupport` and `triggerModelDownload`. */
        const val SUPPORT_CHECK_SDK = 33

        val REASONS =
            listOf("os_too_old", "unavailable", "locale_unsupported", "speech_permission_denied", "assets_missing")

        fun decide(inputs: VoiceCapabilityInputs): VoiceCapability {
            val reason =
                when {
                    inputs.sdkInt < MIN_SDK -> "os_too_old"
                    !inputs.onDeviceAvailable -> "unavailable"
                    inputs.locale == null -> "locale_unsupported"
                    inputs.sdkInt < SUPPORT_CHECK_SDK -> null // nothing to check: try it
                    inputs.assets == SpeechAssets.UNSUPPORTED -> "locale_unsupported"
                    inputs.assets == SpeechAssets.DOWNLOADABLE -> "assets_missing"
                    // The check failed: today's tab works, so do not gamble the turn on it.
                    inputs.assets == SpeechAssets.UNKNOWN -> "unavailable"
                    else -> null
                }
            return VoiceCapability(reason == null, reason, inputs.locale)
        }
    }
}

/**
 * Which of the recognizer's languages serves [deviceTag]: the same tag
 * (case-insensitive), else one with the same primary language. Installed
 * models win over ones that would have to be downloaded.
 */
object RecognitionLocales {
    fun pick(
        deviceTag: String?,
        installed: List<String>,
        downloadable: List<String>,
    ): Pair<SpeechAssets, String?> {
        if (deviceTag.isNullOrBlank()) return SpeechAssets.UNSUPPORTED to null
        match(deviceTag, installed)?.let { return SpeechAssets.INSTALLED to it }
        match(deviceTag, downloadable)?.let { return SpeechAssets.DOWNLOADABLE to it }
        return SpeechAssets.UNSUPPORTED to null
    }

    private fun match(
        tag: String,
        candidates: List<String>,
    ): String? {
        candidates.firstOrNull { it.equals(tag, ignoreCase = true) }?.let { return it }
        val language = primary(tag)
        return candidates.firstOrNull { primary(it) == language }
    }

    private fun primary(tag: String): String = tag.substringBefore('-').substringBefore('_').lowercase()
}
