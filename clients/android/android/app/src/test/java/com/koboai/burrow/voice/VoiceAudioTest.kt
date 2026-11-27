package com.koboai.burrow.voice

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.shadows.ShadowLooper

@RunWith(RobolectricTestRunner::class)
class VoiceAudioTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val manager = context.getSystemService(AudioManager::class.java)
    private val audio = SystemVoiceAudio(context)

    private class Heard : VoiceAudioListener {
        var interrupted = 0
        var routes = 0

        override fun onInterrupted() {
            interrupted++
        }

        override fun onRouteChanged() {
            routes++
        }
    }

    @Test
    fun `route labels come from device types, in the iOS order`() {
        assertNull(VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_BUILTIN_MIC, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER), false))
        assertEquals("Bluetooth", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP), false))
        assertEquals("Bluetooth", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO), false))
        assertEquals("Bluetooth", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_BLE_HEADSET), false))
        assertEquals("Headphones", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_WIRED_HEADSET), false))
        assertEquals("Headphones", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_USB_HEADSET), false))
        assertEquals("Car", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER), true))
        // Bluetooth first, then Car, then Headphones.
        assertEquals("Bluetooth", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_BLE_HEADSET), true))
        assertEquals("Car", VoiceRoute.label(listOf(AudioDeviceInfo.TYPE_WIRED_HEADSET), true))
    }

    @Test
    fun `capture asks for may-duck focus, never an exclusive gain, and gives it back`() {
        audio.beginCapture(Heard())
        val request = shadowOf(manager).lastAudioFocusRequest
        assertEquals(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK, request.durationHint)
        assertTrue(request.durationHint != AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
        audio.endCapture()
        assertSame(request.audioFocusRequest, shadowOf(manager).lastAbandonedAudioFocusRequest)
    }

    @Test
    fun `a podcast's transient focus loss does not end the turn, a permanent loss does`() {
        val heard = Heard()
        audio.beginCapture(heard)
        val listener = shadowOf(manager).lastAudioFocusRequest.listener
        listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        assertEquals(0, heard.interrupted)
        listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        assertEquals(1, heard.interrupted)
    }

    @Test
    fun `a phone call during the turn interrupts it`() {
        val heard = Heard()
        audio.beginCapture(heard)
        manager.mode = AudioManager.MODE_IN_CALL
        ShadowLooper.idleMainLooper()
        assertEquals(1, heard.interrupted)
    }

    @Test
    fun `the call state and other recordings are read live`() {
        assertFalse(audio.inCall)
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        assertTrue("a meeting call in the WebView", audio.inCall)
        manager.mode = AudioManager.MODE_NORMAL
        assertFalse(audio.othersRecording)
        val shadow = shadowOf(manager)
        shadow.setActiveRecordingConfigurations(listOf(shadow.createActiveRecordingConfiguration(0, 1, "other")), false)
        assertTrue(audio.othersRecording)
    }

    @Test
    fun `nothing is heard after the capture ends`() {
        val heard = Heard()
        audio.beginCapture(heard)
        val listener = shadowOf(manager).lastAudioFocusRequest.listener
        audio.endCapture()
        listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        audio.onModeChanged(AudioManager.MODE_IN_CALL)
        assertEquals(0, heard.interrupted)
    }

    @Test
    fun `mode and focus rules`() {
        assertTrue(VoiceRoute.modeEndsTurn(AudioManager.MODE_IN_CALL))
        assertTrue(VoiceRoute.modeEndsTurn(AudioManager.MODE_IN_COMMUNICATION))
        assertTrue(VoiceRoute.modeEndsTurn(AudioManager.MODE_RINGTONE))
        assertFalse(VoiceRoute.modeEndsTurn(AudioManager.MODE_NORMAL))
        assertTrue(VoiceRoute.focusEndsTurn(AudioManager.AUDIOFOCUS_LOSS))
        assertFalse(VoiceRoute.focusEndsTurn(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT))
        assertFalse(VoiceRoute.focusEndsTurn(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK))
    }

    @Test
    fun `removing a personal output is an output loss, the loudspeaker is not`() {
        assertTrue(VoiceRoute.isOutputLoss(listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)))
        assertTrue(VoiceRoute.isOutputLoss(listOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)))
        assertTrue(VoiceRoute.isOutputLoss(listOf(AudioDeviceInfo.TYPE_BLE_HEADSET)))
        assertTrue(VoiceRoute.isOutputLoss(listOf(AudioDeviceInfo.TYPE_WIRED_HEADPHONES)))
        assertFalse(VoiceRoute.isOutputLoss(listOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)))
        assertFalse(VoiceRoute.isOutputLoss(emptyList()))
    }

    @Test
    fun `audio becoming noisy or a removed headset reports the output lost`() {
        var lost = 0
        audio.watchOutputLoss { lost++ }
        context.sendBroadcast(Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        ShadowLooper.idleMainLooper()
        assertEquals(1, lost)
        val headset = AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP).build()
        val speaker = AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER).build()
        audio.outputs.onAudioDevicesRemoved(arrayOf(speaker))
        assertEquals(1, lost)
        audio.outputs.onAudioDevicesRemoved(arrayOf(headset))
        assertEquals(2, lost)
        audio.unwatchOutputLoss()
        context.sendBroadcast(Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        ShadowLooper.idleMainLooper()
        assertEquals(2, lost)
    }

    @Test
    fun `a reply asks for may-duck focus and gives it back`() {
        val focus = SystemReplyFocus(context)
        focus.request()
        val request = shadowOf(manager).lastAudioFocusRequest
        assertEquals(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK, request.durationHint)
        assertEquals(AudioAttributes.USAGE_ASSISTANT, request.audioFocusRequest.audioAttributes.usage)
        focus.abandon()
        assertSame(request.audioFocusRequest, shadowOf(manager).lastAbandonedAudioFocusRequest)
    }
}
