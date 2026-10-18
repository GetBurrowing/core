package com.koboai.burrow

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.activity.result.ActivityResult
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.ActivityCallback
import com.getcapacitor.annotation.CapacitorPlugin
import com.koboai.burrow.push.BurrowPush
import com.koboai.burrow.push.EnableOutcome
import com.koboai.burrow.push.PermissionExplainerActivity
import com.koboai.burrow.push.PermissionStep
import com.koboai.burrow.push.PushError
import com.koboai.burrow.push.PushPermission
import com.koboai.burrow.share.AppShareClient
import com.koboai.burrow.shortcuts.ConversationNoter
import com.koboai.burrow.shortcuts.ConversationShortcuts
import com.koboai.burrow.shortcuts.DonateDispatch
import com.koboai.burrow.shortcuts.Recipient
import org.json.JSONArray
import java.util.concurrent.Executors

/**
 * The app's ONE Capacitor plugin. Web JS reaches it as `SuiteNative`, the
 * wire name older core JS looks up; core JS from task 01a14ba9 on also reads
 * `BurrowNative`, and the name flips in a later app release. Every native capability
 * the web UI reaches goes through it, with the same contract as iOS
 * (`apps/platform/assets/js/hooks/push_subscribe.js`, `mountNative/1`):
 *
 * - `pushState()` resolves `{state: "granted" | "denied" | "prompt"}`
 *   ([PushPermission.state]);
 * - `enablePush()` resolves `{registered: true, state: "granted"}` ONLY when
 *   `POST /api/app/devices` answered 2xx, `{registered: false, state:
 *   "denied"}` when the person said no, and otherwise rejects with
 *   `not_signed_in`, `token_failed` or `registration_failed`;
 * - `switchInstall()` opens the install picker;
 * - `installBadges()` resolves `{others_unread: boolean}`: whether any
 *   signed-in install OTHER than the one showing has unread (task 01a1261e;
 *   the contract is stage 3's `native_install_switch.js`, verbatim). The
 *   shell fires the window event `burrowInstallBadges` (no payload) when
 *   the counts may have changed, and the page asks again;
 * - `donate(detail)` takes 01a111bb's `native_donate` payload (ids only,
 *   forwarded by `assets/js/native_donations.js`). `message_sent` notes the
 *   conversation as a used shortcut ([ConversationNoter]); every other kind
 *   resolves and does nothing ([DonateDispatch]).
 *
 * On Android 13+ `enablePush` shows the native explainer before the system
 * prompt. The web hook calls `enablePush` on mount when the state is
 * "prompt", so the explainer IS that call's UI: there is no second, native
 * trigger, and the two can never stack two prompts. Concurrent calls share
 * one flow.
 *
 * A later meetings plugin (v2) registers beside this one rather than
 * growing it.
 */
@CapacitorPlugin(name = "SuiteNative")
class BurrowNativePlugin : Plugin() {
    private val io = Executors.newSingleThreadExecutor()
    private val waiting = mutableListOf<PluginCall>()

    @PluginMethod
    fun pushState(call: PluginCall) {
        val state =
            PushPermission.state(
                Build.VERSION.SDK_INT,
                BurrowPush.notificationsEnabled(context),
                BurrowPush.prefs(context).explainerShown,
            )
        call.resolve(JSObject().put("state", state))
    }

    @PluginMethod
    fun enablePush(call: PluginCall) {
        val host = (activity as? MainActivity)?.currentHost
        if (host == null || !BurrowPush.tokens(context).let { it.token(host) != null }) {
            call.reject("Not signed in to this install", PushError.NOT_SIGNED_IN)
            return
        }
        val first = synchronized(waiting) { waiting.add(call).let { waiting.size == 1 } }
        if (!first) return // the running flow answers this call too

        val prefs = BurrowPush.prefs(context)
        val step =
            PushPermission.nextStep(
                Build.VERSION.SDK_INT,
                BurrowPush.notificationsEnabled(context),
                prefs.systemAsked,
                canAskAgain(),
            )
        when (step) {
            PermissionStep.REGISTER -> register(host)
            PermissionStep.DENIED -> answer(EnableOutcome.Denied)
            PermissionStep.EXPLAIN, PermissionStep.EXPLAIN_DENIED_PERMANENTLY -> {
                prefs.explainerShown = true
                val variant =
                    if (step == PermissionStep.EXPLAIN) {
                        PermissionExplainerActivity.VARIANT_ASK
                    } else {
                        PermissionExplainerActivity.VARIANT_DENIED_PERMANENTLY
                    }
                val intent =
                    Intent(context, PermissionExplainerActivity::class.java)
                        .putExtra(PermissionExplainerActivity.EXTRA_VARIANT, variant)
                startActivityForResult(call, intent, "explainerResult")
            }
        }
    }

