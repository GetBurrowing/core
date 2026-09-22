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
        # costs nothing, whatever the cadence.
        #
        # NOTE FOR ANYONE CHANGING THIS: `trigger_config` is listed in
        # `Responsibilities.@upsert_replace_fields`, so `register/0` REPLACES
        # whatever is in the database on every boot. Editing the row alone
        # works until the next deploy and then silently reverts to this
        # literal -- which is how a schedule change appears to take and then
        # undoes itself. Change it here, not only in the row.
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

    drive_text =
      if roster_error?, do: drive_instruction(:unavailable), else: drive_instruction(delegates)

    prior_claim = prior_claim(space, leader_ids, since)

    %{
      goal: goal || %{missing?: true, reason: "no chat space carries a goal"},
      measurement: measurement,
      leader: leader_slot(space),
      delegates: delegates,
      roster_error: roster_error?,
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

  # The previous beat's `measured_at`, whatever goal it was taken for, or
  # `nil` when no beat has been recorded (or the stamp does not parse).
  defp previous_beat_at(%Space{metadata: %{} = metadata}) do
    with %{"measured_at" => stamp} when is_binary(stamp) <- Map.get(metadata, @metadata_key),
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

  @doc """
  The drive paragraph for a delegate roster (task `01a0ca24`).

  `[]` renders the solo instruction -- and ONLY `[]` does. A non-empty
  roster renders the delegate drive followed by `Name (agent_id)` entries
  joined with ", " in the roster's order (which is
  `Delegation.eligible_agents/0`'s name order). `:unavailable` is the
  roster-read-failed case: it claims neither solitude nor a roster.
  """
  @spec drive_instruction([%{agent_id: String.t(), name: String.t()}] | :unavailable) ::
          String.t()
  def drive_instruction([]), do: @solo_drive

  def drive_instruction(roster) when is_list(roster) do
    @delegate_drive <> Enum.map_join(roster, ", ", fn d -> "#{d.name} (#{d.agent_id})" end)
  end

  def drive_instruction(:unavailable), do: @unavailable_drive

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

  # `:prior_claim_text` / `:drive_text` are populated by the gather (task
  # `01a0ca24` stages 2-3); a context without them renders the
  # placeholder as blank.
  defp context_to_assigns(context) do
    %{
      goal: format_goal(Map.get(context, :goal)),
      measurement: format_measurement(Map.get(context, :measurement)),
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
