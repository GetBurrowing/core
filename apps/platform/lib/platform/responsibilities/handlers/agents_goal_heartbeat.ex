defmodule Platform.Responsibilities.Handlers.AgentsGoalHeartbeat do
  @moduledoc """
  `agents.goal_heartbeat` responsibility provider (task `01a0b491`, stage 3).

  An hourly ping from the `agents_leader` to the humans who set
  the agents space's goal. Structure, moduledoc discipline and
  `register/0` shape mirror
  `Platform.Responsibilities.Handlers.ArchitectureCronSweep`, which is the
  verified-live cron exemplar. It deliberately does NOT mirror
  `Handlers.TaskTriage`: that module's `gather_context/2` returns
  `"runtime not yet implemented"` and its `handle_output/3` discards its
  output argument, so it is a registration stub and copying it would ship
  another one.

  ## Why the heartbeat carries a number

  A recurring signal whose body is identical every time trains its
  recipient to ignore it — measured 2026-09-17, roughly 80 byte-similar
  notices where the correct response had become dismissal. So consecutive
  pings must DIFFER when the world differs. The measurement, not the
  prose, is what differs: for the first goal ("close backlog items in
  Suite") it is the count of open tasks plus its delta against the
  previous run.

  ## The first run has no delta and says so

  `delta` is `nil` on the first run for a given space, and the rendered
  clause reads "first measurement — no prior run to compare against". It
  is NOT `0`. A zero that means "no prior measurement" is
  indistinguishable from a zero that means "nothing changed", and a
  signal that cannot differ is the failure mode above.

  The previous measurement is persisted on the space's `metadata` map
  under `"goal_heartbeat"` (`%{"measurement" => integer, "measured_at" =>
  iso8601, "goal" => the goal string it was taken for}`). The goal is
  stored alongside the number on purpose: when the goal changes, the old
  number is not a comparable baseline, so the delta resets to "first
  measurement for this goal" rather than reporting a difference between
  two different questions.

  ## Where the baseline is written (task `01a0c332`)

  In `do_gather_context/1`, immediately after `measure/2` returns the
  slot, via `record_measurement/2`.

  The original build wrote the baseline from `handle_output/3` instead,
  on the stated belief that persisting there "keeps a dry-run context
  read from silently consuming the delta". That belief was false for
  this responsibility, and the decision built on it was load-bearing in
  the worst way: `Router.dispatch_native/5`
  (`apps/platform/lib/platform/responsibilities/router.ex`, ~1657) — the
  arm `dispatch_assignee/4` (~1165) routes EVERY non-"external" assignee
  kind to, which is what the heartbeat's native agent assignee is —
  never calls `invoke_handle_output/3`. That seam runs only after the
  external HTTP round trip, in `run_external_dispatch/5` (~1244). The
  only code that wrote the baseline was therefore unreachable, and every
  real fire re-reported "first measurement — no prior run to compare
  against" forever (defect task `01a0c332`; measured live in the Agents
  space, where the heartbeat reverted to the constant ping it was built
  to replace).

  The gather is the write point on its own merits, not a workaround for
  a missing hook: there is no dry-run path in the Router (grep
  `dry_run` in router.ex returns nothing), and
  `gather_context_via_provider/3` runs exactly once per fire from the
  shared preamble in `dispatch_assignee/4`, so a context read cannot
  happen without a real dispatch. The one other caller of `measure/2` is
  the stage-4 header re-derivation on every goal save — which is why the
  write MUST NOT move into `measure/2`: it is public and it runs on
  every save, so persisting there would advance the baseline on every
  render and the heartbeat would read "unchanged" forever.
  `measure/2` stays non-persisting by design; `record_measurement/2`
  takes the already-computed slot instead of re-deriving it, so the
  gather writes exactly what it reports. `handle_output/3` still
  delegates to the same `record_measurement/2` (re-deriving via
  `measure/2`) for a hypothetical external assignee, where the seam is
  live; for this key it stays unreachable in production and that is
  fine.

  ## A goal that cannot name a number has no heartbeat

  When no measurement can be derived — no space carries a goal, or the
  goal names nothing countable — `gather_context/2` returns the
  measurement slot as `%{missing?: true, reason: ...}` and `build_prompt/1`
  refuses with `{:error, {:no_measurement, reason}}` instead of
  dispatching a content-free ping. The Router's refusal path surfaces
  that to the human who set the goal. **This is the single state stage 4
  paints with `--color-warning`** — spending that colour on a delta or a
  falling count would leave nothing to raise this one with.

  ## Assignment IS the enable signal

  `metadata["role"] => "agents_leader"`. The Router resolves the assignee
  in one funnel (`Router.do_fire_trigger/2`) via
  `Platform.Roles.assignee_for/1`; a `nil` assignee logs `unfilled`,
  emits `[:platform, :responsibility, :unfilled]` telemetry and returns
  `{:ok, :unfilled}` with no dispatch and no LLM call. Verified by
  reading that funnel, not assumed. There is therefore no in-handler
  gate, and one must not be added.

  One nuance worth writing down because it is invisible from the role
  page: `assignee_for/1` checks a `ResponsibilityOverride` row FIRST and
  only then the role assignment. So "nobody is pinned to `agents_leader`"
  is sufficient for silence only while no override targets this key. An
  override is an operator act, and it enabling dispatch is the intended
  behaviour — but it means the role is not the ONLY switch.

  ## Decision: refused turns are out of scope here, with no surface

  Saru flagged that a turn refused by any mechanism — including today's
  emergent active-agent mutex — currently has nowhere to be shown, so an
  agent whose turn was silently dropped looks identical to an agent with
  nothing to say. Of the three options offered (out of scope; counted and
  carried in this heartbeat's context; deferred to a follow-up ticket),
  **this handler chooses option (i): out of scope, no surface.**

  The reason is that nothing currently COUNTS refusals. The mutex is
  emergent — it falls out of `AttentionRouter` picking one active agent —
  and it writes no row and emits no telemetry event when it declines to
  route a turn. Carrying a count here would therefore mean carrying a
  number derived from nothing, which is the exact defect the rest of this
  module exists to avoid: a measurement that cannot differ. Making
  refusals visible needs a recorded refusal first, and that is a change to
  the routing layer, not to a cron handler.

  What this decision is NOT: it is not a judgement that invisible
  refusals are acceptable. It is a statement that this stage is the wrong
  place to fix it, recorded here so the next reader inherits the
  reasoning rather than the silence.

  ## Spec

    * `key` — `"agents.goal_heartbeat"`
    * `feature` — `"agents"`
    * `trigger_kind` — `cron`, `expression: "0 * * * *"` (top of every hour)
    * `scope` — `global`
    * `context_provided` — `["goal", "measurement", "leader"]`
    * `default_prompt_template` — `"agents.goal_heartbeat.v1"`
    * `cost_profile` — `low_freq_capable`
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks.Task, as: TaskSchema

  @key "agents.goal_heartbeat"
  @feature "agents"
  @template_slug "agents.goal_heartbeat.v1"

  # Where the previous measurement lives on `chat_spaces.metadata`.
  @metadata_key "goal_heartbeat"

  # Task statuses that count as OPEN for the backlog goal. Derived from
  # `Platform.Tasks.Task.statuses/0` minus the two terminal ones, so a
  # new status added there is counted as open by default rather than
  # silently dropped out of the measurement.
  @closed_statuses ~w(done cancelled)

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # Top of every hour. Rowan, 2026-09-22: "that heartbeat should fire
        # every hour at minimum. You need to be regularly reminded of your
        # goal." Dispatch is gated by the `agents_leader` role assignee via
        # `Roles.assignee_for/1` in the Router, so with no leader pinned this
        # costs nothing hourly rather than nothing daily.
        #
        # NOTE FOR ANYONE CHANGING THIS: `trigger_config` is listed in
        # `Responsibilities.@upsert_replace_fields`, so `register/0` REPLACES
        # whatever is in the database on every boot. Editing the row alone
        # works until the next deploy and then silently reverts to this
        # literal -- which is how a schedule change appears to take and then
        # undoes itself. Change it here, not only in the row.
        trigger_config: %{"expression" => "0 * * * *"},
        scope: "global",
        context_provided: ["goal", "measurement", "leader"],
        output_contract: %{
          "heartbeat" => "string"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.agents",
          "status" => "active",
          "role" => "agents_leader",
          "task" => "01a0b491"
        }
      }
    ]
  end

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def gather_context(_responsibility, ctx) when is_map(ctx), do: {:ok, do_gather_context(ctx)}
  def gather_context(_responsibility, _ctx), do: {:ok, do_gather_context(%{})}

  @doc """
  Assemble the heartbeat context — goal, measurement, leader.

  Public so tests can exercise the shape without the full Router
  pipeline.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx \\ %{}) when is_map(ctx), do: do_gather_context(ctx)

  @impl true
  @doc """
  Build the (system + user) messages for the heartbeat.

  Refuses with `{:error, {:no_measurement, reason}}` when the
  measurement slot is missing. A goal that cannot name a number has no
  heartbeat: dispatching anyway would produce the byte-similar ping this
  responsibility exists to avoid.
  """
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, {:no_measurement, String.t()}}
  def build_prompt(context) when is_map(context) do
    case Map.get(context, :measurement) do
      %{missing?: true} = slot ->
        {:error, {:no_measurement, Map.get(slot, :reason, "no measurement derivable")}}

      _ ->
        system =
          "You are the agents leader posting the daily goal heartbeat. " <>
            "Report the goal, the current measurement and its movement since the " <>
            "previous run in at most three sentences. Never invent a number: use " <>
            "only the figures given. If the delta is absent, say this is the first " <>
            "measurement rather than reporting no change."

        {:ok, %{system: system, user: render_instruction(context)}}
    end
  end

  @doc """
  Render the heartbeat instruction from the DB template, falling back to
  the source descriptor when no row is seeded.

  `PromptTemplates.render_template/2` reads the `prompt_templates` ROW,
  never `do_default_templates/0`, and `seed_defaults/0` is INSERT-only —
  so an edit to a code default is a runtime no-op wherever a row already
  exists. This slug is therefore owned by a seed migration
  (`..._seed_agents_goal_heartbeat_prompt.exs`), which is what actually
  puts it on a migrated database.
  """
  @spec render_instruction(map()) :: String.t()
  def render_instruction(context) when is_map(context) do
    assigns = context_to_assigns(context)

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, rendered} when is_binary(rendered) and rendered != "" ->
        rendered

      _ ->
        case PromptTemplates.render_default(@template_slug, assigns) do
          {:ok, body} -> body
          _ -> fallback_body(assigns)
        end
    end
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(%Responsibility{} = _responsibility, _output, trigger_meta) do
    # Baseline write for the EXTERNAL path only. `invoke_handle_output/3`
    # is reachable from `run_external_dispatch/5` (~1244) and never from
    # `dispatch_native/5` (~1657) — the arm every cron→agent-turn fire
    # takes — so for this key this callback does not run in production.
    # The write that runs on every real fire lives in
    # `do_gather_context/1` → `record_measurement/2` (task `01a0c332`).
    # Kept as parity for a hypothetical external assignee, re-deriving
    # through the public (and deliberately non-persisting) `measure/2`.
    space =
      case Map.get(trigger_meta || %{}, :space_id) || Map.get(trigger_meta || %{}, "space_id") do
        id when is_binary(id) -> Chat.get_space(id)
        _ -> agents_space()
      end

    record_measurement(space, measure(space, space && space.goal))

    :ok
  end

  @impl true
  def handle_refusal(%Responsibility{} = _responsibility, refusal, _trigger_meta) do
    Logger.info("[agents.goal_heartbeat] refused dispatch: #{inspect(refusal)}")
    :ok
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  defp do_gather_context(_ctx) do
    space = agents_space()

    goal = space && space.goal
    measurement = measure(space, goal)

    # THE BASELINE WRITE (task `01a0c332`). The only handler-owned point
    # that runs on every real fire: the Router's native arm
    # (`dispatch_native/5`) never invokes `handle_output/3`, so the
    # original build's persist was unreachable and every fire read as a
    # first measurement. `measure/2` must stay non-persisting — it is
    # also the stage-4 header re-derivation, called on every goal save,
    # and persisting there would advance the baseline on every render.
    record_measurement(space, measurement)

    %{
      goal: goal || %{missing?: true, reason: "no chat space carries a goal"},
      measurement: measurement,
      leader: leader_slot(space)
    }
  end

  @doc """
  The space this heartbeat speaks for: the earliest-created space that
  carries a `goal`. Preferring one with a `leader_agent_id` set so a
  half-configured space cannot shadow the configured one.
  """
  @spec agents_space() :: Space.t() | nil
  def agents_space do
    from(s in Space,
      where: not is_nil(s.goal) and s.goal != "" and is_nil(s.archived_at),
      order_by: [desc: not is_nil(s.leader_agent_id), asc: s.inserted_at],
      limit: 1
    )
    |> Repo.one()
  rescue
    error ->
      Logger.warning("[agents.goal_heartbeat] agents_space lookup raised: #{inspect(error)}")
      nil
  end

  @doc """
  Derive the goal's measurement, or an explicit `missing?: true` slot.

  Public so stage 4 can re-derive on save without going through the
  Router: a saved goal whose measurement can no longer be derived must
  show the no-measurement state immediately, not the previous goal's
  stale number.
  """
  @spec measure(Space.t() | nil, String.t() | nil) :: map()
  def measure(nil, _goal), do: %{missing?: true, reason: "no chat space carries a goal"}

  def measure(_space, goal) when goal in [nil, ""],
    do: %{missing?: true, reason: "the space has no goal set"}

  def measure(%Space{} = space, goal) when is_binary(goal) do
    case measurable_kind(goal) do
      :open_tasks ->
        count = open_task_count()
        previous = previous_measurement(space, goal)

        %{
          missing?: false,
          kind: :open_tasks,
          unit: "open tasks",
          value: count,
          previous: previous && previous.value,
          delta: previous && count - previous.value,
          previous_measured_at: previous && previous.measured_at
        }

      :none ->
        %{
          missing?: true,
          reason:
            "the goal #{inspect(goal)} names nothing this handler can count — " <>
              "no measurement, so no heartbeat"
        }
    end
  end

  # Which goals this handler can put a number to. Deliberately a small
  # closed match rather than an open parser: a goal it cannot measure
  # must land in the `missing?` state loudly, not be answered with a
  # number derived from a guess.
  defp measurable_kind(goal) when is_binary(goal) do
    down = String.downcase(goal)

    if String.contains?(down, "backlog") or
         (String.contains?(down, "task") and String.contains?(down, "close")) do
      :open_tasks
    else
      :none
    end
  end

  defp open_task_count do
    from(t in TaskSchema,
      where: t.status not in ^@closed_statuses and is_nil(t.deleted_at),
      select: count(t.id)
    )
    |> Repo.one()
  rescue
    error ->
      Logger.warning("[agents.goal_heartbeat] open task count raised: #{inspect(error)}")
      0
  end

  # The persisted baseline, or `nil` when there is none FOR THIS GOAL.
  # A measurement taken for a different goal is not a baseline for this
  # one — see the moduledoc.
  defp previous_measurement(%Space{metadata: metadata}, goal) when is_map(metadata) do
    case Map.get(metadata, @metadata_key) do
      %{"measurement" => value, "goal" => ^goal} = row when is_integer(value) ->
        %{value: value, measured_at: Map.get(row, "measured_at")}

      _ ->
        nil
    end
  end

  defp previous_measurement(_space, _goal), do: nil

  # The baseline write (task `01a0c332`). Takes the ALREADY-COMPUTED slot
  # rather than re-deriving it, so the gather writes exactly the number
  # it reports. Reached from `do_gather_context/1` on every real fire and
  # from `handle_output/3` on the external path. A missing slot (no
  # measurable goal, or no space at all) writes nothing — a slot that
  # cannot name a number has no baseline to advance. A persist failure
  # logs a warning and proceeds: losing the delta must never lose the
  # dispatch.
  defp record_measurement(%Space{} = space, %{missing?: false, value: value})
       when is_integer(value) do
    metadata =
      Map.put(space.metadata || %{}, @metadata_key, %{
        "measurement" => value,
        "measured_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "goal" => space.goal
      })

    case Chat.update_space(space, %{metadata: metadata}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[agents.goal_heartbeat] could not persist measurement: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp record_measurement(_space, _slot), do: :ok

  defp leader_slot(%Space{leader_agent_id: id}) when is_binary(id), do: %{agent_id: id}
  defp leader_slot(_), do: %{missing?: true, reason: "no leader pinned to this space"}

  defp context_to_assigns(context) do
    %{
      goal: format_goal(Map.get(context, :goal)),
      measurement: format_measurement(Map.get(context, :measurement))
    }
  end

  defp format_goal(%{missing?: true} = slot),
    do: "(no goal set — #{Map.get(slot, :reason, "unknown")})"

  defp format_goal(goal) when is_binary(goal), do: goal
  defp format_goal(_), do: "(no goal set)"

  @doc """
  Render the measurement slot as the sentence clause both the prompt and
  (stage 4) the header use. The first run reads as a first run.
  """
  @spec format_measurement(map() | nil) :: String.t()
  def format_measurement(%{missing?: true} = slot),
    do: "no measurement available — #{Map.get(slot, :reason, "unknown")}"

  def format_measurement(%{missing?: false, value: value, unit: unit, delta: nil}),
    do: "#{value} #{unit} (first measurement — no prior run to compare against)"

  def format_measurement(%{missing?: false, value: value, unit: unit, delta: 0}),
    do: "#{value} #{unit} (unchanged since the previous run)"

  def format_measurement(%{missing?: false, value: value, unit: unit, delta: delta})
      when is_integer(delta) do
    direction = if delta > 0, do: "up", else: "down"
    "#{value} #{unit} (#{direction} #{abs(delta)} since the previous run)"
  end

  def format_measurement(_), do: "no measurement available"

  @doc """
  `format_measurement/1` minus its leading numeral.

  Stage 4's header renders the number — and ONLY the number — in
  JetBrains Mono inline in the sentence, so it needs the sentence split
  at exactly that boundary. Derived from `format_measurement/1` by
  stripping the leading integer rather than reassembling the clause from
  parts, so the two can never drift into saying different things about
  the same measurement.

  Returns the whole string unchanged for a slot with no leading numeral
  (the `missing?: true` case), which is why the header still asks
  `missing?` rather than inferring the state from this.
  """
  @spec format_measurement_tail(map() | nil) :: String.t()
  def format_measurement_tail(%{missing?: false, value: value} = slot) when is_integer(value) do
    rendered = format_measurement(slot)
    prefix = Integer.to_string(value)

    case rendered do
      ^prefix <> tail -> tail
      other -> other
    end
  end

  def format_measurement_tail(slot), do: format_measurement(slot)

  defp fallback_body(assigns) do
    "Goal: #{assigns.goal}\nMeasurement: #{assigns.measurement}\n" <>
      "Post the daily heartbeat for this goal in at most three sentences."
  end
end
