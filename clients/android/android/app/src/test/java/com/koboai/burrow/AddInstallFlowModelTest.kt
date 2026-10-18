package com.koboai.burrow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The add-your-install state machine (task 01a12787 stage 4): idle ->
 * checking -> confirm | notFound | offline, with an injected probe. Mirrors
 * iOS AddInstallFlowModelTests.
 */
class AddInstallFlowModelTest {
    private val store = InstallStore(InMemoryKeyValueStore(), InMemoryKeyValueStore())
    private val launched = mutableListOf<Install>()

    /** Background work queued until the test runs it, so CHECKING can be observed. */
    private val pending = mutableListOf<() -> Unit>()
    private val probed = mutableListOf<String>()

    private fun model(result: InstallCheck) =
        AddInstallFlowModel(
            store = store,
            probe = { host ->
                probed.add(host)
                result
            },
            onContinue = { launched.add(it) },
            background = { pending.add(it) },
            main = { it() },
        )

    private fun runPending() {
        val work = pending.toList()
        pending.clear()
        work.forEach { it() }
    }

    /** strings.xml, parsed: the copy the view shows. The unit-test working directory is the app module. */
    private val strings: Map<String, String> by lazy {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(java.io.File("src/main/res/values/strings.xml"))
        val nodes = doc.getElementsByTagName("string")
        (0 until nodes.length).associate { i ->
            val node = nodes.item(i)
            node.attributes.getNamedItem("name").nodeValue to node.textContent.replace("\\'", "'")
        }
    }

    @Test
    fun `checks then shows the confirmation card`() {
        val model = model(InstallCheck.Found("Acme"))
        val states = mutableListOf<AddInstallFlowModel.State>()
        model.onChange = { states.add(it) }
        assertEquals(AddInstallFlowModel.State.Idle, model.state)
        assertFalse("nothing typed", model.canSubmit)
        model.address = "https://Acme.Burrow.app/chat  "
        assertEquals(R.string.add_flow_continue, model.buttonRes)

        model.submit()
        assertEquals(AddInstallFlowModel.State.Checking, model.state)
        assertEquals(R.string.add_flow_checking, model.buttonRes)
        assertFalse("Continue is disabled while checking", model.canSubmit)
        model.submit()
        assertEquals("a second press while checking does nothing", 1, pending.size)
        model.address = "https://Acme.Burrow.app/chat"
        assertEquals("the field stays editable", "https://Acme.Burrow.app/chat", model.address)

        runPending()
        assertEquals(listOf("acme.burrow.app"), probed)
        val card = AddInstallFlowModel.State.Confirm("acme.burrow.app", "Acme")
        assertEquals(card, model.state)
        assertEquals("Acme", card.displayName)
        assertEquals("acme.burrow.app", AddInstallFlowModel.State.Confirm("acme.burrow.app", null).displayName)
        assertEquals(Install("acme.burrow.app").iconUrl, card.iconUrl)
        assertNull(model.messageRes)
        assertEquals(listOf(AddInstallFlowModel.State.Checking, card), states)
    }

    @Test
    fun `not found names the host and saves nothing`() {
        val model = model(InstallCheck.NotFound)
        model.address = "acme.burow.app "
        model.submit()
        runPending()
        assertEquals(AddInstallFlowModel.State.NotFound("acme.burow.app"), model.state)
        assertEquals(R.string.add_flow_not_found, model.messageRes)
        assertEquals(
            "No Burrow install answered at acme.burow.app. Check the spelling, or ask the person who invited you.",
            strings.getValue("add_flow_not_found").replace("%1\$s", "acme.burow.app"),
        )
        assertTrue(store.installs.isEmpty())
    }

    @Test
    fun `an address that is not a host is not found without a probe`() {
        val model = model(InstallCheck.Found(null))
        model.address = "not a host"
        model.submit()
        assertTrue(pending.isEmpty())
        assertTrue(probed.isEmpty())
        assertEquals(AddInstallFlowModel.State.NotFound("not a host"), model.state)
    }

    @Test
    fun `offline never shows the not-found copy`() {
        // The probe calls a connection error on an unvalidated network offline...
        assertEquals(InstallCheck.Offline, InstallProbe.classify(UnknownHostException("acme.burrow.app"), networkValidated = false))
        assertEquals(InstallCheck.Offline, InstallProbe.classify(ConnectException("refused"), networkValidated = false))
        // ...and the same error on a working network, or any other failure, not found.
        assertEquals(InstallCheck.NotFound, InstallProbe.classify(UnknownHostException("acme.burow.app"), networkValidated = true))
        assertEquals(InstallCheck.NotFound, InstallProbe.classify(ConnectException("refused"), networkValidated = true))
        assertEquals(InstallCheck.NotFound, InstallProbe.classify(SocketTimeoutException(), networkValidated = false))
        assertEquals(InstallCheck.NotFound, InstallProbe.classify(SSLHandshakeException("x"), networkValidated = false))

        val model = model(InstallCheck.Offline)
        model.address = "acme.burrow.app"
        model.submit()
        runPending()
        assertEquals(AddInstallFlowModel.State.Offline, model.state)
        assertEquals(R.string.add_flow_offline, model.messageRes)
        assertNotEquals(R.string.add_flow_not_found, model.messageRes)
        assertEquals("You're offline. Connect and try again.", strings.getValue("add_flow_offline"))
        assertFalse(strings.getValue("add_flow_offline").contains("No Burrow install answered"))
    }

    @Test
    fun `confirm adds, selects and confirms, then launches`() {
        val model = model(InstallCheck.Found("Acme"))
        assertNull("nothing to confirm before a check", model.confirm())
        assertTrue(launched.isEmpty())

        model.address = "acme.burrow.app"
        model.submit()
        runPending()
        val install = model.confirm()
        assertEquals(Install("acme.burrow.app", "Acme"), install)
        assertEquals(listOf(Install("acme.burrow.app", "Acme")), store.installs)
        assertEquals("acme.burrow.app", store.selectedHost)
        assertTrue(store.hasConfirmedSelection)
        assertEquals(listOf(Install("acme.burrow.app", "Acme")), launched)
    }

    @Test
    fun `change address keeps the typed text`() {
        val model = model(InstallCheck.Found("Stranger"))
        model.address = "acme.burow.app"
        model.submit()
        runPending()
        assertEquals(AddInstallFlowModel.State.Confirm("acme.burow.app", "Stranger"), model.state)
        model.changeAddress()
        assertEquals(AddInstallFlowModel.State.Idle, model.state)
        assertEquals("acme.burow.app", model.address)
        assertTrue("changing the address saves nothing", store.installs.isEmpty())
        assertTrue(launched.isEmpty())
    }

    @Test
    fun `the copy is the canvas's and the placeholder is the example host`() {
        assertEquals("yourteam.example.com", strings.getValue("add_flow_placeholder"))
        assertFalse(ShippedHostScanTest.namesPersonalHost(strings.getValue("add_flow_placeholder")))
        assertEquals("Add your install", strings.getValue("add_flow_title"))
        assertEquals("Enter the address your team uses for Burrow.", strings.getValue("add_flow_body"))
        assertEquals("Continue", strings.getValue("add_flow_continue"))
        assertEquals("Checking...", strings.getValue("add_flow_checking"))
        assertEquals("Don't know it? Ask the person who invited you.", strings.getValue("add_flow_help"))
        assertEquals("Continue to sign in", strings.getValue("add_flow_continue_to_sign_in"))
        assertEquals("Not this one? Change address", strings.getValue("add_flow_change_address"))
    }
}