    @ActivityCallback
    private fun explainerResult(
        call: PluginCall?,
        result: ActivityResult,
    ) {
        call?.let { bridge.releaseCall(it) }
        val host = (activity as? MainActivity)?.currentHost
        if (result.resultCode == PermissionExplainerActivity.RESULT_GRANTED && host != null) {
            register(host)
        } else {
            answer(EnableOutcome.Denied)
        }
    }

    @PluginMethod
    fun donate(call: PluginCall) {
        val kind = call.getString("kind")
        if (kind != DonateDispatch.MESSAGE_SENT) {
            call.resolve()
            return
        }
        val host = (activity as? MainActivity)?.currentHost
        val spaceId = call.getString("space_id")
        val recipients = recipients(call.getArray("recipient_ids"))
        io.execute {
            when (val outcome = DonateDispatch.dispatch(kind, spaceId, recipients, host, noter())) {
                DonateDispatch.Outcome.Ok -> call.resolve()
                is DonateDispatch.Outcome.Rejected -> call.reject("Conversation not noted: ${outcome.code}", outcome.code)
            }
        }
    }

    /** One per plugin, so its spaces cache lives as long as the page. */
    private var conversationNoter: ConversationNoter? = null

    private fun noter(): ConversationNoter =
        conversationNoter ?: ConversationNoter(
            AppShareClient(BurrowPush.client(context)),
            ConversationShortcuts.forContext(context),
        ).also { conversationNoter = it }

    @PluginMethod
    fun installBadges(call: PluginCall) {
        val selected = (activity as? MainActivity)?.currentHost
        val app = context.applicationContext
        io.execute { call.resolve(installBadgesAnswer(BurrowPush.unread(app).othersUnread(selected))) }
    }

    @PluginMethod
    fun switchInstall(call: PluginCall) {
        val shell = activity as? MainActivity
        activity.runOnUiThread {
            shell?.presentPicker()
            call.resolve()
        }
    }

    override fun handleOnDestroy() {
        io.shutdown()
        super.handleOnDestroy()
    }

    private fun register(host: String) {
        val app = context.applicationContext
        io.execute {
            BurrowPush.ensureChannels(app, host)
            answer(BurrowPush.registrar(app).outcome(host))
        }
    }

    private fun answer(outcome: EnableOutcome) {
        when (outcome) {
            EnableOutcome.Registered -> finishAll { it.resolve(JSObject().put("registered", true).put("state", "granted")) }
            EnableOutcome.Denied -> finishAll { it.resolve(denied()) }
            is EnableOutcome.Failed -> finishAll { it.reject("Push registration failed: ${outcome.code}", outcome.code) }
        }
    }

    private fun finishAll(answer: (PluginCall) -> Unit) {
        val calls = synchronized(waiting) { waiting.toList().also { waiting.clear() } }
        calls.forEach(answer)
    }

    private fun recipients(array: JSONArray?): List<Recipient> {
        if (array == null) return emptyList()
        return (0 until array.length()).mapNotNull { i ->
            val o = array.optJSONObject(i) ?: return@mapNotNull null
            val type = o.optString("type").ifEmpty { return@mapNotNull null }
            val id = o.optString("id").ifEmpty { return@mapNotNull null }
            Recipient(type, id)
        }
    }

    private fun denied() = JSObject().put("registered", false).put("state", "denied")

    companion object {
        /** `installBadges`'s answer, exactly `{others_unread: boolean}`. */
        fun installBadgesAnswer(othersUnread: Boolean): JSObject = JSObject().put("others_unread", othersUnread)

        /** The window event the page re-queries `installBadges` on. */
        const val BADGES_EVENT = "burrowInstallBadges"
    }

    private fun canAskAgain(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
}
