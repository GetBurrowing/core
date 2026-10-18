defmodule PlatformWeb.Components.NotificationState do
  @moduledoc """
  The durable home for the browser's notification-permission state (task
  019ffb7b stage 4, revised after Marlowe's review).

  One row, rendered at the top of `/inbox`. It answers "will this computer
  interrupt me?" on a surface every authenticated user can reach, internal and
  external alike, and it is the only permanent place that answer lives.

  ## Why `/inbox` and not the rail or a settings page

  The first cut of this stage put a bell in the desktop icon rail. Marlowe
  rejected it on review: a rail row whose only behaviour was opening a panel
  collided with the Inbox tile beside it, which holds the actual activity
  notifications, and a rail row that navigates nowhere is not a rail row.
  Settings was the obvious alternative and does not exist — there is no
  `/settings` route, and the rail's bottom gear is Admin (`root_only?: true`,
  gated on `root_user`), so external and non-admin internal users would
  never see it, and this feature has to cover external users.

  `InboxLive` runs the `:authenticated` `live_session`, whose `on_mount` chain
  includes `PlatformWeb.ShellLive`, so `@push_permission` is already in its
  assigns with no extra wiring. The `PushSubscribe` hook that reports the state
  is mounted on the shell, so it covers `/inbox` like every other route.

  ## What renders

      unknown      nothing. The client has not reported yet, so anything drawn
                   would be a guess that flickers a moment later.
      unsupported  nothing. The browser has no Notification API; a control it
                   could never honour has no business on the page.
      prompt       offer row + one primary action.
      denied       warning row, NO action (see `notification_state_row/1`).
      granted      nothing. The healthy case adds nothing to the page,
                   UNLESS `@registration_failed` names a reason: two
                   granted-but-not-registered rows, one per reason
                   (task 019ffe52 stage 3).
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr :push_permission, :string,
    required: true,
    doc:
      "browser notification-permission state from ShellLive's :push_permission assign. " <>
        "One of \"unknown\" | \"prompt\" | \"granted\" | \"denied\" | \"unsupported\". " <>
        "Only \"prompt\" and \"denied\" render anything."

  attr :user_agent, :string,
    default: nil,
    doc:
      "raw user-agent header, read server-side from the LiveView connect info by " <>
        "ShellLive. Names the browser in the blocked row's instruction. nil or " <>
        "anything unrecognised falls back to the generic wording."

  attr :auto_denied, :boolean,
    default: false,
    doc:
      "true when the browser refused the permission request without ever showing " <>
        "the user a dialog, detected by how fast it answered (see " <>
        "assets/js/hooks/push_subscribe.js). Rides ALONGSIDE :push_permission; it " <>
        "is not a sixth permission value."

  attr :native_platform, :string,
    default: nil,
    doc:
      "the native shell the PushSubscribe hook reported (\"android\" | \"ios\"), or " <>
        "nil in a browser. Rides ALONGSIDE :push_permission. Only \"android\" changes " <>
        "anything: see `notification_state_row/1`'s \"Inside Burrow Android\" section."

  attr :registration_failed, :atom,
    default: nil,
    values: [nil, :no_participant, :subscribe_failed],
    doc:
      "WHY the browser granted permission and Burrow still failed to store the " <>
        "subscription, or nil when it did not (task 019ffe52). Rides ALONGSIDE " <>
        ":push_permission for the same reason :auto_denied does: the permission " <>
        "is truthfully \"granted\", so the failure is a second fact, not a sixth " <>
        "value. A REASON rather than a boolean because the two failures need " <>
        "opposite instructions; see notification_state_row/1's moduledoc."

  @doc """
  Notification-state row for `/inbox`.

  Three renderings, and the difference between them is the whole point:

    * `prompt` — an offer, carrying the one action that works. The button
      fires `enable_notifications`, handled by `ShellLive`'s `:push_events`
      attach, which pushes `request_push_permission` to the `PushSubscribe`
      hook.
    * `denied` — a statement of fact with NO button. No web API can re-prompt
      after a browser-level block, and no page can open browser settings, so
      any button here would silently do nothing every time it was pressed.
      Never add one; the instruction line is the only thing that works. The
      row having nothing focusable is correct: there is nothing to do here.
    * `granted` + `@registration_failed` — the browser said yes and Burrow
      failed to store the device (task 019ffe52). TWO variants, because the two
      ways to get here need opposite instructions. Neither has a button, for a
      close cousin of the reason above: the permission is already granted, so
      nothing this row could offer re-runs anything usefully.

  ## Inside Burrow Android (task 01a10d8e)

  `@native_platform == "android"` replaces BOTH the `prompt` and the `denied`
  rows with one row that carries the button. The browser premise behind the
  button-less `denied` row is false there: "denied" means the person tapped
  "Not now" on the app's explainer or denied Android's prompt, and the app can
  still ask. `enable_notifications` reaches the app's `enablePush`, which shows
  the explainer again; after one denial, Android's own prompt; and once Android
  will no longer prompt, the explainer's "Notifications are off for Burrow"
  variant, whose Open settings goes to Burrow's Android notification settings.
  So the button always does something, and the copy names no address bar the
  app does not have. Nothing re-asks on its own: the app reports "denied"
  after the first ask, so the hook never auto-calls `enablePush` again; this
  row's click is the only re-ask. iOS (`"ios"`) renders exactly as a browser
  did before.

  ## Why the failure carries a reason and not a boolean

  This shipped as one variant behind a boolean and Marlowe rejected it on review:

  > What does "suite cannot finish setting up" mean? If we are going to tell
  > the user something is broken, we need to tell them how to fix (whether they
  > need to do something, or we need to do something).

  The copy could not answer that, and the reason it could not is structural.
  One flag was being set by two failures whose answers are opposites:

    * `:no_participant` — the user's account is in no conversation, so there is
      no `chat_participants` row to key a subscription to. There is nothing the
      user can do. It resolves when somebody adds them to a conversation.
    * `:subscribe_failed` — `pushManager.subscribe` rejected in the browser
      after permission was granted. A browser or network failure, and a reload
      can genuinely change the outcome.

  No single sentence is true of both, so the copy went vague to cover them, and
  vague is exactly what got caught. The flag carries the reason now, and each
  variant names who has to act.

  ## The two sets of words

  `:no_participant`

  > Notifications are on, but you are not in any conversations yet.
  >
  > Start a conversation in Chat and they will switch on.

  It opens by confirming the thing the user did worked, because it did: every
  other variant in this row is about something they or their browser must
  change, and this one is not.

  The second line went through two wrong drafts before this one, and both
  errors are worth keeping written down.

  "Open any conversation and they will switch on" was wrong because nobody in
  this state HAS a conversation to open: a device registers against any
  participant row the user holds, so reaching this row means holding none.

  "Nothing to do. They start working as soon as someone adds you to one" was
  wrong for the opposite reason, and Marlowe caught it: everyone who can see this
  row can start a conversation themselves. `/inbox` lives in the
  `:authenticated` live_session behind `:require_app_surface`, while the
  `:external_chat` session on the `chat.` host exposes only `/chat` and
  `/chat/:space_slug`. No external user can reach this row, so the passive
  wording was protecting a population that never arrives, and it told staff to
  wait for something they could do themselves.

  "they will switch on" is a factual claim and it was verified before shipping
  rather than assumed. `push_subscribed` is sent from the `PushSubscribe`
  hook's `mounted()`, which re-runs on LiveView live navigation, so walking to
  Chat re-sends the existing subscription and `subscribe_for_user/2` files it
  against the participant row that now exists. Measured on a dev server: user
  in this state with 0 stored subscriptions, given a conversation, then an
  in-app navigation to Chat with no page load (a `window` marker survived the
  transition, which a reload would have wiped) left 1 stored subscription and
  the row gone. It switches on without a reload.

  `:subscribe_failed`

  > Your browser allowed notifications, but this device could not be registered.
  >
  > Reload the page to try again.

  Here the user CAN act, so it says so plainly. "Reload the page" is instruction
  text and not a control: a reload button would duplicate one the browser
  already gives them, which is a separate decision nobody has asked for.

  Neither variant promises persistence. `:push_registration_failed` lives on the
  socket and resets on reload, the same lifetime `:push_auto_denied` has. That
  is consistent with both lines: `:subscribe_failed` asks for the reload that
  clears it, and `:no_participant` describes a condition rather than a stored
  state.

  ## Why there is no "open browser settings" link

  Marlowe asked on review whether the row could send the user to their browser's
  settings. It cannot, on any browser. `chrome://settings/content/notifications`,
  `edge://settings/...`, `about:preferences#privacy` and Safari's preference
  panes are all privileged URLs: a web page may not navigate to them, link to
  them, or open them in a new tab, and the browsers drop the attempt silently
  rather than erroring. That is a deliberate defence (a page that could open
  your settings could walk you into changing them), so it is not a gap waiting
  on a future API. The row therefore does the only thing available to it:
  names the browser and gives the clicks, in `denied_instruction/1` below.

  ## Two ways to be blocked, and they need different words

  `denied` covers two situations that look identical on the wire:

    1. The user was asked and chose Block. Site settings are exactly the fix.
    2. The browser refused WITHOUT asking. Chrome does this in a private
       window, and any browser does it when notifications are switched off
       for every site. The user never saw a dialog, and pointing them at a
       site setting sends them to a screen where nothing is wrong.

  `@auto_denied` separates them. It is a flag beside `@push_permission`, never
  a sixth value of it: `granted` / `denied` / `prompt` / `unsupported` /
  `unknown` is a fixed vocabulary other code keys on by string, and widening it
  would break those readers silently. The flag is set by timing in the
  `PushSubscribe` hook (a human cannot choose Block in single-digit
  milliseconds); see `assets/js/hooks/push_subscribe.js` for the threshold and
  why detecting private browsing directly is the wrong tool.

  Both wrappers carry `role="status"` deliberately. They render server-side in
  the `unknown` state (nothing) and then flip a moment after connect when the
  hook pushes its first `push_permission_state`, so the row must announce on
  appearance rather than appearing silently.

  ## Colour

  `--color-warning` appears ONLY as the 3px left bar on the `denied` row, and
  `--color-error` never appears at all: notifications being off is a
  configuration state, and error has to stay reserved for real errors.

  That bar is decoration and carries no meaning on its own. The words carry the
  message and the `hero-bell-slash` glyph carries the shape, both at normal
  `--color-base-content` strength. This matters because `--color-warning` is
  roughly 1.9:1 against base-100 and would fail WCAG 1.4.11 (non-text contrast)
  if any meaning depended on seeing it. Nothing does. If someone later flags
  that contrast, darkening the token or moving the glyph to `text-warning` is
  NOT the fix — both would make the colour load-bearing, which is the thing
  this arrangement avoids.

  `prompt` gets no accent bar at all: mark the exception only, and an offer is
  not an exception.

  Semantic token slots throughout, no raw hex. No `hover:` / `group-hover:`
  variant gates the visibility of anything here — those compile inside
  `@media (hover: hover)`, which never matches on touch, so a control gated
  that way goes invisible rather than quiet (see the 2026-08-11 record around
  the `.channel-row-*` rules in `app.css`). Nothing here is hover-revealed.
  """
  def notification_state_row(assigns) do
    assigns = assign(assigns, :browser, browser_family(assigns[:user_agent]))

    ~H"""
    <div
      :if={@native_platform == "android" and @push_permission in ["prompt", "denied"]}
      class="mb-6 flex items-start gap-3 rounded-box border border-edge bg-base-200 p-3"
      role="status"
      data-role="notification-state"
      data-permission={@push_permission}
      data-native="android"
    >
      <.icon name="hero-bell-slash" class="mt-0.5 size-4 flex-shrink-0 text-base-content/70" />
      <div class="min-w-0 flex-1">
        <p class="text-sm">Notifications are off for Burrow on this phone.</p>
        <p class="mt-1 text-xs text-base-content/60">
          Turn them on to hear about mentions and approvals when Burrow is closed.
        </p>
      </div>
      <button
        type="button"
        phx-click="enable_notifications"
        class="btn btn-primary btn-sm flex-shrink-0"
        data-role="notification-enable"
      >
        Turn on notifications
      </button>
    </div>

    <div
      :if={@native_platform != "android" and @push_permission == "prompt"}
      class="mb-6 flex items-start gap-3 rounded-box border border-edge bg-base-200 p-3"
      role="status"
      data-role="notification-state"
      data-permission="prompt"
    >
      <.icon name="hero-bell" class="mt-0.5 size-4 flex-shrink-0 text-base-content/60" />
      <div class="min-w-0 flex-1">
        <p class="text-sm">Notifications are off for this browser.</p>
        <p class="mt-1 text-xs text-base-content/60">
          Turn them on to hear about mentions and replies when Burrow is not open.
        </p>
      </div>
      <button
        type="button"
        phx-click="enable_notifications"
        class="btn btn-primary btn-sm flex-shrink-0"
        data-role="notification-enable"
      >
        Turn on notifications
      </button>
    </div>

    <div
      :if={@native_platform != "android" and @push_permission == "denied"}
      class="mb-6 flex items-start gap-3 rounded-box border border-edge border-l-[3px] border-l-warning bg-base-200 p-3"
      role="status"
      data-role="notification-state"
      data-permission="denied"
      data-browser={Atom.to_string(@browser)}
      data-auto-denied={to_string(@auto_denied)}
    >
      <.icon name="hero-bell-slash" class="mt-0.5 size-4 flex-shrink-0 text-base-content/70" />
      <div :if={@auto_denied} class="min-w-0 flex-1">
        <p class="text-sm">Your browser turned notifications down without asking you.</p>
        <p class="mt-1 text-xs text-base-content/60">
          That usually means a private window, or notifications are switched off for every site.
        </p>
      </div>
      <div :if={not @auto_denied} class="min-w-0 flex-1">
        <p class="text-sm">Your browser is blocking notifications from Burrow.</p>
        <p class="mt-1 text-xs text-base-content/60">{denied_instruction(@browser)}</p>
        <p class="mt-1 text-xs text-base-content/60">
          If your computer is silencing the browser itself, no site setting will help.
        </p>
      </div>
    </div>

    <div
      :if={
        @push_permission == "granted" and @registration_failed in [:no_participant, :subscribe_failed]
      }
      class="mb-6 flex items-start gap-3 rounded-box border border-edge border-l-[3px] border-l-warning bg-base-200 p-3"
      role="status"
      data-role="notification-state"
      data-permission="granted"
      data-registration-failed={Atom.to_string(@registration_failed)}
    >
      <.icon name="hero-bell-alert" class="mt-0.5 size-4 flex-shrink-0 text-base-content/70" />
      <div :if={@registration_failed == :no_participant} class="min-w-0 flex-1">
        <p class="text-sm">Notifications are on, but you are not in any conversations yet.</p>
        <p class="mt-1 text-xs text-base-content/60">
          Start a conversation in Chat and they will switch on.
        </p>
      </div>
      <div :if={@registration_failed == :subscribe_failed} class="min-w-0 flex-1">
        <p class="text-sm">
          Your browser allowed notifications, but this device could not be registered.
        </p>
        <p class="mt-1 text-xs text-base-content/60">Reload the page to try again.</p>
      </div>
    </div>
    """
  end

  # The clicks that actually undo a site-level block, per browser. One line
  # each, and each names the browser: "your browser's site settings" is a
  # phrase most people cannot act on, which is the defect this replaces.
  #
  # The OS caveat is rendered separately, next to these, because it is the one
  # case none of these steps can fix.
  defp denied_instruction(:chrome),
    do:
      "In Chrome, click the icon at the left of the address bar, then Notifications, then Allow."

  defp denied_instruction(:edge),
    do: "In Edge, click the icon at the left of the address bar, then Notifications, then Allow."

  defp denied_instruction(:safari),
    do: "In Safari, open Settings, then Websites, then Notifications, and allow this site."

  defp denied_instruction(:firefox),
    do:
      "In Firefox, click the padlock in the address bar, then clear the notifications permission."

  # The default, and the right answer whenever we are not sure. A confidently
  # wrong set of clicks costs the reader more than a vague true sentence: they
  # follow it, find no such menu, and conclude the product is broken.
  defp denied_instruction(:other), do: "Allow them in your browser's site settings for this page."

  # Every browser lies in this header, so ORDER is the whole implementation:
  #
  #   * Edge ships "Chrome/126 … Edg/126"; Opera ships "Chrome/126 … OPR/112".
  #     Both must be decided before the Chrome clause or they read as Chrome.
  #   * Chrome ships "Safari/537.36", so Safari must be decided after Chrome.
  #   * On iOS every browser is WebKit wearing a badge (CriOS, FxiOS, EdgiOS),
  #     and the notification permission lives in the iOS Settings app rather
  #     than in any in-browser menu, so none of our instructions apply and
  #     these fall through to the generic line on purpose.
  #
  # Opera is Chromium but its address-bar affordance does not match the
  # wording above, so it takes the generic line rather than a near-miss.
  defp browser_family(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, ["CriOS", "FxiOS", "EdgiOS"]) -> :other
      String.contains?(ua, "Edg/") -> :edge
      String.contains?(ua, "OPR/") -> :other
      String.contains?(ua, "Firefox/") -> :firefox
      String.contains?(ua, ["Chrome/", "Chromium/"]) -> :chrome
      String.contains?(ua, ["iPhone", "iPad"]) -> :other
      String.contains?(ua, "Safari/") -> :safari
      true -> :other
    end
  end

  defp browser_family(_), do: :other
end
