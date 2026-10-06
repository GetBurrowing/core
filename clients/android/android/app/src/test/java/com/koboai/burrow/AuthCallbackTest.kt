package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AuthCallbackTest {
    @Test
    fun `reads the code from burrow-auth-callback`() {
        assertEquals("abc123", AuthCallback.code("burrow://auth/callback?code=abc123"))
        assertEquals("a b+c", AuthCallback.code("burrow://auth/callback?state=x&code=a%20b%2Bc"))
        assertEquals("XYZ", AuthCallback.code("BURROW://AUTH/callback?code=XYZ"))
    }

    @Test
    fun `rejects anything that is not exactly burrow-auth-callback`() {
        listOf(
            null,
            "",
            "https://auth/callback?code=x",
            "https://suite.example.com/auth/callback?code=x",
            "burrow://evil/callback?code=x",
            "burrow://auth/callback/extra?code=x",
            "burrow://auth/callbackx?code=x",
            "burrow://auth/?code=x",
            "burrow://auth:99/callback?code=x",
            "burrow://user@auth/callback?code=x",
            "burrow://auth/callback",
            "burrow://auth/callback?code=",
            "burrow://auth/callback?xcode=x",
            "burrowx://auth/callback?code=x",
            "not a uri at all",
        ).forEach { assertNull(it, AuthCallback.code(it)) }
    }
}
