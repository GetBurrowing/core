defmodule PlatformWeb.Components.PlanningStepExtension do
  @moduledoc """
  Board-level rendering of a task's ADR-0046 planning-step record — the fused
  strip that sits directly above a task card (task `019f9b29-9c47`, stack
  member 8).

  Stage 1 is this module alone: a pure presentation component with **no call
  sites**. Stage 2 wires it above the desktop and mobile solo cards, stage 3
  adds the compact marker to stack-member rows. Zero lines land in
  `tasks_live.ex` in any of them, and this module existing is what makes that
  possible.

  ## The three outcomes and their treatments

  Member 4 (`Platform.Tasks.Task`) persists a per-step record keyed by
  `Task.planning_step_keys/0`, whose `"outcome"` is drawn from
  `Task.planning_step_outcomes/0`. The rule in
  `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`
  is that `not_applicable` and
  `failed` **must never collapse into one value** — a gate that never ran must
  never be indistinguishable from a gate that ran and passed. This table is the
  presentation half of that promise:

  | outcome          | treatment                                             | renders at |
  | ---------------- | ----------------------------------------------------- | ---------- |
  | `not_applicable` | **nothing at all**                                    | never      |
  | `complete`       | muted chip, `hero-check-badge`, step label             | `backlog`, `planning` |
  | `failed`         | destructive chip, `hero-exclamation-triangle`, "… gate did not run" | every status, forever |

  Plus two entries that are not outcomes:

  * the **one `not_applicable` that renders** — see below;
  * the **active cursor**, `task.planning_step`, which shows what the planner
    is doing right now.

  `not_applicable` renders nothing by *producing nothing* — `entries/1` returns
  `[]`, the root element's `:if` is false, and the component contributes no DOM.
  It is deliberately not achieved with `opacity-0` or `hidden`: a hidden node is
  still findable, still costs layout, and is still a board change for an org
  that opted into none of this. The hardest constraint on this task is that an
  org with no designer and no architect sees today's board *exactly*.

  ## The one `not_applicable` that does render

  Member 7 (`Platform.Design.PreplanStep`) records the design step as
  `not_applicable` with reason `"no_ui_surface"` when its heuristic says the
  task has no UI surface, and budgets that heuristic at **zero** false
  negatives — because a missed design step is indistinguishable from "no
  designer assigned", which is the invisibility ADR-0046 exists to close.
  `audit_ui_prediction/2` is member 7's own detector for that budget being
  blown, and it annotates the entry `"no_ui_surface_contradicted"`.

  That single reason therefore renders, as a **warning**-toned chip: visually
  distinct from `failed` (error-toned) *and* from silence. Every other
  `not_applicable`, whatever its reason, renders nothing.

  The reason string is read from `PreplanStep.reasons/0` at compile time rather
  than restated here — member 7 exposes that accessor specifically so this
  renderer binds to the *name* and not to the spelling.

  ## Persistence rules

  * `failed` and `no_ui_surface_contradicted` render at **every** `task.status`,
    including `deploying` and `done`. This is ADR-0046's "visible marker that
    persists through to merge"; member 4 owns the PR-body half of the same
    promise and `build_pr_body/3` emits `ARCHITECTURE GATE DID NOT RUN`, so the
    copy here is word-for-word the same sentence a human reads there. There is
    no dismiss control, no `x` button and no auto-expiry — a control that
    removes the marker is the amended-safety-net habit named by
    `0046-design-and-architecture-phases-in-planning.md § Context`.
  * `complete` renders only while the task is still pre-execution
    (`@complete_statuses`). Once work has started, the design canvas is one
    click away in the detail panel's linked-canvases strip, and a permanent
    muted band on every in-flight card is 20px of height per card for zero
    decision value. Note what this does and does not collapse: the *dangerous*
    direction (a failure going quiet) stays open at every status; only the
    benign direction (a success going quiet) is traded for density.
  * The active cursor renders only while `@active_statuses`. A stale
    `"designing"` cursor on an `in_progress` task is a bug in member 7's
    expiry, not something this component should paper over by rendering it
    indefinitely.

  ## Purity

  `entries/1` is a pure function of `%Task{}` **fields only** — no `Repo` call,
  no plan lookup, no canvas lookup. The board is the hottest query in the app
  and it stays a single query. That property is asserted directly (the tests
  run `async: true` with no `DataCase` and no checked-out connection), and it is
  the mechanical reason the ADR-0046 bounded-reject-loop counter is *not*
  rendered here: the iteration count lives across `plans.version` rows, so a
  per-card counter would be a per-card query across every column on every board
  refresh.

  ## Tailwind v4: every class is a whole literal

  A `hero-*` or colour class **assembled at render time is invisible to the
  Tailwind v4 scanner**, even inside a `@source`-covered directory — the
  scanner matches complete string literals in the source text, it does not
  execute the code. `hero-bug-ant` and `hero-queue-list` have already shipped
  in this repo as empty boxes with an entirely green test suite, because
  `html =~ "hero-bug-ant"` passes when the class is in the HTML and absent from
  the compiled CSS.

  So every icon and colour class in this module lives in `@treatments` /
  `@cursor_treatments` as a whole string literal. Never `"hero-\#{icon}"`. The
  guard tests assert against `File.read!/1` of **this source file**, not against
  rendered HTML, because only the source is what Tailwind reads.

  Only semantic brand-token slots are used — `accent`, `base-100`/`base-200`/
  `base-300`, `base-content` and its opacity steps, `error`, `warning`. No hex
  literal, no arbitrary colour-function value, no raw palette name. Both themes
  in `app.css` define every slot used here, so the component is theme-correct by
  construction rather than by inspection.

  (The token guard in the test file greps this source, prose included, so the
  forbidden spellings are deliberately not written out even in documentation —
  a guard with a documented exemption is a guard with a hole.)

  ## DOM discipline

  The component emits **no `id` attribute, ever**. Desktop and mobile share one
  DOM (CSS visibility, not presence), so a component rendered on both branches
  that emits a fixed id produces duplicate DOM ids — LiveView undefined
  behaviour that raises on mount. Identification is entirely by caller-supplied
  `data-role` plus per-chip `data-planning-step-key`, `data-planning-outcome`,
  `data-planning-reason` and `data-planning-cursor`. The root additionally
  carries `data-planning-outcome` for the highest-severity entry, so a caller
  can select "this card needs attention" without walking children.

  ## Variants

  * `:extension` — the full fused strip above a card. A `<button>` firing the
    *same* `select_task` event the card fires: the strip is a sibling of the
    card, not a child, so there is no nested-button problem on mobile where the
    card itself is a `<button>`. A visually-fused element sitting on a
    clickable card that does nothing when clicked is a dead zone.
  * `:compact` — a single inline marker for stack-member rows, **failure states
    only** (`failed` and `no_ui_surface_contradicted`); `complete` and the
    active cursor are suppressed. A member row is a ~44px line already carrying
    a position glyph, a truncated title and two badges. It renders as a
    `<span>`, not a `<button>`: it sits *inside* the row's badge cluster, and
    the row is itself clickable.

  ## Examples

      <.planning_step_extension task={task} data_role="planning-step-extension" />
      <.planning_step_extension task={task} variant={:compact} data_role="stack-member-planning-step" />
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Design.PreplanStep
  alias Platform.Tasks.Task

  # Bound to member 7's shipped constant at compile time rather than restated.
  # `PreplanStep.reasons/0` exists for exactly this: "Exposed so tests and
  # member 8's renderer assert against the shipped strings rather than restated
  # copies." A rename there recompiles and follows through here; the guard test
  # still pins the wire value, because the string is also persisted in rows.
  @reason_contradicted PreplanStep.reasons().contradicted

  # Statuses at which a `complete` chip still earns its space, and at which the
  # active cursor is meaningful. Both are subsets of `Task.statuses/0`, asserted
  # in the guards so a typo cannot silently disable the gate.
  @complete_statuses ~w(backlog planning)
  @active_statuses ~w(planning)

  # WHOLE STRING LITERALS. See the Tailwind section of the moduledoc — a class
  # assembled at render time ships as an empty box with a green suite. Keyed by
  # entry KIND, never by step key: the step labels are derived from
  # `Task.planning_step_keys/0` so this module holds no copy of that list.
  @treatments %{
    complete: %{
      icon: "hero-check-badge",
      tone: "text-subtle",
      chip: "bg-base-200/60"
    },
    failed: %{
      icon: "hero-exclamation-triangle",
      tone: "text-error",
      chip: "bg-error/10 border border-error/40"
    },
    contradicted: %{
      icon: "hero-exclamation-triangle",
      tone: "text-warning",
      chip: "bg-warning/10 border border-warning/40"
    }
  }

  # The active-cursor treatments, keyed by `task.planning_step`. `"planning"` is
  # deliberately absent — a plain planning cursor contributes nothing. A guard
  # asserts these keys plus `"planning"` are exactly `Task.planning_steps/0`, so
  # a new cursor value added upstream fails loudly here instead of silently
  # rendering no chip.
  @cursor_treatments %{
    "designing" => %{icon: "hero-paint-brush", tone: "text-accent", label: "Designing"},
    "architecting" => %{icon: "hero-cube-transparent", tone: "text-accent", label: "Architecting"}
  }

  # Most severe first. Drives the root's summary `data-planning-outcome` and the
  # `aria-label` ordering within a kind.
  @severity [:failed, :contradicted, :complete, :active]

  @typedoc """
  One rendered chip. `step_key` is a `Task.planning_step_keys/0` member for
  outcome-derived entries and `nil` for the active cursor; `cursor` is the
  inverse.
  """
  @type entry :: %{
          kind: :complete | :failed | :contradicted | :active,
          step_key: String.t() | nil,
          cursor: String.t() | nil,
          outcome: String.t() | nil,
          reason: String.t() | nil,
          detail: String.t() | nil,
          label: String.t(),
          icon: String.t(),
          tone: String.t(),
          chip: String.t()
        }

  @doc """
  The `not_applicable` reason that renders, as shipped by member 7.

  Exposed so callers and guards bind to the accessor rather than restating the
  string.
  """
  @spec contradicted_reason() :: String.t()
  def contradicted_reason, do: @reason_contradicted

  @doc """
  The statuses at which a `complete` chip renders. See the persistence rules.
  """
  @spec complete_statuses() :: [String.t()]
  def complete_statuses, do: @complete_statuses

  @doc """
  The statuses at which the active-cursor chip renders.
  """
  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

  @doc """
  Whether this task has anything at all to show above its card.

  Callers use this to apply `rounded-t-none` to the card so the strip reads as
  fused rather than stacked. A task with nothing to show must render a
  byte-identical card to today, which is why this is a predicate and not a
  `class` the component always emits.
  """
  @spec visible?(Task.t(), :extension | :compact) :: boolean()
  def visible?(task, variant \\ :extension), do: entries(task, variant) != []

  @doc """
  The chips this task's planning-step record produces, in render order.

  Pure: reads `%Task{}` fields only. Outcome entries come first, ordered by
  `Task.planning_step_keys/0` so output is deterministic; the active cursor —
  which describes *now* rather than what happened — comes last.
  """
  @spec entries(Task.t(), :extension | :compact) :: [entry()]
  def entries(task, variant \\ :extension) do
    outcomes = task.planning_step_outcomes || %{}

    Task.planning_step_keys()
    |> Enum.flat_map(&outcome_entry(&1, Map.get(outcomes, &1)))
    |> Kernel.++(cursor_entry(task))
    |> Enum.filter(&renders?(&1, variant, task.status))
  end

  # ── entry construction ────────────────────────────────────────────────────

  defp outcome_entry(step_key, %{} = record) do
    kind = kind_for(Map.get(record, "outcome"), Map.get(record, "reason"))

    case kind && Map.fetch(@treatments, kind) do
      {:ok, treatment} ->
        [
          %{
            kind: kind,
            step_key: step_key,
            cursor: nil,
            outcome: Map.get(record, "outcome"),
            reason: Map.get(record, "reason"),
            detail: detail_of(record),
            label: label_for(kind, step_key),
            icon: treatment.icon,
            tone: treatment.tone,
            chip: treatment.chip
          }
        ]

      _ ->
        []
    end
  end

  defp outcome_entry(_step_key, _absent), do: []

  # `not_applicable` produces NO entry — except member 7's own false-negative
  # annotation, which is the detector for the heuristic that produced the
  # `not_applicable` in the first place. Every other reason falls through to
  # `nil`, i.e. nothing rendered.
  defp kind_for("complete", _reason), do: :complete
  defp kind_for("failed", _reason), do: :failed
  defp kind_for("not_applicable", @reason_contradicted), do: :contradicted
  defp kind_for(_outcome, _reason), do: nil

  defp cursor_entry(task) do
    case Map.get(@cursor_treatments, task.planning_step) do
      %{} = treatment ->
        [
          %{
            kind: :active,
            step_key: nil,
            cursor: task.planning_step,
            outcome: nil,
            reason: nil,
            detail: nil,
            label: treatment.label,
            icon: treatment.icon,
            tone: treatment.tone,
            chip: ""
          }
        ]

      _ ->
        []
    end
  end

  # ── the persistence rules, in one place ───────────────────────────────────

  # `:compact` is failure-only: see the moduledoc on why a member row does not
  # get a fifth chip for a success.
  defp renders?(%{kind: kind}, :compact, _status) when kind not in [:failed, :contradicted],
    do: false

  defp renders?(%{kind: :complete}, _variant, status), do: status in @complete_statuses
  defp renders?(%{kind: :active}, _variant, status), do: status in @active_statuses
  defp renders?(_entry, _variant, _status), do: true

  # ── copy ──────────────────────────────────────────────────────────────────

  # Derived from the step key rather than tabulated, so this module holds no
  # copy of `Task.planning_step_keys/0`. Copy is not a CSS class — assembling it
  # at render time is safe, and it is what keeps the key list single-sourced.
  defp label_for(:complete, step_key), do: humanise(step_key)

  # WORD-FOR-WORD member 4's PR-body wording (`build_pr_body/3` emits
  # `ARCHITECTURE GATE DID NOT RUN`) so a human reads one sentence in both
  # places.
  defp label_for(:failed, step_key), do: "#{humanise(step_key)} gate did not run"

  defp label_for(:contradicted, step_key),
    do: "#{humanise(step_key)} skipped as non-UI — plan says otherwise"

  defp humanise(step_key) do
    step_key
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp detail_of(record) do
    case Map.get(record, "detail") do
      detail when is_binary(detail) and detail != "" -> detail
      _ -> nil
    end
  end

  defp title_for(%{label: label, detail: nil}), do: label
  defp title_for(%{label: label, detail: detail}), do: "#{label} — #{detail}"

  # The root is a `<button>`, which supports naming natively, so the composed
  # label needs no `role` override. The visual chips are `aria-hidden` because
  # this label already carries their copy verbatim plus the detail they only
  # show on hover.
  defp aria_label([]), do: nil
  defp aria_label(entries), do: Enum.map_join(entries, ", ", &title_for/1)

  defp summary_outcome(entries) do
    @severity
    |> Enum.find_value(fn kind ->
      Enum.find_value(entries, fn
        %{kind: ^kind, outcome: outcome} -> outcome
        _ -> nil
      end)
    end)
  end

  # ── component ─────────────────────────────────────────────────────────────

  attr(:task, :map, required: true, doc: "the `%Platform.Tasks.Task{}` to read")

  attr(:variant, :atom,
    default: :extension,
    values: [:extension, :compact],
    doc: "`:extension` for the fused strip above a card, `:compact` for a stack-member row"
  )

  attr(:data_role, :string,
    required: true,
    doc:
      "caller-supplied identifier. MUST differ between the desktop and mobile branches: " <>
        "they share one DOM, so a shared value double-matches every selector."
  )

  attr(:class, :any, default: nil, doc: "extra classes merged onto the root element")

  @doc """
  Render the planning-step strip for a task, or nothing at all.
  """
  def planning_step_extension(assigns) do
    entries = entries(assigns.task, assigns.variant)

    assigns =
      assigns
      |> assign(:entries, entries)
      |> assign(:aria_label, aria_label(entries))
      |> assign(:summary_outcome, summary_outcome(entries))

    ~H"""
    <button
      :if={@entries != [] and @variant == :extension}
      type="button"
      phx-click="select_task"
      phx-value-id={@task.id}
      data-role={@data_role}
      data-planning-outcome={@summary_outcome}
      aria-label={@aria_label}
      class={[
        "focus-visible-ring flex w-full items-center gap-1.5 overflow-hidden rounded-t-md",
        "border border-b-0 border-edge bg-base-100 px-2 py-1 text-left text-[10px]",
        @class
      ]}
    >
      <span
        :for={entry <- @entries}
        aria-hidden="true"
        title={title_for(entry)}
        data-planning-step-key={entry.step_key}
        data-planning-cursor={entry.cursor}
        data-planning-outcome={entry.outcome}
        data-planning-reason={entry.reason}
        class={[
          "inline-flex min-w-0 items-center gap-1 rounded px-1 py-px",
          entry.tone,
          entry.chip
        ]}
      >
        <span
          :if={entry.kind == :active}
          class="size-1.5 shrink-0 rounded-full bg-accent motion-safe:animate-pulse"
        >
        </span>
        <.icon name={entry.icon} class="size-3 shrink-0" />
        <span class="truncate">{entry.label}</span>
      </span>
    </button>
    <span
      :if={@entries != [] and @variant == :compact}
      data-role={@data_role}
      data-planning-outcome={@summary_outcome}
      role="img"
      aria-label={@aria_label}
      class={["inline-flex shrink-0 items-center gap-0.5", @class]}
    >
      <span
        :for={entry <- @entries}
        title={title_for(entry)}
        data-planning-step-key={entry.step_key}
        data-planning-outcome={entry.outcome}
        data-planning-reason={entry.reason}
        class="inline-flex shrink-0"
      >
        <.icon name={entry.icon} class={["size-3 shrink-0", entry.tone]} />
      </span>
    </span>
    """
  end
end
