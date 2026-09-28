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

  ## Which tasks are counted: the goal's project scope (task `01a0ca9f`)

  Install-wide by default. Rowan, 2026-09-22: "we need to scope the tasks
  just to the Job Hunt project, not all tasks across all projects" --
  measured on milv the same day, the install-wide "31 open tasks" was 28
  Job Hunt tasks plus 3 from an unrelated project, so the number moved
  with work that had nothing to do with the goal.

  The scope is `chat_spaces.metadata["goal_project_id"]` on the goal
  space: a project UUID string. It is NOT a column (no migration). The
  goal editor writes it through `Platform.Chat.Sidebar.save_goal/3` (task
  `01a0cef1`), which re-reads the space and writes goal text and scope in
  ONE update; the value it may write is computed by `put_goal_scope/2`
  against `goal_scope_projects/1`, the live projects the channel's org can
  see (`Platform.Tenancy.scope/2`, `:root_all` for a root-org channel,
  `{:orgs, [org_id]}` for a tenant-org channel, nothing for a space with
  no org). A project outside that list is refused as
  `{:error, :unknown_project}` and nothing is written; an UNCHANGED value
  passes through without validation, so a legacy server-set scope
  survives an unrelated goal-text edit. The org is enforced at WRITE time
  only: `goal_scope/1` below still does not check it. Every beat's write
  (`Map.put` on the existing map) leaves the key in place. It can also be
  set server-side, e.g. from a remote console:

      space = Platform.Chat.get_space(space_id)

      Platform.Chat.update_space(space, %{
        metadata: Map.put(space.metadata || %{}, "goal_project_id", "<project uuid>")
      })

  Unset it by deleting the key (`Map.delete(space.metadata, "goal_project_id")`
  in the same call); `nil` also reads as unset.

  Because the value is untyped, `goal_scope/1` validates it on every read
  and has exactly three outcomes:

    * `:install` -- the key is absent or `nil`. Today's count, slot and
      prompt, byte for byte (`unit: "open tasks"`, no `:project_id`).
    * `{:project, project}` -- the value casts with `Platform.UUID.cast/1`
      (cast FIRST: `Repo.get` raises on a non-UUID string) and names a
      project whose `archived_at` and `deletion_scheduled_at` are both
      nil. The count adds `project_id == ^id`; the unit is
      `"open tasks in <project name>"` and the slot carries `:project_id`.
    * `:unknown` -- anything else: not a UUID, no such project, archived,
      or deletion scheduled. The slot is `%{missing?: true, kind:
      :unknown_scope}` and carries NO number. It never falls back to the
      install-wide count: that is the wrong-population number this scope
      exists to remove. The id is never interpolated either (a UUID would
      carry digits into the measurement line). The beat still fires, as
      for an uncounted goal.

  Only the `:open_tasks` arm reads the scope; an uncounted goal ignores
  it.

  ## A count that could not be read is not zero

  `open_task_count/1` used to rescue a raised query and return `0`, a
  number nobody measured. It now returns `:error`, and the slot is
  `%{missing?: true, kind: :count_failed}`: no number, the beat still
  fires with the no-count system message, and the previous baseline is
  left untouched (a beat stamp is written only when no row exists), so
  the next readable count still gets a real delta.

  ## The first run has no delta and says so

  `delta` is `nil` on the first run for a given space, and the rendered
  clause reads "first measurement — no prior run to compare against". It
  is NOT `0`. A zero that means "no prior measurement" is
  indistinguishable from a zero that means "nothing changed", and a
  signal that cannot differ is the failure mode above.

  The previous measurement is persisted on the space's `metadata` map
  under `"goal_heartbeat"` (`%{"measurement" => integer, "measured_at" =>
  iso8601, "goal" => the goal string it was taken for}`, plus
  `"project_id"` ONLY when the count was scoped to a project; an unscoped
  row is exactly the three keys it always was). The goal is stored
  alongside the number on purpose: when the goal changes, the old number
  is not a comparable baseline, so the delta resets to "first measurement
  for this goal" rather than reporting a difference between two
  different questions. The scope is compared the same way:
  `previous_measurement/3` requires the row's `"project_id"` (nil when
  absent) to equal the current scope's (nil for `:install`). So an
  existing unscoped baseline still yields its delta, and any scope change
  (install to project, project A to B, project to install) reads as a
  first measurement, never as a delta between two populations.

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

  ## The heartbeat drives; it does not report

  Rowan, 2026-09-22: "this is just a way to make sure that our assigned
  agent gets regular prods saying, keep working towards this goal, and
  you have no agents to delegate to, so this is on you to manage." The
  first live fire of the status-report version was answered with three
  sentences and no work, which is exactly what that prompt asked for.

  So the gather carries a `delegates` roster and the prompt branches on
  its size (task `01a0ca24`):

    * zero delegates -- `drive_instruction/1` renders the solo sentence
      ("You are the only agent working this goal. There is no one to
      delegate to; this is yours. ..."). That sentence appears for an
      EMPTY roster and for nothing else.
    * N delegates -- the same drive, plus "Agents you can delegate to:"
      and every `Name (agent_id)` in `Delegation.eligible_agents/0`'s
      name order.

  The roster is `Platform.Agents.Delegation.eligible_agents/0` minus the
  leader ids: the space's `leader_agent_id` AND whoever
  `Roles.assignee_for/1` resolves for this key (the agent the Router
  actually dispatches the prompt to). Those are separate fields, and
  neither is ever offered to itself as a delegate. `eligible_agents/0`
  counts only agents with a CONNECTED (`RuntimePresence.online?/1`),
  active, non-voice-only runtime and no `DelegationExclusion` row, so the
  roster is THIS HOUR's roster, not the org chart: an agent whose socket
  is down is not offered, and the next fire re-reads it. It is not
  re-derived here from runtimes and exclusions, so the heartbeat and the
  delegation surface cannot disagree about who counts.

  A raise while reading the roster logs a warning and yields `[]` with
  `roster_error: true` rather than losing the dispatch. That case does
  NOT render the solo sentence: "there is no one to delegate to" would be
  a claim nobody measured. It renders `drive_instruction(:unavailable)`,
  which says the roster could not be read.

  ### The drive follows the goal's direction

  Task `01a0caa5`: "pick the open item ... and work it" is the right
  prod for a goal that shrinks a count and the wrong one for a goal that
  grows one (milv's job-board backlog has no open item to pick). The
  gather reads `goal_direction/1` from the goal text -- a CLOSED,
  word-bounded match, not a parser -- and passes it to
  `drive_instruction/2`, and the context carries it as `goal_direction`:

    * close words only (close, reduce, shrink and their listed forms) --
      `:close`, the original "open item" wording, byte for byte;
    * grow words only (grow, increase, populate and their listed forms)
      -- `:grow`, which asks for the single item to ADD;
    * neither family, or both -- `:neutral`, which asks for the single
      action; a conflict is not guessed.

  Only the action sentence changes; the solo, roster and unavailable
  framing are shared. The direction reads the goal, not the measurement
  slot, so an uncounted goal gets it too. `{{drive}}` is rendered in code
  and substituted into the `agents.goal_heartbeat.v1` row, which carries
  no drive text of its own, so no prompt-template migration is needed.

  ## Where the last beat's claim is read

  Each beat asks the leader to end its reply with a "Next:" line, and the
  NEXT beat puts that line back to it ("Last beat you said you would: X.
  Did it ship?"). The claim is read at the next fire's gather, from the
  leader's latest message in the goal space. It is NOT stored from
  `handle_output/3`, and must not be moved there:

    * `Router.dispatch_assignee/4` (router.ex ~1140) sends every
      non-"external" assignee kind to `dispatch_native/6` (~1657), which
      classifies the prompt, builds the signal, calls
      `call_agent_responder/1` and returns `{:ok, :dispatched}`. It never
      calls `invoke_handle_output/3`; that is reached only from
      `run_external_dispatch/5` (~1244).
    * `AgentResponder.broadcast_system_event/3` (agent_responder.ex ~455)
      broadcasts the signal to the runtime's attention topic and returns.
      There is no return channel for the model's output.

  So on the heartbeat's native path, what the leader says exists only as
  a chat message it posts. A claim stored from `handle_output/3` would
  record nothing in production, and a test calling `handle_output/3`
  directly would pass anyway.

  The read (`Chat.latest_agent_message_since/3`): messages in the goal
  space, authored by a leader id (the same ids the roster excludes),
  not deleted, not log-only, inserted strictly after the previous beat's
  `measured_at`. That timestamp is taken BEFORE `record_measurement/2`
  overwrites it. The LAST "Next:" line of the newest such message is the
  claim, trimmed and capped at 280 characters. The four outcomes (claim /
  reply with no Next: line / no reply / first beat) render four distinct
  sentences via `prior_claim_instruction/1`, because an absent claim must
  not read like a kept promise, and "no reply" must not read like "first
  beat".

  The other half of the bridge: the gather sets `dispatch_space_id` to the
  goal space, so `signal.metadata.space_id` names it and AgentResponder
  invites the leader there. Without it the leader had no in-band way to
  know where to reply, and the read above would depend on luck.

  ## A goal with no count still fires, and says it has no count

  Task `01a0ca9f`. A goal that names nothing this handler can count ("Keep
  the job board populated ...") used to refuse the heartbeat outright, so
  the leader of an uncounted goal was never prodded. Now `measure/2`
  returns `%{missing?: true, kind: :uncounted, reason: "no count for this
  goal"}` — no `:value`, `:delta` or `:previous` — and `build_prompt/1`
  dispatches it with its own system message ("This goal has no count:
  never invent a number for it ..."). The prompt's measurement line comes
  from `prompt_measurement/1` ("no count for this goal. There is no number
  the system can count for this goal, so do not supply one: ..."), and
  neither string interpolates the goal, so a goal like "Ship 3 demos"
  cannot put a digit on that line.

  `missing?` stays `true` deliberately: every consumer that branches on it
  (the header strip, `format_measurement_tail/1`, `record_measurement/2`)
  keeps treating the slot as no-number. `missing?: false` with `value:
  nil` would render " (first measurement ...)", a fabricated first run.

  An uncounted beat writes `%{"goal", "beat_at"}` under `"goal_heartbeat"`
  and NO `"measurement"` / `"measured_at"`, so no delta can ever be read
  from it. `previous_beat_at/1` falls back to `"beat_at"`, which is what
  lets the next beat read the leader's reply instead of reporting "first
  beat" forever.

  ## Two states refuse, and the Router now skips the hand-off entirely

  No chat space carries a goal (`measure(nil, _)`), or the space's goal is
  blank (`measure(_, goal) when goal in [nil, ""]`). Those slots carry no
  `kind`, and `build_prompt/1` refuses with `{:error, {:no_measurement,
  reason}}`.

  Task `01a0e881`: before this, the native path still handed the leader a
  bare signal for this refusal — no `prompt` key,
  `prompt_status: :render_gap` — which woke the runtime hourly to spend a
  model turn saying "there is nothing to measure." A missing goal means
  there is nothing to DO, not merely nothing to render, so
  `Router.dispatch_native/6` now matches
  `{:absent, {:refused, {:no_measurement, _}}}` before building any
  signal and skips the whole hand-off: no native signal, no
  `call_agent_responder/1` call, no broadcast to the runtime topic. It
  logs at `:debug` and the fire returns `{:ok, :no_measurement}`
  (`Platform.Responsibilities.outcome/1` maps it to `:not_applicable`,
  alongside `:unfilled`).

  This is deliberately narrower than `@no_work_refusals` — that whitelist
  (`:no_transcript_text`, `:no_intent_text`) still dispatches a bare
  `:no_work` envelope, because an agent that declined to summarize or
  file an action item should still be able to wake and say so. A missing
  goal is a different case: there is no work of any kind for the leader
  to do, so waking it accomplishes nothing and costs a paid turn every
  hour on every install with no goal. `:no_measurement` is therefore
  matched on its own, not added to that list.

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
    * `context_provided` — `["goal", "measurement", "leader", "delegates", "prior_claim"]`
    * `default_prompt_template` — `"agents.goal_heartbeat.v1"`
    * `cost_profile` — `low_freq_capable`
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Agents.Delegation
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @key "agents.goal_heartbeat"
  @feature "agents"
  @template_slug "agents.goal_heartbeat.v1"

  # Where the previous measurement lives on `chat_spaces.metadata`.
  @metadata_key "goal_heartbeat"

  # Where the goal's project scope lives on `chat_spaces.metadata`.
  @scope_key "goal_project_id"

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
        # costs nothing, whatever the cadence.
        #
        # NOTE FOR ANYONE CHANGING THIS: this literal is the DEFAULT. On
        # every boot `upsert_by_key/1` replaces the stored `trigger_config`
        # with it UNLESS the stored value carries `"operator_set": true`,
        # which only an admin's cadence write
        # (`Responsibilities.set_goal_heartbeat_cadence/3`, task 01a0e882)
        # sets. A hand-edit of the row without the marker still reverts on
        # the next deploy.
        trigger_config: %{"expression" => "0 * * * *"},
        scope: "global",
        context_provided: ["goal", "measurement", "leader", "delegates", "prior_claim"],
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
  Assemble the heartbeat context — goal, measurement, leader, the
  delegate roster and the drive paragraph built from it.

  Public so tests can exercise the shape without the full Router
  pipeline.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx \\ %{}) when is_map(ctx), do: do_gather_context(ctx)

  # The system message for a goal with no count (task `01a0ca9f`). The
  # measured string is NOT reused: its "if the delta is absent, say this
  # is the first measurement" would have the leader call every uncounted
  # beat a first measurement.
  @uncounted_system "You are the agents leader. This hourly heartbeat is a prod to drive " <>
                      "the goal, not a status report. This goal has no count: never invent " <>
                      "a number for it, and report concretely what changed since the last " <>
                      "beat instead."

  # Slots that carry no number and still dispatch: an uncounted goal, a
  # project scope that names no project, and a count that raised.
  @no_count_kinds [:uncounted, :unknown_scope, :count_failed]

  @impl true
  @doc """
  Build the (system + user) messages for the heartbeat.

  A slot with no number (`kind: :uncounted`, `:unknown_scope` or
  `:count_failed`) dispatches with its own system message and a
  measurement line that says there is no count.
  Refuses with `{:error, {:no_measurement, reason}}` for every other
  missing slot: no space carries a goal, or the goal is blank.
  """
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, {:no_measurement, String.t()}}
  def build_prompt(context) when is_map(context) do
    case Map.get(context, :measurement) do
      %{missing?: true, kind: kind} when kind in @no_count_kinds ->
        {:ok, %{system: @uncounted_system, user: render_instruction(context)}}

      %{missing?: true} = slot ->
        {:error, {:no_measurement, Map.get(slot, :reason, "no measurement derivable")}}

      _ ->
        system =
          "You are the agents leader. This hourly heartbeat is a prod to drive " <>
            "the goal, not a status report. Never invent a number: use only the " <>
            "figures given. If the delta is absent, say this is the first " <>
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
  puts it on a migrated database, and the hourly drive body that
  replaced it (task `01a0ca24`) arrived by an UPDATE migration
  (`..._update_agents_goal_heartbeat_prompt_drive.exs`) for the same
  reason.
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

    # THE PREVIOUS BEAT'S TIMESTAMP, taken from the snapshot loaded above
    # and therefore BEFORE `record_measurement/2` below overwrites it. It
    # is the lower bound of the window the leader's reply is read from;
    # read after the write, the window would start at "now" and every
    # reply would fall outside it. See "Where the last beat's claim is
    # read" in the moduledoc.
    since = previous_beat_at(space)

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

    leader_ids = leader_ids(space)
    {delegates, roster_error?} = delegate_roster(leader_ids)

    # THE GOAL DIRECTION (task `01a0caa5`), read from the goal TEXT, so it
    # applies to measured and uncounted goals alike. It picks the drive's
    # action sentence only; see "The drive follows the goal's direction"
    # in the moduledoc.
    direction = goal_direction(goal)

    drive_text =
      if roster_error?,
        do: drive_instruction(:unavailable, direction),
        else: drive_instruction(delegates, direction)

    prior_claim = prior_claim(space, leader_ids, since)

    %{
      goal: goal || %{missing?: true, reason: "no chat space carries a goal"},
      measurement: measurement,
      leader: leader_slot(space),
      delegates: delegates,
      roster_error: roster_error?,
      goal_direction: direction,
      drive_text: drive_text,
      prior_claim: prior_claim,
      prior_claim_text: prior_claim_instruction(prior_claim)
    }
    |> put_dispatch_space(space)
  end

  # Names the goal space as the space this dispatch writes into, so the
  # Router copies it to `signal.metadata.space_id` (`put_dispatch_space/2`)
  # and AgentResponder invites the leader there. That is where the reply
  # the next beat reads back has to land.
  defp put_dispatch_space(context, %Space{id: id}) when is_binary(id),
    do: Map.put(context, :dispatch_space_id, id)

  defp put_dispatch_space(context, _space), do: context

  # The previous beat's `measured_at` (a counted beat) or, failing that,
  # its `beat_at` (an uncounted beat, task `01a0ca9f`), whatever goal it
  # was taken for; `nil` when no beat has been recorded (or the stamp
  # does not parse).
  defp previous_beat_at(%Space{metadata: %{} = metadata}) do
    row = Map.get(metadata, @metadata_key)
    stamp = is_map(row) && (Map.get(row, "measured_at") || Map.get(row, "beat_at"))

    with stamp when is_binary(stamp) <- stamp,
         {:ok, at, _offset} <- DateTime.from_iso8601(stamp) do
      at
    else
      _ -> nil
    end
  end

  defp previous_beat_at(_space), do: nil

  # Longest claim carried into the next prompt, in characters.
  @claim_cap 280

  # The last line of a reply that starts "Next:", with its text captured.
  # `[ \t]` rather than `\s` so a bare "Next:" cannot capture the line
  # below it.
  @next_line ~r/^[ \t]*Next:[ \t]*(.+?)[ \t]*$/mi

  # The prior-claim slot. `:first_beat` when no previous beat is recorded;
  # otherwise the leader's latest message in the goal space since that
  # beat decides between `:claimed`, `:no_next_line` and `:no_reply`.
  defp prior_claim(_space, _leader_ids, nil), do: %{status: :first_beat}
  defp prior_claim(nil, _leader_ids, _since), do: %{status: :first_beat}
  defp prior_claim(_space, [], _since), do: %{status: :no_reply}

  defp prior_claim(%Space{id: space_id}, leader_ids, %DateTime{} = since) do
    case Chat.latest_agent_message_since(space_id, leader_ids, since) do
      nil ->
        %{status: :no_reply}

      message ->
        case next_claim(message.content) do
          nil -> %{status: :no_next_line, message_id: message.id}
          claim -> %{status: :claimed, claim: claim, message_id: message.id}
        end
    end
  rescue
    error ->
      Logger.warning("[agents.goal_heartbeat] prior claim read raised: #{inspect(error)}")
      %{status: :unavailable}
  end

  defp next_claim(content) when is_binary(content) do
    case @next_line |> Regex.scan(content) |> List.last() do
      [_, claim] ->
        case claim |> String.trim() |> String.slice(0, @claim_cap) |> String.trim() do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  defp next_claim(_content), do: nil

  @doc """
  The prior-claim line for a prior-claim slot (task `01a0ca24` stage 3).

  Four states, four DISTINCT sentences, so an absent claim can never read
  like a kept promise:

    * `%{status: :claimed, claim: x}` -- the leader's last `Next:` line,
      put back to it as a question;
    * `%{status: :no_next_line}` -- the leader replied but named no next
      action;
    * `%{status: :no_reply}` -- a previous beat exists and the leader
      posted nothing in the goal space since;
    * `%{status: :first_beat}` -- no previous beat is recorded.

  `%{status: :unavailable}` (the read raised) claims none of the four.
  """
  @spec prior_claim_instruction(map()) :: String.t()
  def prior_claim_instruction(%{status: :claimed, claim: claim}) when is_binary(claim),
    do:
      "Last beat you said you would: #{String.trim_trailing(claim, ".")}. " <>
        "Did it ship? Say yes or no and what changed."

  def prior_claim_instruction(%{status: :no_next_line}),
    do: "Last beat your reply named no next action."

  def prior_claim_instruction(%{status: :no_reply}),
    do: "Last beat got no reply from you in this space."

  def prior_claim_instruction(%{status: :first_beat}),
    do: "This is the first beat; there is no prior claim to check."

  def prior_claim_instruction(%{status: :unavailable}),
    do:
      "Last beat's reply could not be read this hour, so whether its claim was kept is not known."

  # The agents never offered to themselves as a delegate: the space's
  # `leader_agent_id` and the agent the Router dispatches this key to
  # (`Roles.assignee_for/1` returns `%Agent{} | nil`, override first).
  defp leader_ids(space) do
    space_leader = if match?(%Space{}, space), do: space.leader_agent_id

    assignee =
      case Roles.assignee_for(@key) do
        %Agent{id: id} -> id
        _ -> nil
      end

    [space_leader, assignee] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # `{roster, roster_error?}`. A raise must not lose the dispatch, and must
  # not be rendered as "no one to delegate to" either -- see the moduledoc.
  defp delegate_roster(leader_ids) do
    roster =
      Delegation.eligible_agents()
      |> Enum.reject(fn {agent, _features} -> agent.id in leader_ids end)
      |> Enum.map(fn {agent, _features} -> %{agent_id: agent.id, name: agent.name} end)

    {roster, false}
  rescue
    error ->
      Logger.warning("[agents.goal_heartbeat] delegate roster raised: #{inspect(error)}")
      {[], true}
  end

  @solo_drive "You are the only agent working this goal. There is no one to delegate to; " <>
                "this is yours. Pick the single open item that most moves the measurement " <>
                "and work it this turn. Report what you picked and what changed."

  @delegate_drive "Pick the single open item that most moves the measurement. Assign it to " <>
                    "one of these agents by creating or assigning a task, or work it yourself " <>
                    "this turn. Report what you picked, who has it, and what changed.\n" <>
                    "Agents you can delegate to: "

  @unavailable_drive "The delegate roster could not be read this hour, so it is not known " <>
                       "whether anyone else can take work. Pick the single open item that most " <>
                       "moves the measurement and work it this turn. Report what you picked " <>
                       "and what changed."

  # The `:grow` and `:neutral` variants (task `01a0caa5`). The solo
  # prefix, the unavailable prefix and the "Agents you can delegate to: "
  # roster line are shared with the `:close` strings above word for word;
  # only the action sentence changes. None of these says "open item": a
  # goal that grows a count has no open item to pick.
  @grow_solo_drive "You are the only agent working this goal. There is no one to delegate " <>
                     "to; this is yours. Pick the single item to add that most moves the " <>
                     "measurement toward the goal and add it this turn. Report what you " <>
                     "added and what changed."

  @grow_delegate_drive "Pick the single item to add that most moves the measurement toward " <>
                         "the goal. Assign it to one of these agents by creating or assigning " <>
                         "a task, or add it yourself this turn. Report what you picked, who " <>
                         "has it, and what changed.\n" <>
                         "Agents you can delegate to: "

  @grow_unavailable_drive "The delegate roster could not be read this hour, so it is not " <>
                            "known whether anyone else can take work. Pick the single item to " <>
                            "add that most moves the measurement toward the goal and add it " <>
                            "this turn. Report what you added and what changed."

  @neutral_solo_drive "You are the only agent working this goal. There is no one to delegate " <>
                        "to; this is yours. Pick the single action that most moves the " <>
                        "measurement toward the goal and take it this turn. Report what you " <>
                        "did and what changed."

  @neutral_delegate_drive "Pick the single action that most moves the measurement toward " <>
                            "the goal. Assign it to one of these agents by creating or " <>
                            "assigning a task, or take it yourself this turn. Report what you " <>
                            "picked, who has it, and what changed.\n" <>
                            "Agents you can delegate to: "

  @neutral_unavailable_drive "The delegate roster could not be read this hour, so it is not " <>
                               "known whether anyone else can take work. Pick the single " <>
                               "action that most moves the measurement toward the goal and " <>
                               "take it this turn. Report what you did and what changed."

  @doc """
  The direction a goal asks the measurement to move (task `01a0caa5`).

  A small CLOSED word match on the downcased goal, word-bounded, in the
  same discipline as `measurable_kind/1`: no open parser and no stemming
  beyond the listed forms.

    * `:grow` -- a grow word (grow, grows, growing, grown, increase,
      increases, increasing, populate, populated, populating) and no
      close word;
    * `:close` -- a close word (close, closes, closing, closed, reduce,
      reduces, reducing, shrink, shrinks, shrinking) and no grow word;
    * `:neutral` -- both families (a conflict is not guessed), neither,
      or a non-binary input such as a `missing?: true` goal slot or `nil`.
  """
  @spec goal_direction(String.t() | term()) :: :grow | :close | :neutral
  def goal_direction(goal) when is_binary(goal) do
    down = String.downcase(goal)

    grow? =
      Regex.match?(
        ~r/\b(?:grow|grows|growing|grown|increase|increases|increasing|populate|populated|populating)\b/u,
        down
      )

    close? =
      Regex.match?(
        ~r/\b(?:close|closes|closing|closed|reduce|reduces|reducing|shrink|shrinks|shrinking)\b/u,
        down
      )

    case {grow?, close?} do
      {true, false} -> :grow
      {false, true} -> :close
      _ -> :neutral
    end
  end

  def goal_direction(_goal), do: :neutral

  @doc """
  The drive paragraph for a delegate roster (task `01a0ca24`), in the
  `:close` direction. Equivalent to `drive_instruction(roster, :close)`.
  """
  @spec drive_instruction([%{agent_id: String.t(), name: String.t()}] | :unavailable) ::
          String.t()
  def drive_instruction(roster), do: drive_instruction(roster, :close)

  @doc """
  The drive paragraph for a delegate roster and a goal direction (tasks
  `01a0ca24`, `01a0caa5`).

  `[]` renders the solo instruction -- and ONLY `[]` does. A non-empty
  roster renders the delegate drive followed by `Name (agent_id)` entries
  joined with ", " in the roster's order (which is
  `Delegation.eligible_agents/0`'s name order). `:unavailable` is the
  roster-read-failed case: it claims neither solitude nor a roster.

  `direction` (see `goal_direction/1`) picks the action sentence only:
  `:close` is the original "open item ... work it" wording, byte for
  byte; `:grow` asks for an item to add; `:neutral` asks for an action.
  """
  @spec drive_instruction(
          [%{agent_id: String.t(), name: String.t()}] | :unavailable,
          :grow | :close | :neutral
        ) :: String.t()
  def drive_instruction([], direction), do: drive_text(direction, :solo)

  def drive_instruction(roster, direction) when is_list(roster) do
    drive_text(direction, :delegate) <>
      Enum.map_join(roster, ", ", fn d -> "#{d.name} (#{d.agent_id})" end)
  end

  def drive_instruction(:unavailable, direction), do: drive_text(direction, :unavailable)

  defp drive_text(:close, :solo), do: @solo_drive
  defp drive_text(:close, :delegate), do: @delegate_drive
  defp drive_text(:close, :unavailable), do: @unavailable_drive
  defp drive_text(:grow, :solo), do: @grow_solo_drive
  defp drive_text(:grow, :delegate), do: @grow_delegate_drive
  defp drive_text(:grow, :unavailable), do: @grow_unavailable_drive
  defp drive_text(:neutral, :solo), do: @neutral_solo_drive
  defp drive_text(:neutral, :delegate), do: @neutral_delegate_drive
  defp drive_text(:neutral, :unavailable), do: @neutral_unavailable_drive

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
        case goal_scope(space) do
          :install ->
            open_tasks_slot(space, goal, nil, "open tasks")

          {:project, %Project{} = project} ->
            open_tasks_slot(space, goal, project.id, "open tasks in #{project.name}")

          # Never the install-wide count, and never the id: see the
          # moduledoc's scope section.
          :unknown ->
            %{
              missing?: true,
              kind: :unknown_scope,
              reason: "the goal's project scope names no project that exists"
            }
        end

      # An uncounted goal (task `01a0ca9f`). `missing?: true` on purpose:
      # every consumer that branches on it keeps treating the slot as
      # no-number. The reason does NOT interpolate the goal, which could
      # carry a digit ("Ship 3 demos") into the measurement line.
      :none ->
        %{missing?: true, kind: :uncounted, reason: "no count for this goal"}
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

  @doc """
  The goal space's project scope (task `01a0ca9f`), read from
  `metadata["goal_project_id"]`.

    * `:install` -- the key is absent or `nil`;
    * `{:project, %Project{}}` -- it casts as a UUID and names a project
      that is neither archived nor scheduled for deletion;
    * `:unknown` -- anything else.

  The value is cast with `Platform.UUID.cast/1` before any Repo call: it
  accepts only the canonical 36-character form, so a 16-byte binary
  cannot clear it the way it clears a bare `Ecto.UUID.cast/1`.
  """
  @spec goal_scope(Space.t() | nil) :: :install | {:project, Project.t()} | :unknown
  def goal_scope(%Space{metadata: %{} = metadata}) do
    case Map.get(metadata, @scope_key) do
      nil -> :install
      raw -> resolve_scope(raw)
    end
  end

  def goal_scope(_space), do: :install

  defp resolve_scope(raw) do
    with {:ok, id} <- Platform.UUID.cast(raw),
         %Project{archived_at: nil, deletion_scheduled_at: nil} = project <-
           Tasks.get_project(id) do
      {:project, project}
    else
      _ -> :unknown
    end
  end

  @doc """
  The projects `space`'s goal may be scoped to (task `01a0cef1`): the
  live (not archived, not deletion-scheduled) projects the channel's org
  can see, ordered by name.

  Visibility goes through `Platform.Tenancy.scope/2`, the one choke point,
  rather than a hand-rolled `where`. A root-org channel reads `:root_all`,
  mirroring `Tenancy.visibility/1`'s ruling that sub-orgs are filtering
  mechanisms; a tenant-org channel reads `{:orgs, [org.id]}`. A space whose
  `org_id` is nil (or names no org) fails closed to `[]`. The live-only
  filter matches `resolve_scope/1`, so no option offered here is one
  `measure/2` would read as `:unknown`.
  """
  @spec goal_scope_projects(Space.t() | nil) :: [Project.t()]
  def goal_scope_projects(%Space{org_id: org_id}) do
    vis =
      case Tenancy.get_org(org_id) do
        %Org{} = org -> if Tenancy.tier(org) == :root, do: :root_all, else: {:orgs, [org.id]}
        nil -> :none
      end

    from(p in Project,
      where: is_nil(p.archived_at) and is_nil(p.deletion_scheduled_at),
      order_by: [asc: p.name]
    )
    |> Tenancy.scope(vis)
    |> Repo.all()
  end

  def goal_scope_projects(_space), do: []

  @doc """
  The metadata map to write for a goal-editor scope submission `raw`
  (task `01a0cef1`), or `{:error, :unknown_project}`.

    * `nil` or `""` -- the key is removed (install-wide).
    * `raw` equal to the stored value -- metadata unchanged, NOT
      re-validated, so a legacy server-set scope the admin never touched
      survives a goal-text edit even when it is not an offered option.
    * otherwise -- cast with `Platform.UUID.cast/1` FIRST, then accepted
      only when it names one of `goal_scope_projects/1`. Anything else
      (non-UUID, unknown, foreign-org, archived, deletion-scheduled) is
      refused. Never a silent save, never a fallback to install-wide.

  It never touches `metadata["goal_heartbeat"]`: the baseline reset on a
  scope change is `previous_measurement/3`'s project comparison.
  """
  @spec put_goal_scope(Space.t(), term()) :: {:ok, map()} | {:error, :unknown_project}
  def put_goal_scope(%Space{} = space, raw) do
    metadata = space.metadata || %{}

    cond do
      raw in [nil, ""] ->
        {:ok, Map.delete(metadata, @scope_key)}

      raw == Map.get(metadata, @scope_key) ->
        {:ok, metadata}

      true ->
        with {:ok, id} <- Platform.UUID.cast(raw),
             true <- Enum.any?(goal_scope_projects(space), &(&1.id == id)) do
          {:ok, Map.put(metadata, @scope_key, id)}
        else
          _ -> {:error, :unknown_project}
        end
    end
  end

  # The measured slot for the `:install` (`project_id` nil) or
  # `{:project, _}` scope. The install slot is today's slot exactly: no
  # `:project_id` key.
  defp open_tasks_slot(space, goal, project_id, unit) do
    case open_task_count(project_id) do
      {:ok, count} ->
        previous = previous_measurement(space, goal, project_id)

        %{
          missing?: false,
          kind: :open_tasks,
          unit: unit,
          value: count,
          previous: previous && previous.value,
          delta: previous && count - previous.value,
          previous_measured_at: previous && previous.measured_at
        }
        |> put_project_id(project_id)

      :error ->
        %{
          missing?: true,
          kind: :count_failed,
          reason: "the open-task count could not be read"
        }
    end
  end

  defp put_project_id(slot, nil), do: slot
  defp put_project_id(slot, project_id), do: Map.put(slot, :project_id, project_id)

  # `{:ok, count}`, or `:error` when the query raised. Never a made-up
  # `0`: see "A count that could not be read is not zero".
  defp open_task_count(project_id) do
    query =
      from(t in TaskSchema,
        where: t.status not in ^@closed_statuses and is_nil(t.deleted_at),
        select: count(t.id)
      )

    query =
      if project_id, do: from(t in query, where: t.project_id == ^project_id), else: query

    {:ok, Repo.one(query)}
  rescue
    error ->
      Logger.warning("[agents.goal_heartbeat] open task count raised: #{inspect(error)}")
      :error
  end

  # The persisted baseline, or `nil` when there is none FOR THIS GOAL AND
  # THIS SCOPE. A measurement taken for a different goal, or over a
  # different population, is not a baseline for this one — see the
  # moduledoc. An unscoped row has no "project_id" key, which reads as
  # nil and so matches the `:install` scope exactly as before.
  defp previous_measurement(%Space{metadata: metadata}, goal, project_id)
       when is_map(metadata) do
    case Map.get(metadata, @metadata_key) do
      %{"measurement" => value, "goal" => ^goal} = row when is_integer(value) ->
        if Map.get(row, "project_id") == project_id,
          do: %{value: value, measured_at: Map.get(row, "measured_at")}

      _ ->
        nil
    end
  end

  defp previous_measurement(_space, _goal, _project_id), do: nil

  # The baseline write (task `01a0c332`). Takes the ALREADY-COMPUTED slot
  # rather than re-deriving it, so the gather writes exactly the number
  # it reports. Reached from `do_gather_context/1` on every real fire and
  # from `handle_output/3` on the external path. A missing slot (no
  # measurable goal, or no space at all) writes nothing — a slot that
  # cannot name a number has no baseline to advance. A persist failure
  # logs a warning and proceeds: losing the delta must never lose the
  # dispatch.
  defp record_measurement(%Space{} = space, %{missing?: false, value: value} = slot)
       when is_integer(value) do
    row = %{
      "measurement" => value,
      "measured_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "goal" => space.goal
    }

    # "project_id" ONLY when scoped, so an unscoped row stays the exact
    # three-key map it always was.
    row =
      case Map.get(slot, :project_id) do
        nil -> row
        project_id -> Map.put(row, "project_id", project_id)
      end

    metadata = Map.put(space.metadata || %{}, @metadata_key, row)

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

  # An uncounted goal stamps the beat and writes NO baseline: no
  # "measurement" and no "measured_at" key, so `previous_measurement/2`
  # can never compute a delta from it. The stamp is what lets the next
  # beat read the leader's reply instead of saying "first beat" forever.
  # A scope that names no project is stamped the same way.
  defp record_measurement(%Space{} = space, %{missing?: true, kind: kind})
       when kind in [:uncounted, :unknown_scope] do
    persist_beat(space, %{
      "goal" => space.goal,
      "beat_at" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  # A count that raised leaves an existing row untouched, so the next
  # readable count still has its baseline; with no row at all it stamps
  # the beat so the next one is not read as the first.
  defp record_measurement(%Space{} = space, %{missing?: true, kind: :count_failed}) do
    if is_map(Map.get(space.metadata || %{}, @metadata_key)) do
      :ok
    else
      persist_beat(space, %{
        "goal" => space.goal,
        "beat_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    end
  end

  defp record_measurement(_space, _slot), do: :ok

  defp persist_beat(%Space{} = space, row) do
    metadata = Map.put(space.metadata || %{}, @metadata_key, row)

    case Chat.update_space(space, %{metadata: metadata}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[agents.goal_heartbeat] could not persist beat stamp: #{inspect(reason)}")

        :ok
    end
  end

  defp leader_slot(%Space{leader_agent_id: id}) when is_binary(id), do: %{agent_id: id}
  defp leader_slot(_), do: %{missing?: true, reason: "no leader pinned to this space"}

  # `:prior_claim_text` / `:drive_text` are populated by the gather (task
  # `01a0ca24` stages 2-3); a context without them renders the
  # placeholder as blank.
  defp context_to_assigns(context) do
    %{
      goal: format_goal(Map.get(context, :goal)),
      measurement: prompt_measurement(Map.get(context, :measurement)),
      prior_claim: text_or_empty(Map.get(context, :prior_claim_text)),
      drive: text_or_empty(Map.get(context, :drive_text))
    }
  end

  defp text_or_empty(text) when is_binary(text), do: text
  defp text_or_empty(_), do: ""

  defp format_goal(%{missing?: true} = slot),
    do: "(no goal set — #{Map.get(slot, :reason, "unknown")})"

  defp format_goal(goal) when is_binary(goal), do: goal
  defp format_goal(_), do: "(no goal set)"

  @doc """
  Render the measurement slot as the sentence clause both the prompt and
  (stage 4) the header use. The first run reads as a first run.
  """
  @spec format_measurement(map() | nil) :: String.t()
  def format_measurement(%{missing?: true, kind: :uncounted}), do: "no count for this goal"

  def format_measurement(%{missing?: true, kind: :unknown_scope}),
    do: "no count: the goal's project scope names no project that exists"

  def format_measurement(%{missing?: true, kind: :count_failed}),
    do: "no count: the open-task count could not be read"

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
  The measurement clause as the PROMPT carries it (task `01a0ca9f`).

  For an uncounted goal it adds the instruction not to supply a number;
  for every other slot it is `format_measurement/1` verbatim, so a
  measured prompt is unchanged. Neither string interpolates the goal.
  """
  @spec prompt_measurement(map() | nil) :: String.t()
  def prompt_measurement(%{missing?: true, kind: :uncounted} = slot),
    do:
      format_measurement(slot) <>
        ". There is no number the system can count for this goal, so do not " <>
        "supply one: report concretely what changed since the last beat."

  def prompt_measurement(%{missing?: true, kind: :unknown_scope}),
    do:
      "no count for this goal. Its project scope names no project that exists, so " <>
        "nothing was counted: report concretely what changed since the last beat."

  def prompt_measurement(%{missing?: true, kind: :count_failed}),
    do:
      "no count for this goal. The open-task count could not be read this hour, so " <>
        "nothing was counted: report concretely what changed since the last beat."

  def prompt_measurement(slot), do: format_measurement(slot)

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

  # Same layout as the `agents.goal_heartbeat.v1` row written by
  # `20260922180000_update_agents_goal_heartbeat_prompt_drive.exs`
  # (task `01a0ca24`), for a database that carries no row at all.
  defp fallback_body(assigns) do
    "Goal: #{assigns.goal}\nMeasurement: #{assigns.measurement}\n\n" <>
      "#{assigns.prior_claim}\n\n" <>
      "#{assigns.drive}\n\n" <>
      "Lead with the measurement and its movement exactly as given above. " <>
      "Do not recompute it, do not round it, and do not invent a number that is not there. " <>
      "If the measurement says this is the first run, say so rather than reporting no change.\n\n" <>
      "Post your reply in this space. End it with one line that starts \"Next:\" " <>
      "naming the single action you will have done before the next beat."
  end
end
