package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PickerBackTest {
    private val store = InstallStore(InMemoryKeyValueStore(), InMemoryKeyValueStore())
    private val pickerReturn = PickerReturn(store)

    private val a = "suite.example.com"
    private val b = "suite.example.com"

    /** Install A open and confirmed, as after a Continue. */
    private fun confirmA() {
        store.select(a)
        store.confirmSelection()
    }

    @Test
    fun `a sub-screen beats everything`() {
        for (current in listOf(null, "a")) {
            for (restore in listOf(null, "a")) {
                assertEquals(PickerBack.CLOSE_SUB_SCREEN, PickerBack.decide(true, current, restore))
            }
        }
    }

    @Test
    fun `an install on screen is dismissed to`() {
        assertEquals(PickerBack.DISMISS_TO_CURRENT, PickerBack.decide(false, "a", "a"))
        assertEquals(PickerBack.DISMISS_TO_CURRENT, PickerBack.decide(false, "a", null))
    }

    @Test
    fun `a cold switch picker opens the restored install`() {
        assertEquals(PickerBack.OPEN_RESTORED, PickerBack.decide(false, null, "a"))
    }

    @Test
    fun `with nothing to return to, back is the system's`() {
        assertEquals(PickerBack.SYSTEM, PickerBack.decide(false, null, null))
    }

    @Test
    fun `backing out of the switch picker after tapping another row keeps the current install selected`() {
        confirmA()
        pickerReturn.onPresent(switching = true)
        store.select(b) // the row tap, before Continue
        assertEquals(PickerBack.DISMISS_TO_CURRENT, pickerReturn.decide(hasSubScreen = false, currentHost = a))
        pickerReturn.restoreSelection()
        assertEquals(a, store.selectedHost)
        assertTrue(store.hasConfirmedSelection)
    }

    @Test
    fun `a cold switch picker backs out onto the install that was current`() {
        confirmA()
        pickerReturn.onPresent(switching = true)
        store.select(b)
        assertEquals(PickerBack.OPEN_RESTORED, pickerReturn.decide(hasSubScreen = false, currentHost = null))
        assertEquals(a, pickerReturn.restoreSelection()?.host)
        assertEquals(a, store.selectedHost)
    }

    @Test
    fun `a second shortcut over an open switch picker keeps the first install`() {
        confirmA()
        pickerReturn.onPresent(switching = true)
        store.select(b)
        pickerReturn.onPresent(switching = true)
        assertEquals(a, pickerReturn.restoreHost)
    }

    @Test
    fun `the sign-out and sign-in-failed picker never returns anywhere`() {
        confirmA()
        // finishSignOut / abandonInstall: currentInstall is null, plain picker.
        pickerReturn.onPresent(switching = false)
        assertNull(pickerReturn.restoreHost)
        assertEquals(PickerBack.SYSTEM, pickerReturn.decide(hasSubScreen = false, currentHost = null))
    }

    @Test
    fun `a first-launch switch picker has nothing to return to`() {
        pickerReturn.onPresent(switching = true)
        assertNull(pickerReturn.restoreHost)
        assertEquals(PickerBack.SYSTEM, pickerReturn.decide(hasSubScreen = false, currentHost = null))
    }

    @Test
    fun `an install removed from the picker is not returned to`() {
        confirmA()
        pickerReturn.onPresent(switching = true)
        store.remove(a)
        assertEquals(PickerBack.SYSTEM, pickerReturn.decide(hasSubScreen = false, currentHost = null))
    }

    @Test
    fun `clear forgets the install`() {
        confirmA()
        pickerReturn.onPresent(switching = true)
        pickerReturn.clear()
        assertNull(pickerReturn.restoreSelection())
        assertEquals(PickerBack.SYSTEM, pickerReturn.decide(hasSubScreen = false, currentHost = null))
    }
}
