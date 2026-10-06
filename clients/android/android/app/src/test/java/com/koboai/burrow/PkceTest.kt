package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PkceTest {
    @Test
    fun `challenge matches the RFC 7636 appendix B test vector`() {
        assertEquals(
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            Pkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        )
    }

    @Test
    fun `verifier is 43 base64url characters and fresh each time`() {
        val a = Pkce.makeVerifier()
        val b = Pkce.makeVerifier()
        assertEquals(43, a.length)
        assertTrue(a.matches(Regex("^[A-Za-z0-9_-]{43}$")))
        assertNotEquals(a, b)
    }

    @Test
    fun `login URL carries the S256 challenge of the session's own verifier`() {
        val verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        val session = AuthSession(Install("suite.example.com"), verifier)
        assertEquals(
            "https://suite.example.com/auth/login?app_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            session.loginUrl,
        )
        assertTrue(verifier !in session.toString())
    }
}
