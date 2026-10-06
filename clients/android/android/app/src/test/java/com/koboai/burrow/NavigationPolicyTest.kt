package com.koboai.burrow

import com.koboai.burrow.NavigationDecision.ALLOW
import com.koboai.burrow.NavigationDecision.BLOCK
import com.koboai.burrow.NavigationDecision.OPEN_EXTERNALLY
import com.koboai.burrow.NavigationDecision.SIGN_OUT
import com.koboai.burrow.NavigationDecision.START_NATIVE_LOGIN
import org.junit.Assert.assertEquals
import org.junit.Test

class NavigationPolicyTest {
    private val policy = NavigationPolicy("suite.example.com")

    private fun main(url: String?) = policy.decide(url, isMainFrame = true)

    private fun frame(url: String) = policy.decide(url, isMainFrame = false)

    @Test
    fun `the install host stays in the view`() {
        assertEquals(ALLOW, main("https://suite.example.com/chat/general"))
        assertEquals(ALLOW, main("https://SUITE.example.com/"))
        assertEquals(ALLOW, main(null))
        assertEquals(ALLOW, main("about:blank"))
        assertEquals(ALLOW, main("blob:https://suite.example.com/1234"))
    }

    @Test
    fun `every other host opens in the browser`() {
        assertEquals(OPEN_EXTERNALLY, main("https://github.com/Startup-Suite/core"))
        assertEquals(OPEN_EXTERNALLY, main("https://suite.milv.life/"))
        // A look-alike host is another host.
        assertEquals(OPEN_EXTERNALLY, main("https://suite.example.com.evil.example/"))
        assertEquals(OPEN_EXTERNALLY, main("https://evil.example/?next=https://suite.example.com/"))
        assertEquals(OPEN_EXTERNALLY, main("mailto:someone@example.com"))
        assertEquals(OPEN_EXTERNALLY, main("tel:+15555550100"))
    }

    @Test
    fun `sub-frames load whatever their host`() {
        assertEquals(ALLOW, frame("https://www.youtube.com/embed/x"))
        assertEquals(ALLOW, frame("https://suite.example.com/auth/logout"))
    }

    @Test
    fun `the install's own login goes native unless it is the native flow's URL`() {
        assertEquals(START_NATIVE_LOGIN, main("https://suite.example.com/auth/login"))
        assertEquals(START_NATIVE_LOGIN, main("https://suite.example.com/auth/login?return_to=/chat"))
        assertEquals(ALLOW, main("https://suite.example.com/auth/login?app_challenge=abc"))
        // Another host's /auth/login is just another host.
        assertEquals(OPEN_EXTERNALLY, main("https://suite.milv.life/auth/login"))
    }

    @Test
    fun `the install's own logout signs out natively`() {
        assertEquals(SIGN_OUT, main("https://suite.example.com/auth/logout"))
        assertEquals(OPEN_EXTERNALLY, main("https://suite.milv.life/auth/logout"))
    }

    @Test
    fun `the app's own scheme and component schemes are blocked`() {
        assertEquals(BLOCK, main("burrow://auth/callback?code=abc"))
        assertEquals(BLOCK, main("intent://scan/#Intent;scheme=zxing;end"))
        assertEquals(BLOCK, main("file:///data/data/com.koboai.burrow/shared_prefs/x.xml"))
        assertEquals(BLOCK, main("content://com.koboai.burrow.fileprovider/x"))
        assertEquals(BLOCK, main("https://bad host/"))
    }
}
