package com.koboai.burrow.voice

import android.annotation.SuppressLint
import android.app.UiModeManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import java.util.concurrent.Executor

/** What the audio system tells an open turn. */
interface VoiceAudioListener {
    /** A phone call, or another app taking audio focus for good: the turn ends (`interrupted`). */
    fun onInterrupted()

    /** A device came or went: the plugin sends `route`. */
    fun onRouteChanged()
}

/**
 * What [BurrowVoicePlugin] needs from the audio system. [SystemVoiceAudio] is
 * the real one; tests inject a fake. Main thread only.
 */
interface VoiceAudioControl {
    /** A phone call, or a meeting call in the WebView (`MODE_IN_COMMUNICATION`), holds the audio. */
    val inCall: Boolean

    /** Some client is recording right now (another app, or the WebView's own mic). */
    val othersRecording: Boolean

    /** "Bluetooth", "Headphones", "Car", or null for the built-in mic and speaker. */
    val routeLabel: String?

    /** The mic is about to open: watch focus, the call state and the devices. */
    fun beginCapture(listener: VoiceAudioListener)

    /** The mic closed: stop watching and give back any focus. */
    fun endCapture()

    /**
     * Calls [onLost] whenever the device a reply plays on goes away: a
     * Bluetooth or wired output is removed, or the system says audio is
     * becoming noisy (headphones pulled). The reply then stops instead of
     * moving to the loudspeaker (iOS `route_lost`).
     */
    fun watchOutputLoss(onLost: () -> Unit)

    fun unwatchOutputLoss()
}

object VoiceRoute {
    // Plain ints: the BLE types are API 31+, and only an API 31+ turn reads them.
    @SuppressLint("InlinedApi")
    private val BLUETOOTH =
        setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
        )

    private val HEADPHONES =
        setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
        )

    /** Whether removing devices of these types takes away a reply's personal output (not the loudspeaker). */
    fun isOutputLoss(removedTypes: Collection<Int>): Boolean = removedTypes.any { it in BLUETOOTH || it in HEADPHONES }

    /**
     * The route label from the device TYPES only, never a device's name (that
     * is the name the person gave it, often their own). Same order as iOS
     * `VoiceAudioSession.routeLabel`: Bluetooth, then Car, then Headphones.
     * Android has no car output type on a phone, so "Car" is the system's car
     * mode (Android Auto).
     */
    fun label(
        deviceTypes: Collection<Int>,
        carMode: Boolean,
    ): String? =
        when {
            deviceTypes.any { it in BLUETOOTH } -> "Bluetooth"
            carMode -> "Car"
            deviceTypes.any { it in HEADPHONES } -> "Headphones"
            else -> null
        }

    /**
     * Whether an audio focus change ends the turn. Only a PERMANENT loss does:
     * a transient one (a notification sound, navigation, a podcast ducking or
     * pausing around another app) leaves the turn open, as iOS's mixable
     * session does.
     */
    fun focusEndsTurn(focusChange: Int): Boolean = focusChange == AudioManager.AUDIOFOCUS_LOSS

    /** Whether the phone's audio mode means a call took the audio. */
    @SuppressLint("InlinedApi") // MODE_CALL_SCREENING is an inlined API 30 int
    fun modeEndsTurn(mode: Int): Boolean =
        mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION ||
            mode == AudioManager.MODE_RINGTONE ||
            mode == AudioManager.MODE_CALL_SCREENING
}

/**
 * The Voice tab's audio, for an open turn only. Capture asks for
 * `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`, never an exclusive gain, so a
 * podcast ducks (or pauses, if it chooses) instead of losing focus for good,
 * and the turn hears about a call. No manifest change: RECORD_AUDIO and
 * MODIFY_AUDIO_SETTINGS are already declared.
 */
@RequiresApi(Build.VERSION_CODES.S)
class SystemVoiceAudio(
    private val context: Context,
) : VoiceAudioControl {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val uiMode = context.getSystemService(UiModeManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { main.post(it) }
    private var listener: VoiceAudioListener? = null
    private var focus: AudioFocusRequest? = null

    internal val focusListener = AudioManager.OnAudioFocusChangeListener { change -> onFocusChange(change) }
    private val modeListener = AudioManager.OnModeChangedListener { mode -> onModeChanged(mode) }
    private val devices =
        object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                listener?.onRouteChanged()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                listener?.onRouteChanged()
            }
        }

    private var onOutputLost: (() -> Unit)? = null

    internal val outputs =
        object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                if (VoiceRoute.isOutputLoss(removedDevices.orEmpty().map { it.type })) onOutputLost?.invoke()
            }
        }

    private val noisy =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) onOutputLost?.invoke()
            }
        }

    override val inCall: Boolean get() = VoiceRoute.modeEndsTurn(audio.mode)

    override val othersRecording: Boolean get() = audio.activeRecordingConfigurations.isNotEmpty()

    override val routeLabel: String?
        get() =
            VoiceRoute.label(
                (audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS) + audio.getDevices(AudioManager.GET_DEVICES_INPUTS)).map { it.type },
                uiMode?.currentModeType == Configuration.UI_MODE_TYPE_CAR,
            )

    override fun beginCapture(listener: VoiceAudioListener) {
        endCapture()
        this.listener = listener
        val request =
            AudioFocusRequest
                .Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(
                    AudioAttributes
                        .Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                ).setOnAudioFocusChangeListener(focusListener, main)
                .build()
        // Refused focus does not stop the mic: capture does not need it.
        audio.requestAudioFocus(request)
        focus = request
        audio.addOnModeChangedListener(mainExecutor, modeListener)
        audio.registerAudioDeviceCallback(devices, main)
    }

    override fun endCapture() {
        if (listener == null) return
        listener = null
        focus?.let { audio.abandonAudioFocusRequest(it) }
        focus = null
        audio.removeOnModeChangedListener(modeListener)
        audio.unregisterAudioDeviceCallback(devices)
    }

    override fun watchOutputLoss(onLost: () -> Unit) {
        unwatchOutputLoss()
        onOutputLost = onLost
        audio.registerAudioDeviceCallback(outputs, main)
        // A protected system broadcast: delivered to a not-exported receiver.
        ContextCompat.registerReceiver(
            context,
            noisy,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun unwatchOutputLoss() {
        if (onOutputLost == null) return
        onOutputLost = null
        audio.unregisterAudioDeviceCallback(outputs)
        context.unregisterReceiver(noisy)
    }

    internal fun onFocusChange(change: Int) {
        if (VoiceRoute.focusEndsTurn(change)) listener?.onInterrupted()
    }

    internal fun onModeChanged(mode: Int) {
        if (VoiceRoute.modeEndsTurn(mode)) listener?.onInterrupted()
    }
}

/** The reply's audio focus: `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`, so a podcast ducks or pauses and then resumes. */
class SystemReplyFocus(
    context: Context,
) : ReplyFocus {
    private val audio = context.getSystemService(AudioManager::class.java)
    private var held: AudioFocusRequest? = null

    override fun request() {
        if (held != null) return
        val request =
            AudioFocusRequest
                .Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(
                    AudioAttributes
                        .Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                ).build()
        audio.requestAudioFocus(request)
        held = request
    }

    override fun abandon() {
        val request = held ?: return
        held = null
        audio.abandonAudioFocusRequest(request)
    }
}
