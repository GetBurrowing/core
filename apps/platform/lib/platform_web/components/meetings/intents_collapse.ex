defmodule PlatformWeb.Components.Meetings.IntentsCollapse do
  @moduledoc """
  The `.intents-collapse` bar — the meeting-producer's live-tuning
  surface over a meeting's intent queue (task 019f70b8 stage 7).

  Renders as a strip above the embedded chat pane inside the meeting's
  right rail. One row per intent in `Platform.Meetings.IntentQueue`,
  live-updated off `meeting:<meeting_id>:intents`.

  ## Two hooks, on purpose

  Every element carries BOTH the mockup's class name
  (`intents-collapse`, greppable against the design canvas) and a
  `data-role` attribute. DOM assertions key on `data-role`, never on the
  class — a Tailwind reshuffle must not be able to break a test.

  ## Status chips (design stage 1, Saru)

  All nine statuses render through Suite's `<.chip tone>` — not raw
  daisyUI `badge-*` — so the bar stays on the approved soft-tint re-skin
  formula. Every chip pairs a hero-icon glyph with a JetBrains-Mono
  label: **colour is never the only signal**, so the bar reads for
  colourblind operators.

  The error split is semantic, not decorative:

    * `:timed_out` is **amber** — we waited and got nothing back.
    * `:dispatch_failed` / `:no_ack_spawn_failed` are **red** —
      something is broken (no runtime / the runtime could not spawn).

  Those are three different operator actions, so they stay three
  different chips all the way out to the DOM. Stage 6 carried the same
  split into the corrections corpus's `dispatch_outcome` enum; a UI that
  collapsed them would be lying about a distinction the corpus records.

  ## Controls are status-aware, not decorative

  The mock draws an X and a pencil on every row. They are not the same
  affordance on every row:

  | status                                | X                     | pencil            |
  |---------------------------------------|-----------------------|-------------------|
  | `:queued`                             | remove (local delete) | re-target         |
  | `:dispatched` / `:acked`              | cancel in flight (confirm) | correct + cancel (confirm) |
  | `:completed` / `:cancelled` / `:cancelled_late` | — (read-only history) | —      |
  | `:timed_out`                          | dismiss               | —                 |
  | `:dispatch_failed` / `:no_ack_spawn_failed` | dismiss         | re-target         |

  Retroactively relabelling a `:completed` intent is out of scope, so
  completed rows carry no controls at all rather than controls that
  quietly no-op.

  Buttons are **persistent, never hover-revealed** — mobile has no
  hover — and every one of them is a ≥44px tap target (`min-h-11
  min-w-11`), which is where the mock's `btn-xs` (~24px) row icons fell
  short. Rows are two-line at EVERY viewport, because this rail is
  ~320px wide on desktop and on mobile alike — a target pill, a
  confidence readout, a status chip and two 44px buttons do not fit on
  one line in 320px, and a `sm:` breakpoint would only describe the
  viewport, not the container.

  ## The collapsed summary protects the severity fragment

  The resting (collapsed) state exists to answer one question without
  expanding: *is anything wrong?* So the severity fragment is the LAST
  thing allowed to truncate. Two mechanisms, together:

    * **Severity-first copy** — `3 need attention · 10 intents`, so a
      truncation eats the benign tail rather than the signal. The first
      draft read `10 intents · 3 need attention` and clipped to
      `10 intents · 3 need…` in a 320px rail, which is the one case the
      state is built for.
    * **Structural** — the severity fragment renders in its own
      `shrink-0 whitespace-nowrap` span and the count tail in a
      `min-w-0 truncate` sibling, with the `Producer` chip allowed to
      yield. Copy order alone would not survive someone re-wording it.

  The zero-attention case (`10 intents` on its own) may truncate freely:
  there is no severity fragment to protect.

  ## Low confidence is emphasised, and never by colour alone

  A producer deciding whether to trust a dispatch is exactly the person
  who needs `0.55` not to look like `0.96`. Below `0.70` the readout
  takes warning tone, gains a `~` prefix on the mono value, and carries
  an aria-label saying "low confidence". The `~` is what keeps the
  treatment off colour alone — the same rule the status chips follow.

  The threshold is view-level because `IntentClassifier` does not expose
  one; the classifier reports a float and nothing acts on it. Unifying
  the two is tracked in follow-up task
  `019f9c6f-ecb7-74e6-87f1-5d624e66020b`.

  ## Pending cancel — the state the mock predates

  `IntentQueue.cancel/3` does NOT flip an in-flight row to `:cancelled`
  at signal time; the row moves only when the target answers with
  `intent_ack(:cancel_honored)` (or the ack window expires). So between
  the click and the answer the honest state is "still with a runtime,
  cancel requested" — rendered as a `Cancelling` chip alongside the
  live status chip, with the row's controls disabled so a double-tap
  cannot double-fire. `MeetingLive` owns the pending set; this module
  only renders it.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [chip: 1]

  alias Platform.Meetings.IntentCorrection

  # status -> {chip tone, heroicon CLASS, mono label, reading group, hint}
  #
  # Ordered as the bar reads top-to-bottom: in-flight (neutral -> info),
  # success (green), cancelled (muted), then the amber/red error split.
  #
  # No two statuses share a glyph OR a label. Saru's direction draws
  # `:cancelled_late` as "x-circle + !"; rendered as its own
  # `hero-exclamation-circle` glyph so the distinction survives being
  # read at 12px on a phone, where a superscript bang would not.
  #
  # The icon column holds the COMPLETE `hero-*` class, not a suffix to
  # interpolate. Tailwind v4 scans these files as plain text (`@source
  # "../../lib/platform_web"` in app.css), so a class assembled at render
  # time as `"hero-" <> suffix` is invisible to the scanner and its rule
  # never reaches the bundle. The failure is silent and partial: chips
  # whose glyph happens to be written out literally elsewhere in the
  # codebase render fine, and the rest ship an empty box. Caught in
  # review on `hero-bug-ant` and `hero-queue-list`, which nothing else
  # uses. Keeping the whole literal here is what makes it findable.
  @status_presentation %{
    queued:
      {"neutral", "hero-queue-list", "Queued", :in_flight, "Waiting for the dispatch cursor."},
    dispatched:
      {"info", "hero-paper-airplane", "Sent", :in_flight, "With a runtime, waiting for an ack."},
    acked: {"info", "hero-bolt", "Working", :in_flight, "A subagent picked this up."},
    completed:
      {"success", "hero-check-circle", "Done", :success, "The subagent reported completion."},
    cancelled: {"neutral", "hero-x-circle", "Cancelled", :cancelled, "Pulled by the producer."},
    cancelled_late:
      {"neutral", "hero-exclamation-circle", "Cancelled late", :cancelled,
       "The work finished before the cancel landed."},
    timed_out: {"warning", "hero-clock", "Timed out", :error, "No ack of any kind arrived."},
    dispatch_failed:
      {"error", "hero-exclamation-triangle", "No runtime", :error,
       "The target agent has no runtime to reach."},
    no_ack_spawn_failed:
      {"error", "hero-bug-ant", "Spawn failed", :error,
       "The runtime answered but could not spawn a subagent."}
  }

  # Below this, a confidence readout is emphasised as low.
  #
  # VIEW-LEVEL on purpose, and only because there is nowhere better yet:
  # `Platform.Meetings.IntentClassifier` parses a `confidence` float out
  # of the model's JSON and carries it to the queue, but never compares
  # it to anything — there is no classifier-side threshold to reuse.
  # Unifying the two (so the classifier can also gate or re-ask on a
  # low-confidence read, and the bar can render whatever it decides) is
  # tracked in follow-up task `019f9c6f-ecb7-74e6-87f1-5d624e66020b`.
  #
  # 0.70 rather than 0.50: the useful question is not "did the model
  # guess?" but "should the producer look before trusting the dispatch?",
  # and the answer to that starts well above a coin flip.
  @low_confidence_threshold 0.70

  # Statuses whose X removes the row without reaching a runtime.
  @locally_removable [:queued, :timed_out, :dispatch_failed, :no_ack_spawn_failed]

  # Statuses whose X has to signal a live runtime, so it confirms first.
  @cancellable_in_flight [:dispatched, :acked]

  # Statuses the pencil can re-target. `:timed_out` is excluded on
  # purpose: nobody answered, so there is no evidence the classifier was
  # wrong about the target — only that the target was silent.
  @correctable [:queued, :dispatched, :acked, :dispatch_failed, :no_ack_spawn_failed]

  @doc "Every status the bar knows how to render, in reading order."
  @spec statuses() :: [atom()]
  def statuses, do: Map.keys(@status_presentation)

  @doc """
  `<.chip>` tone for `status`.

  `:timed_out` is `"warning"` and the two hard failures are `"error"` —
  see the moduledoc for why that split is load-bearing.
  """
  @spec status_tone(atom() | binary()) :: String.t()
  def status_tone(status), do: status |> presentation() |> elem(0)

  @doc "Complete hero-icon class for `status` (the glyph half of the chip)."
  @spec status_icon(atom() | binary()) :: String.t()
  def status_icon(status), do: status |> presentation() |> elem(1)

  @doc "Human label for `status`, rendered in JetBrains Mono."
  @spec status_label(atom() | binary()) :: String.t()
  def status_label(status), do: status |> presentation() |> elem(2)

  @doc "Reading group for `status` — `:in_flight | :success | :cancelled | :error`."
  @spec status_group(atom() | binary()) :: atom()
  def status_group(status), do: status |> presentation() |> elem(3)

  @doc """
  One-sentence explanation of `status`, rendered as the chip's tooltip.

  `:cancelled_late` earns this most — "the work finished before the
  cancel landed" is a race, not a misclassification, and a producer who
  reads it as one will keep correcting a classifier that was right.
  """
  @spec status_hint(atom() | binary()) :: String.t()
  def status_hint(status), do: status |> presentation() |> elem(4)

  @doc "True when the row's X is offered at all."
  @spec removable?(atom() | binary()) :: boolean()
  def removable?(status) do
    normalize(status) in (@locally_removable ++ @cancellable_in_flight)
  end

  @doc "True when the row's pencil is offered at all."
  @spec correctable?(atom() | binary()) :: boolean()
  def correctable?(status), do: normalize(status) in @correctable

  @doc """
  True when acting on the row has to confirm first — i.e. the intent is
  with a runtime right now and the action interrupts running work.
  """
  @spec confirm_required?(atom() | binary()) :: boolean()
  def confirm_required?(status), do: normalize(status) in @cancellable_in_flight

  @doc """
  The `dispatch_outcome` to stamp on a correction written about a row in
  `status`.

  `nil` for `:queued` — a row the producer pulled before it ever left
  the queue has no dispatch outcome, and inventing one would poison the
  corpus with a dispatch that never happened.
  """
  @spec dispatch_outcome(atom() | binary()) :: atom() | nil
  def dispatch_outcome(status) do
    normalized = normalize(status)
    if normalized in IntentCorrection.dispatch_outcomes(), do: normalized
  end

  @doc """
  Collapsed-header summary, split into the fragment that must survive
  truncation and the one that may be eaten.

  `%{severity: nil | String.t(), tail: String.t()}`. `:severity` is the
  answer to "is anything wrong?" — the only reason the resting state
  exists — so it is rendered `shrink-0` and written FIRST. `:tail`
  carries the total count (and its leading separator, when there is a
  severity fragment to separate it from) and is free to truncate.

  `:severity` is `nil` when nothing needs attention; there is then no
  signal to protect and the tail may truncate freely.
  """
  @spec summary_parts([map()]) :: %{severity: String.t() | nil, tail: String.t()}
  def summary_parts([]), do: %{severity: nil, tail: "No intents yet"}

  def summary_parts(intents) when is_list(intents) do
    total = length(intents)
    attention = Enum.count(intents, &(status_group(&1.status) == :error))
    noun = if total == 1, do: "intent", else: "intents"
    verb = if attention == 1, do: "needs", else: "need"

    case attention do
      0 -> %{severity: nil, tail: "#{total} #{noun}"}
      n -> %{severity: "#{n} #{verb} attention", tail: "· #{total} #{noun}"}
    end
  end

  @doc """
  The collapsed-header summary as one string — severity fragment first.

  This is what a tooltip and an accessible name want; the rendered
  header splits the same text across two spans so the tail truncates
  before the severity fragment does. See `summary_parts/1`.
  """
  @spec summary([map()]) :: String.t()
  def summary(intents) when is_list(intents) do
    case summary_parts(intents) do
      %{severity: nil, tail: tail} -> tail
      %{severity: severity, tail: tail} -> "#{severity} #{tail}"
    end
  end

  defp presentation(status) do
    Map.get(@status_presentation, normalize(status), @status_presentation.queued)
  end

  defp normalize(status) when is_atom(status), do: status

  defp normalize(status) when is_binary(status) do
    Enum.find(Map.keys(@status_presentation), &(Atom.to_string(&1) == status)) || :queued
  end

  defp normalize(_), do: :queued

  # ── Components ─────────────────────────────────────────────────────────────

  @doc """
  The intents-collapse strip.

  Caller is responsible for the role gate — this component renders
  whenever it is called, and `MeetingLive` wraps it in the
  `meeting_producer` `:if` so an unassigned role leaves NOTHING in the
  DOM rather than something hidden with CSS.
  """
  attr(:intents, :list, required: true)
  attr(:open, :boolean, default: true)
  attr(:expanded, :boolean, default: false)
  attr(:pending_cancels, :any, default: nil)
  attr(:reason_picker_id, :string, default: nil)
  attr(:error, :string, default: nil)

  def intents_collapse(assigns) do
    assigns =
      assigns
      |> assign_new(:pending_cancels, fn -> MapSet.new() end)
      |> assign(:summary, summary(assigns.intents))
      |> assign(:summary_parts, summary_parts(assigns.intents))

    ~H"""
    <section
      class="intents-collapse flex flex-shrink-0 flex-col border-b border-base-300 bg-base-100"
      data-role="intents-collapse"
      data-intent-count={length(@intents)}
    >
      <header
        class="intents-collapse__header flex items-center gap-1 border-b border-base-300 bg-base-200/40 pr-1 pl-1"
        data-role="intents-collapse-header"
      >
        <button
          type="button"
          phx-click="toggle_intents_collapse"
          aria-expanded={to_string(@open)}
          aria-controls="intents-collapse-body"
          title={if @open, do: "Collapse intents", else: "Expand intents"}
          class="flex min-h-11 min-w-0 flex-1 items-center gap-2 rounded-lg px-2 text-left hover:bg-base-300/40 focus-visible-ring"
          data-role="intents-collapse-toggle"
        >
          <span class="hero-bolt size-4 flex-shrink-0 text-primary" aria-hidden="true"></span>
          <span class="flex min-w-0 flex-1 flex-col">
            <span class="truncate text-sm leading-tight font-semibold text-base-content">
              Intents
            </span>
            <%!-- The severity fragment is the LAST thing allowed to truncate.

               Two spans, not one string, because copy order alone is a
               convention and this is a constraint: `· 10 intents` is
               `min-w-0 truncate` and gives up its width first, while
               `3 need attention` is `shrink-0 whitespace-nowrap` and
               keeps its own. Re-wording the copy cannot break that.
               When nothing needs attention there is no severity span at
               all and the tail truncates freely. --%>
            <span
              class="flex min-w-0 items-baseline gap-1 overflow-hidden font-mono text-[10px] leading-tight text-base-content/60"
              data-role="intents-summary"
              title={@summary}
            >
              <span
                :if={@summary_parts.severity}
                class="shrink-0 whitespace-nowrap"
                data-role="intents-summary-severity"
              >
                {@summary_parts.severity}
              </span>
              <span class="min-w-0 truncate" data-role="intents-summary-tail">
                {@summary_parts.tail}
              </span>
            </span>
          </span>
          <span
            class={[
              "size-4 flex-shrink-0 text-base-content/50",
              if(@open, do: "hero-chevron-up", else: "hero-chevron-down")
            ]}
            aria-hidden="true"
          >
          </span>
        </button>

        <%!-- Why the privileged viewer alone sees this rail.

           Allowed to SHRINK, unlike everything else in this header: it
           labels a permission that never changes, so in a squeeze it is
           the cheapest thing on the row to give up. The summary's
           severity fragment is the expensive one. --%>
        <.chip tone="primary" class="min-w-0 shrink truncate font-mono text-[10px]">
          Producer
        </.chip>

        <button
          type="button"
          phx-click="toggle_intents_expanded"
          aria-label="Open the full intent table"
          aria-expanded={to_string(@expanded)}
          title="Full intent table"
          class="btn btn-ghost btn-square min-h-11 min-w-11 text-base-content/60 hover:text-base-content"
          data-role="intents-expand-toggle"
        >
          <span class="hero-arrow-top-right-on-square size-4" aria-hidden="true"></span>
        </button>
      </header>

      <div
        :if={@open}
        id="intents-collapse-body"
        class="intents-collapse__body max-h-96 overflow-y-auto"
        data-role="intents-collapse-body"
      >
        <p
          :if={@error}
          class="border-b border-base-300 bg-error/10 px-3 py-2 text-xs text-error"
          data-role="intents-error"
        >
          {@error}
        </p>

        <p
          :if={@intents == []}
          class="px-3 py-3 font-mono text-xs text-base-content/50"
          data-role="intents-empty"
        >
          Listening for intents…
        </p>

        <ul :if={@intents != []} class="flex flex-col" role="list" data-role="intents-list">
          <.intent_row
            :for={intent <- @intents}
            intent={intent}
            pending_cancel={MapSet.member?(@pending_cancels, intent.id)}
            reason_picker_open={@reason_picker_id == intent.id}
          />
        </ul>
      </div>
    </section>
    """
  end

  @doc """
  The strip's two full-screen overlays — the expanded table and the
  correction modal.

  Rendered SEPARATELY from `intents_collapse/1`, at the LiveView root,
  and this is not a stylistic split. The chat rail these overlays belong
  to carries `transition-transform` + `translate-x-0` so it can slide in
  as a mobile drawer, and a transformed ancestor becomes the containing
  block for `position: fixed` descendants. An overlay rendered inside
  the strip is therefore centred on a 320px rail rather than on the
  viewport — which is exactly what "large, centered modal, not a mobile
  bottom-sheet on desktop" is not.
  """
  attr(:intents, :list, required: true)
  attr(:expanded, :boolean, default: false)
  attr(:edit_row, :map, default: nil)
  attr(:agent_options, :list, default: [])

  def intents_overlays(assigns) do
    ~H"""
    <.intent_expanded_table :if={@expanded} intents={@intents} />
    <.intent_edit_modal :if={@edit_row} row={@edit_row} agent_options={@agent_options} />
    """
  end

  attr(:intent, :map, required: true)
  attr(:pending_cancel, :boolean, default: false)
  attr(:reason_picker_open, :boolean, default: false)

  defp intent_row(assigns) do
    ~H"""
    <%!-- ALWAYS two-line, at every viewport.

       The design direction calls for a two-line row "below `sm`", but a
       viewport breakpoint is the wrong instrument here: this rail is
       `lg:w-80` on desktop and `w-80 max-w-[85vw]` as a mobile drawer —
       ~320px in BOTH cases. A `sm:flex-row` would therefore switch a
       320px container to a one-line layout on a 1440px desktop, which
       is the widest viewport and the worst rendering: intent labels
       truncate to a couple of characters. Two lines everywhere. --%>
    <li
      class="intents-collapse__row flex min-h-11 flex-col gap-1 border-b border-base-300/60 px-2 py-1.5 last:border-b-0"
      data-role="intent-row"
      data-intent-id={@intent.id}
      data-intent-status={@intent.status}
      data-intent-group={status_group(@intent.status)}
      data-pending-cancel={to_string(@pending_cancel)}
    >
      <%!-- Line 1: what was classified, and who it was aimed at. --%>
      <div class="flex min-w-0 items-center gap-2">
        <span
          class="min-w-0 flex-1 truncate font-mono text-xs text-base-content"
          data-role="intent-label"
          title={@intent.chunk_excerpt}
        >
          {@intent.classified_intent || "—"}
        </span>
        <span
          class="flex-shrink-0 truncate rounded-full border border-base-300 bg-base-200/60 px-2 py-0.5 text-[10px] text-base-content/70"
          data-role="intent-target"
        >
          @{@intent.target_agent_slug || @intent.target_role || "unassigned"}
        </span>
      </div>

      <%!-- Line 2: confidence, status, controls. --%>
      <div class="flex items-center gap-1">
        <%!-- `role="img"` is what makes `aria-label` binding on a
           generic element: without a role, an author-supplied name on a
           <span> is not guaranteed to be exposed. The label repeats the
           number, so replacing the text content costs nothing. --%>
        <span
          class={[
            "w-10 flex-shrink-0 text-right font-mono text-[10px]",
            confidence_tone_classes(@intent.confidence)
          ]}
          role="img"
          aria-label={confidence_aria_label(@intent.confidence)}
          title={confidence_aria_label(@intent.confidence)}
          data-role="intent-confidence"
          data-low-confidence={to_string(low_confidence?(@intent.confidence))}
        >
          {confidence_readout(@intent.confidence)}
        </span>

        <.chip
          tone={status_tone(@intent.status)}
          class="inline-flex flex-shrink-0 items-center gap-1 font-mono text-[10px]"
          data-role="intent-status-chip"
          data-intent-status={@intent.status}
          title={status_hint(@intent.status)}
        >
          <span class={["size-3", status_icon(@intent.status)]} aria-hidden="true"></span>
          {status_label(@intent.status)}
        </.chip>

        <.chip
          :if={@pending_cancel}
          tone="warning"
          class="inline-flex flex-shrink-0 items-center gap-1 font-mono text-[10px]"
          data-role="intent-pending-cancel-chip"
        >
          <span class="hero-no-symbol size-3" aria-hidden="true"></span> Cancelling
        </.chip>

        <div class="ml-auto flex flex-shrink-0 items-center">
          <button
            :if={removable?(@intent.status)}
            type="button"
            phx-click="intent_reason_picker_toggle"
            phx-value-intent_id={@intent.id}
            disabled={@pending_cancel}
            aria-disabled={to_string(@pending_cancel)}
            aria-expanded={to_string(@reason_picker_open)}
            aria-label={"Remove intent #{@intent.classified_intent}"}
            title="Remove"
            class={[
              "btn btn-ghost btn-square min-h-11 min-w-11 text-base-content/60 hover:text-error",
              @pending_cancel && "btn-disabled opacity-40"
            ]}
            data-role="intent-remove"
            data-intent-id={@intent.id}
          >
            <span class="hero-x-mark size-4" aria-hidden="true"></span>
          </button>

          <button
            :if={correctable?(@intent.status)}
            type="button"
            phx-click="intent_edit_open"
            phx-value-intent_id={@intent.id}
            disabled={@pending_cancel}
            aria-disabled={to_string(@pending_cancel)}
            aria-label={"Correct intent #{@intent.classified_intent}"}
            title="Correct"
            class={[
              "btn btn-ghost btn-square min-h-11 min-w-11 text-base-content/60 hover:text-primary",
              @pending_cancel && "btn-disabled opacity-40"
            ]}
            data-role="intent-edit"
            data-intent-id={@intent.id}
          >
            <span class="hero-pencil-square size-4" aria-hidden="true"></span>
          </button>
        </div>
      </div>

      <%!-- Line 3 (only while picking): the reason.

         IN FLOW, not an absolutely-positioned dropdown. The strip's body
         is `overflow-y-auto`, which CLIPS an absolute child — the menu
         rendered with two of its four options cut off at the scroll
         edge, which is a picker that cannot be used to pick. Growing the
         row instead lets the scroll container do its job.

         Not a JS dropdown either: the choice has to round-trip through
         the LiveView so the correction row carries a reason a human
         actually stated. --%>
      <ul
        :if={@reason_picker_open}
        class="mt-1 flex flex-col rounded-box border border-base-300 bg-base-200/60 p-1"
        role="menu"
        data-role="intent-reason-picker"
        data-intent-id={@intent.id}
      >
        <li class="px-2 py-1 font-mono text-[10px] text-base-content/50">Why remove it?</li>
        <li :for={reason <- IntentCorrection.reasons()}>
          <button
            type="button"
            phx-click="intent_remove"
            phx-value-intent_id={@intent.id}
            phx-value-reason={reason}
            data-confirm={
              confirm_required?(@intent.status) &&
                "This intent is with an agent right now. Cancel the running work?"
            }
            role="menuitem"
            class="flex min-h-11 w-full items-center rounded-lg px-2 text-left text-xs hover:bg-base-300/50 focus-visible-ring"
            data-role="intent-reason-option"
            data-reason={reason}
          >
            {reason_label(reason)}
          </button>
        </li>
      </ul>
    </li>
    """
  end

  attr(:intents, :list, required: true)

  # An OVERLAY, not an inline panel in the rail.
  #
  # The full table carries every column of the ETS row — nine of them,
  # including `subagent_id` and `dispatch_failure_reason`, which are the
  # two an operator debugging a red row actually needs. Rendered inside
  # the 320px rail those columns are clipped away and the control is
  # worse than useless: it looks like it worked and hides the data it
  # exists to show. So the lightning-bolt escapes the rail.
  defp intent_expanded_table(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      data-role="intents-expanded"
    >
      <div class="flex max-h-[80vh] w-full max-w-5xl flex-col rounded-box border border-base-300 bg-base-100 shadow-xl">
        <header class="flex flex-shrink-0 items-center gap-2 border-b border-base-300 px-4 py-3">
          <span class="hero-bolt size-4 flex-shrink-0 text-primary" aria-hidden="true"></span>
          <h2 class="min-w-0 flex-1 truncate text-sm font-semibold">
            Intent queue — {length(@intents)} rows
          </h2>
          <button
            type="button"
            phx-click="toggle_intents_expanded"
            aria-label="Close the full intent table"
            class="btn btn-ghost btn-square min-h-11 min-w-11 text-base-content/60"
            data-role="intents-expanded-close"
          >
            <span class="hero-x-mark size-4" aria-hidden="true"></span>
          </button>
        </header>

        <div class="min-h-0 flex-1 overflow-auto">
          <table class="table-xs table w-full font-mono" data-role="intents-expanded-table">
            <thead class="sticky top-0 bg-base-100">
              <tr>
                <th class="text-left">Intent</th>
                <th class="text-left">Status</th>
                <th class="text-left">Target</th>
                <th class="text-left">Subagent</th>
                <th class="text-left">Failure</th>
                <th class="text-left">Conf.</th>
                <th class="text-left">Model</th>
                <th class="text-left">Elapsed</th>
                <th class="text-left">Excerpt</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={intent <- @intents}
                data-role="intents-expanded-row"
                data-intent-id={intent.id}
                data-intent-status={intent.status}
              >
                <td class="max-w-40 truncate">{intent.classified_intent || "—"}</td>
                <td>
                  <.chip
                    tone={status_tone(intent.status)}
                    class="inline-flex items-center gap-1 font-mono text-[10px] whitespace-nowrap"
                  >
                    <span class={["size-3", status_icon(intent.status)]} aria-hidden="true"></span>
                    {status_label(intent.status)}
                  </.chip>
                </td>
                <td class="max-w-32 truncate" data-role="intents-expanded-target">
                  {intent.target_agent_slug || intent.target_role || "—"}
                </td>
                <td class="max-w-32 truncate" data-role="intents-expanded-subagent">
                  {intent.subagent_id || "—"}
                </td>
                <td class="max-w-32 truncate" data-role="intents-expanded-failure">
                  {intent.dispatch_failure_reason || "—"}
                </td>
                <%!-- Same treatment as the strip. A producer who opened
                   the table did so BECAUSE a row looked wrong; showing
                   `0.55` plain here after showing `~0.55` in warning
                   tone two clicks earlier would read as two different
                   numbers. --%>
                <td
                  data-role="intents-expanded-confidence"
                  data-low-confidence={to_string(low_confidence?(intent.confidence))}
                >
                  <span
                    class={["whitespace-nowrap", confidence_tone_classes(intent.confidence)]}
                    role="img"
                    aria-label={confidence_aria_label(intent.confidence)}
                  >
                    {confidence_readout(intent.confidence)}
                  </span>
                </td>
                <td class="max-w-28 truncate">{intent.model_used || "—"}</td>
                <td>{if intent.elapsed_ms, do: "#{intent.elapsed_ms}ms", else: "—"}</td>
                <td class="max-w-56 truncate">{intent.chunk_excerpt || "—"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:agent_options, :list, default: [])

  defp intent_edit_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      data-role="intent-edit-modal"
      data-intent-id={@row.id}
    >
      <div class="w-full max-w-md rounded-box border border-base-300 bg-base-100 shadow-xl">
        <header class="flex items-center gap-2 border-b border-base-300 px-4 py-3">
          <span class="hero-pencil-square size-4 text-primary" aria-hidden="true"></span>
          <h2 class="min-w-0 flex-1 truncate text-sm font-semibold">Correct this intent</h2>
          <button
            type="button"
            phx-click="intent_edit_close"
            aria-label="Close correction dialog"
            class="btn btn-ghost btn-square min-h-11 min-w-11 text-base-content/60"
            data-role="intent-edit-close"
          >
            <span class="hero-x-mark size-4" aria-hidden="true"></span>
          </button>
        </header>

        <form phx-submit="intent_edit_save" class="flex flex-col gap-3 px-4 py-4">
          <input type="hidden" name="intent_edit[intent_id]" value={@row.id} />

          <p class="rounded-lg bg-base-200/60 px-3 py-2 font-mono text-[11px] text-base-content/70">
            {@row.chunk_excerpt || @row.classified_intent}
          </p>

          <label class="flex flex-col gap-1">
            <span class="text-xs font-medium text-base-content/70">Corrected intent</span>
            <input
              type="text"
              name="intent_edit[corrected_intent]"
              value={@row.classified_intent}
              placeholder="what it should have been"
              class="input input-bordered min-h-11 w-full font-mono text-xs"
              data-role="intent-edit-intent"
            />
          </label>

          <label class="flex flex-col gap-1">
            <span class="text-xs font-medium text-base-content/70">Corrected target agent</span>
            <select
              name="intent_edit[corrected_target_agent_id]"
              class="select select-bordered min-h-11 w-full text-xs"
              data-role="intent-edit-target"
            >
              <option value="">Leave as-is</option>
              <option
                :for={{label, id} <- @agent_options}
                value={id}
                selected={id == @row.target_agent_id}
              >
                {label}
              </option>
            </select>
          </label>

          <label class="flex flex-col gap-1">
            <span class="text-xs font-medium text-base-content/70">Reason</span>
            <select
              name="intent_edit[reason]"
              class="select select-bordered min-h-11 w-full text-xs"
              data-role="intent-edit-reason"
            >
              <option :for={reason <- IntentCorrection.reasons()} value={reason}>
                {reason_label(reason)}
              </option>
            </select>
          </label>

          <div class="flex items-center justify-end gap-2 pt-1">
            <button
              type="button"
              phx-click="intent_edit_close"
              class="btn btn-ghost min-h-11 text-xs"
              data-role="intent-edit-cancel"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary min-h-11 text-xs"
              data-role="intent-edit-save"
              data-confirm={
                confirm_required?(@row.status) &&
                  "This intent is with an agent right now. Save the correction and cancel the running work?"
              }
            >
              Save + remove from queue
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  @doc "Human label for a correction reason atom."
  @spec reason_label(atom() | binary()) :: String.t()
  def reason_label(:wrong_intent), do: "Wrong intent"
  def reason_label(:wrong_target), do: "Wrong target"
  def reason_label(:not_actionable), do: "Not actionable"
  def reason_label(:other), do: "Other"

  def reason_label(reason) when is_binary(reason),
    do: reason |> String.to_existing_atom() |> reason_label()

  @doc """
  Confidence as a two-decimal mono readout, or an em-dash when the
  classifier reported none.
  """
  @spec format_confidence(number() | nil) :: String.t()
  def format_confidence(nil), do: "—"

  def format_confidence(confidence) when is_number(confidence) do
    :erlang.float_to_binary(confidence * 1.0, decimals: 2)
  end

  def format_confidence(_), do: "—"

  @doc """
  The threshold below which a confidence readout is emphasised.

  Exposed so tests and any future classifier-side gate pin the same
  number instead of each restating it.
  """
  @spec low_confidence_threshold() :: float()
  def low_confidence_threshold, do: @low_confidence_threshold

  @doc """
  True when `confidence` is low enough that a producer should look
  before trusting the dispatch.

  `nil` (and anything unparseable) is NOT low: the classifier made no
  claim, and rendering "no reading" as "bad reading" would be its own
  lie. Those render as the em-dash, untinted.
  """
  @spec low_confidence?(number() | nil | any()) :: boolean()
  def low_confidence?(confidence) when is_number(confidence),
    do: confidence * 1.0 < @low_confidence_threshold

  def low_confidence?(_), do: false

  @doc """
  Confidence as it is painted: `~0.55` when low, `0.96` when not.

  The `~` is the non-colour half of the treatment. Tone alone would put
  the whole signal back on hue, which is the rule the status chips
  already refuse to break — and this readout is 10px mono, the smallest
  text in the bar and the hardest place to read a tint.
  """
  @spec confidence_readout(number() | nil | any()) :: String.t()
  def confidence_readout(confidence) do
    if low_confidence?(confidence) do
      "~" <> format_confidence(confidence)
    else
      format_confidence(confidence)
    end
  end

  @doc """
  Accessible name for a confidence readout.

  A bare `0.55` announces as a naked number; the emphasis a sighted
  producer gets from tone and the `~` has to reach a screen reader as
  words, so the phrase "low confidence" is spelled out.
  """
  @spec confidence_aria_label(number() | nil | any()) :: String.t()
  def confidence_aria_label(confidence) do
    cond do
      low_confidence?(confidence) -> "Confidence #{format_confidence(confidence)}, low confidence"
      is_number(confidence) -> "Confidence #{format_confidence(confidence)}"
      true -> "Confidence not reported"
    end
  end

  @doc """
  Tone half of the confidence readout's classes — warning when low.

  Both branches are COMPLETE literal strings, and that is the point.
  Tailwind v4 scans this file as plain text, so `"text-" <> tone` would
  compile, render a correct-looking `class` attribute, and ship no rule:
  the same silent, partial failure that put empty boxes where
  `hero-bug-ant` should have been. Returning whole class strings is what
  keeps the scanner able to see them.

  Layout (width, alignment, size) stays at the call site because the
  strip and the expanded table need different layout and the same tone.
  """
  @spec confidence_tone_classes(number() | nil | any()) :: String.t()
  def confidence_tone_classes(confidence) do
    if low_confidence?(confidence) do
      "font-semibold text-warning"
    else
      "text-base-content/50"
    end
  end
end
