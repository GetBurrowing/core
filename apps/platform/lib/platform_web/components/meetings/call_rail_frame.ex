defmodule PlatformWeb.Components.Meetings.CallRailFrame do
  @moduledoc """
  The FRAME around `/meetings`' call rail: an in-flow column at `lg`, a
  bottom sheet below it (task 01a07410 / FE-17 stage 3).

  ## Why a frame and not a second rail

  The rail is ONE DOM node holding a nested chat `live_render`, the
  `MeetingTranscript` hook and the candidate buttons, and every one of
  those is mount-once: a second copy puts two `#meeting-call-rail`s in
  the document (`meeting_live_test.exs` pins the chat mount count at
  exactly 1), and moving the node between parents on every sheet switch
  destroys the child LiveView and the transcript's scrollback. So the
  three mobile surfaces the ticket names — cards, chat, invite — are three
  STATES of one `PlatformWeb.Components.Sheet` instance (`data-sheet`),
  not three sheets each holding a copy of the surface.

  The rail markup is this component's `:inner_block`, rendered in exactly
  ONE of the two branches below. The slot body lives once in
  `meeting_live.html.heex` and stays change-tracked against the
  LiveView's own assigns, which a component that took the whole assigns
  map as one attr would lose.

  ## Which branch renders is a SERVER decision

  `mobile?` comes from the `ViewportBreakpoint` hook, which reports which
  side of Tailwind's `lg` (1024px) the viewport is on at mount and on
  every crossing. Until it reports, the in-flow branch renders — that is
  the desktop layout, byte-for-byte what shipped, and at `<lg` it is
  `hidden`. A phone therefore mounts the rail hidden, receives the
  report, and re-renders it inside the sheet: one child-LiveView remount
  at page load, never one per tab switch.

  The alternative — both wrappers always in the document, gated by CSS —
  is not available here: the sheet is `role="dialog" aria-modal="true"`,
  and a modal dialog that is in the accessibility tree at desktop tells
  a screen reader the whole page behind it is inert. `lg:hidden` is still
  on the sheet root as belt-and-braces (the same width gate every other
  bottom sheet in this codebase carries), but the load-bearing gate is
  the `:if`.

  ## The handle IS the countdown, only while shut

  On a phone the 30-second candidate window is only visible on the SHUT
  sheet, so the sheet's grab bar carries stage 2's `:soonest_candidate`:
  a depleting `info` track that steps to `warning` inside
  `Countdown.warning_seconds/0`, a JetBrains Mono numeral, and a short
  label. The bar is the glance; the numeral is the answer. When the
  sheet is OPEN the handle reverts to the plain grabber — the cards
  inside carry their own drains, and a second countdown above them would
  be a second thing to disagree.

  The handle row is `role="status"` with an accessible name that STATES
  THE DEADLINE IN WORDS ("12 seconds until a task is created"), which
  `candidate_clock.js` refreshes as it counts from `data-label-template`.
  The visual children are `aria-hidden`: a live region that re-announced
  a changing digit every second would be hostile, and the name is what
  a screen-reader user reads when they land on it.

  ## Who ticks the handle

  Stage 2 widened the rail's `CandidateClock` query to reach this node.
  That hook is mounted on `[data-role="meeting-candidate-countdown-rail"]`
  (`candidate_rail.ex`), which renders ONLY inside the Canvas branch of
  `call_rail/1`'s tab `case` — on People, Chat or Transcript there is no
  rail ticker at all, and a shut sheet would freeze at its
  server-rendered number, the exact lying-window defect this ticket
  exists to fix. So the handle mounts `SheetHandleClock`, the same
  `_paint` against the same server `acts_at`. When both hooks are live
  they paint the same node from the same deadline; neither starts a
  client-side clock.
  """

  use Phoenix.Component

  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Platform.Meetings.Countdown
  alias PlatformWeb.Components.Meetings.CallShell
  alias PlatformWeb.Components.Meetings.CandidateDisplay

  @sheet_id "meeting-rail-sheet"

  @doc "The one sheet's DOM id. Its handle row is `#{@sheet_id}-handle`."
  def sheet_id, do: @sheet_id

  @doc """
  The sheet state a rail tab maps to.

  The ticket names cards, chat and invite; the rail also serves a
  Transcript tab, which is its own state rather than being folded into
  one of the three. People carries the invite section, so `"people"` is
  the invite sheet.
  """
  @spec sheet_for_tab(String.t()) :: String.t()
  def sheet_for_tab(tab) do
    case CallShell.normalize_tab(tab) do
      "canvas" -> "cards"
      "chat" -> "chat"
      "people" -> "invite"
      "transcript" -> "transcript"
    end
  end

  @doc """
  The rail tab a sheet state opens on. Inverse of `sheet_for_tab/1`;
  anything unknown lands on People, as every other tab coercion here does.
  """
  @spec tab_for_sheet(term()) :: String.t()
  def tab_for_sheet("cards"), do: "canvas"
  def tab_for_sheet("chat"), do: "chat"
  def tab_for_sheet("invite"), do: "people"
  def tab_for_sheet("transcript"), do: "transcript"
  def tab_for_sheet(_sheet), do: "people"

  @doc "The sheet's visible title for a rail tab."
  @spec sheet_title(String.t()) :: String.t()
  def sheet_title(tab) do
    case sheet_for_tab(tab) do
      "cards" -> "Cards"
      "chat" -> "Chat"
      "invite" -> "People and invites"
      "transcript" -> "Transcript"
    end
  end

  @doc """
  The handle's accessible name, in words. `%{n}`/`%{s}` are the
  placeholders `candidate_clock.js` substitutes on every tick, so the
  server-rendered name and the client-refreshed one come from ONE string.
  """
  @spec label_template(map()) :: String.t()
  def label_template(candidate) do
    case CandidateDisplay.armed_outcome_label(candidate) do
      nil -> "%{n} second%{s} until the soonest card acts"
      noun -> "%{n} second%{s} until a #{noun} is created"
    end
  end

  @doc "`label_template/1` with the placeholders filled for `remaining` seconds."
  @spec accessible_name(map(), integer()) :: String.t()
  def accessible_name(candidate, remaining) when is_integer(remaining) do
    candidate
    |> label_template()
    |> String.replace("%{n}", Integer.to_string(remaining))
    |> String.replace("%{s}", if(remaining == 1, do: "", else: "s"))
  end

  attr(:mobile?, :boolean, required: true, doc: "below `lg`, per the ViewportBreakpoint hook")
  attr(:open, :boolean, required: true, doc: "the `<lg` sheet is open (`:call_rail_open`)")

  attr(:collapsed, :boolean,
    required: true,
    doc: "the desktop collapse (`:chat_panel_collapsed`)"
  )

  attr(:animate, :boolean, required: true, doc: "`:call_rail_animate`")
  attr(:active_tab, :string, required: true)

  attr(:soonest_candidate, :any,
    default: nil,
    doc: "stage 2's `:soonest_candidate`; nil renders a plain grabber"
  )

  attr(:now, :any, default: nil, doc: "DateTime for the server-rendered remaining seconds")

  slot(:inner_block, required: true, doc: "the rail's contents, rendered exactly once")

  def rail_frame(assigns) do
    assigns =
      assigns
      |> assign(:sheet_id, @sheet_id)
      |> assign(:handle_label, handle_label(assigns.soonest_candidate, assigns.open, assigns.now))
      |> assign(:sheet_class, sheet_class(assigns.soonest_candidate))

    ~H"""
    <%!-- IN-FLOW BRANCH: the desktop column, `hidden` below `lg`. The
         class list is 01a084bf stage 2's one-node fold minus the
         right-drawer geometry it carried below `lg`, which is retired by
         FE-17 stage 3 in favour of the sheet below. Everything `lg:`-
         prefixed is unchanged. --%>
    <div
      :if={not @mobile?}
      id="meeting-call-rail-pane"
      class={
        [
          "hidden flex-col lg:flex lg:flex-shrink-0 lg:overflow-hidden",
          # THE ANIMATED QUANTITY. `lg:` only. `prefers-reduced-motion:
          # reduce` drops the transition: a reader who asked for no motion
          # gets the collapse as an instant state change.
          #
          # MOTION ASYMMETRY (task 01a0740d): present ONLY when the viewer
          # moved the rail themselves — `:call_rail_animate` is `false` at
          # both mounts and on every mode-driven reassert, so switching to
          # screen share SNAPS the width instead of sliding a slab of the
          # screen at someone whose attention is already committed.
          if(@animate,
            do: "lg:transition-[width] lg:duration-200 lg:ease-out motion-reduce:transition-none"
          ),
          if(@collapsed, do: "lg:w-11", else: "lg:w-[312px]")
        ]
      }
      data-pane="call-rail"
      data-collapsed={to_string(@collapsed)}
      data-call-rail-open={to_string(@open)}
      data-rail-frame="column"
    >
      {render_slot(@inner_block)}
    </div>

    <%!-- SHEET BRANCH. One `PlatformWeb.Components.Sheet`, `placement:
         :bottom`, `lg:hidden` like the twelve call sites before it, and
         `:if`-gated on the viewport report (see the moduledoc for why
         CSS alone cannot gate a modal dialog). `sheet-peek` keeps the
         SHUT sheet's handle row on screen while a countdown runs —
         without it `.sheet` is `visibility: hidden` when closed and the
         handle would be a countdown nobody can see. --%>
    <.sheet
      :if={@mobile?}
      id={@sheet_id}
      open={@open}
      placement={:bottom}
      on_close="close_call_rail"
      class={@sheet_class}
      handle_label={@handle_label}
      data-sheet={sheet_for_tab(@active_tab)}
    >
      <:handle :if={@soonest_candidate && not @open}>
        <.sheet_handle_countdown
          candidate={@soonest_candidate}
          now={@now}
          label_target={"#{@sheet_id}-handle"}
        />
      </:handle>
      <:title>{sheet_title(@active_tab)}</:title>
      <%!-- Bleeds the sheet body's 1.5rem padding: the rail brings its own
           chrome and a padded inset around a tab strip reads as a card
           inside a card. `h-[60dvh]` gives the rail a definite height so
           its own `min-h-0 flex-1` pane can scroll; the sheet panel is
           capped at 90vh by its own CSS and grows to fit this. --%>
      <div
        id="meeting-call-rail-pane"
        class="-m-6 flex h-[60dvh] flex-col"
        data-pane="call-rail"
        data-collapsed={to_string(@collapsed)}
        data-call-rail-open={to_string(@open)}
        data-rail-frame="sheet"
      >
        {render_slot(@inner_block)}
      </div>
    </.sheet>
    """
  end

  # `lg:hidden` on every call site is the codebase's width gate for a bottom
  # sheet; `sheet-peek` is only earned while a countdown is running, so a
  # shut sheet with nothing to say is fully hidden like any other.
  defp sheet_class(nil), do: "lg:hidden"
  defp sheet_class(_candidate), do: "lg:hidden sheet-peek"

  # `handle_label` is the status row's accessible name at RENDER time; the
  # hook refreshes it from the same template afterwards. Computed here so
  # the `<.sheet>` call above can pass a plain string, and `nil` when there
  # is no handle so the bare grab bar stays `aria-hidden`.
  defp handle_label(nil, _open, _now), do: nil
  defp handle_label(_candidate, true, _now), do: nil

  defp handle_label(candidate, false, now) do
    accessible_name(candidate, remaining(candidate, now))
  end

  defp remaining(candidate, now) do
    Countdown.remaining_seconds(candidate.acts_at, now || DateTime.utc_now()) || 0
  end

  defp warning?(remaining), do: remaining <= Countdown.warning_seconds()

  # Same arithmetic as `CandidateRail.drain_width/1` and the hook's
  # `_paint`: full width at t=total, nothing at t=0.
  defp drain_width(remaining) do
    total = Countdown.countdown_seconds()
    Float.round(min(remaining / total, 1.0) * 100, 2)
  end

  attr(:candidate, :map, required: true)
  attr(:now, :any, default: nil)
  attr(:label_target, :string, required: true, doc: "id of the `role=status` row to name")

  @doc """
  The handle's countdown: label, track, numeral. Renders INSIDE the
  sheet's `:handle` slot, so the `role="status"` row around it belongs to
  `Sheet`; this is the row's content and its heartbeat.

  The whole thing is a button that opens the cards sheet — the handle is
  under the thumb and it is what a person taps to see the cards the
  countdown is about. Its visual children are `aria-hidden`; the status
  row's name carries the deadline in words and the button's own name
  says what tapping does.

  `data-role="meeting-sheet-handle-countdown"` plus the same `data-*`
  contract as a card foot is what `candidate_clock.js` paints; the
  child roles are the CARD's roles on purpose, so one `_paint` serves
  both and the handle cannot show a number the card would not.
  """
  def sheet_handle_countdown(assigns) do
    remaining = remaining(assigns.candidate, assigns.now)

    assigns =
      assigns
      |> assign(:remaining, remaining)
      |> assign(:warning?, warning?(remaining))
      |> assign(:drain_width, drain_width(remaining))
      |> assign(:outcome_noun, CandidateDisplay.armed_outcome_label(assigns.candidate))

    ~H"""
    <button
      type="button"
      id="meeting-sheet-handle-countdown"
      phx-hook="SheetHandleClock"
      phx-click="open_mobile_sheet"
      phx-value-sheet="cards"
      class="sheet-handle__countdown"
      aria-label="Open the cards"
      data-role="meeting-sheet-handle-countdown"
      data-candidate-id={@candidate.id}
      data-acts-at={DateTime.to_iso8601(@candidate.acts_at)}
      data-total-seconds={Countdown.countdown_seconds()}
      data-warning-seconds={Countdown.warning_seconds()}
      data-label-target={@label_target}
      data-label-template={label_template(@candidate)}
    >
      <span class="sheet-handle__label" aria-hidden="true">
        <%= if @outcome_noun do %>
          Creating a {@outcome_noun} in
        <% else %>
          Next card in
        <% end %>
      </span>
      <span class="sheet-handle__track" aria-hidden="true">
        <span
          class={["sheet-handle__fill", @warning? && "candidate-drain--warning"]}
          data-role="meeting-candidate-drain"
          style={"width: #{@drain_width}%"}
        >
        </span>
      </span>
      <time
        class={["sheet-handle__numeral", @warning? && "candidate-count--warning"]}
        datetime={DateTime.to_iso8601(@candidate.acts_at)}
        data-role="meeting-candidate-remaining"
        data-remaining={@remaining}
        aria-hidden="true"
      >
        {@remaining}
      </time>
    </button>
    """
  end
end
