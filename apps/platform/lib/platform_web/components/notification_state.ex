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
  `/settings` route, and the rail's bottom gear is Admin (`fabrikam_only?: true`,
  gated on `is_fabrikam_user`), so external and non-admin internal users would
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
      granted      nothing. The healthy case adds nothing to the page.
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

  @doc """
  Notification-state row for `/inbox`.

  Two renderings, and the difference between them is the whole point:

    * `prompt` — an offer, carrying the one action that works. The button
      fires `enable_notifications`, handled by `ShellLive`'s `:push_events`
      attach, which pushes `request_push_permission` to the `PushSubscribe`
      hook.
    * `denied` — a statement of fact with NO button. No web API can re-prompt
      after a browser-level block, and no page can open browser settings, so
      any button here would silently do nothing every time it was pressed.
      Never add one; the instruction line is the only thing that works. The
      row having nothing focusable is correct: there is nothing to do here.

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
      :if={@push_permission == "prompt"}
      class="mb-6 flex items-start gap-3 rounded-box border border-base-300 bg-base-200 p-3"
      role="status"
      data-role="notification-state"
      data-permission="prompt"
    >
      <.icon name="hero-bell" class="mt-0.5 size-4 flex-shrink-0 text-base-content/60" />
      <div class="min-w-0 flex-1">
        <p class="text-sm">Notifications are off for this browser.</p>
        <p class="mt-1 text-xs text-base-content/60">
          Turn them on to hear about mentions and replies when Suite is not open.
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
      :if={@push_permission == "denied"}
      class="mb-6 flex items-start gap-3 rounded-box border border-base-300 border-l-[3px] border-l-warning bg-base-200 p-3"
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
        <p class="text-sm">Your browser is blocking notifications from Suite.</p>
        <p class="mt-1 text-xs text-base-content/60">{denied_instruction(@browser)}</p>
        <p class="mt-1 text-xs text-base-content/60">
          If your computer is silencing the browser itself, no site setting will help.
        </p>
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
