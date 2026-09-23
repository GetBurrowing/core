defmodule Platform.Orchestration.PromptTemplates do
  @moduledoc """
  Context module for managing prompt templates.

  Prompt templates are stored in the database and used by HeartbeatScheduler
  to generate dispatch and nudge prompts. Templates use `{{variable_name}}`
  mustache-style interpolation (NOT EEx — too dangerous for user-editable content).

  If a template is not found in the database, HeartbeatScheduler falls back
  to its hardcoded prompts, so the system works even before seeding.

  ## Payload split (task 019f640d stage 4)

  Two prompt shapes back the router's runtime dispatches:

  * `dispatch.*` slugs (`.planning`, `.in_progress`, `.in_review`,
    `.review_e2e`, `.deploying`, `.fallback`) — FULL context on state
    transitions. Fat payload, one shot to load skills / evidence workflow /
    stage contract.
  * `nudge` slug — SHORT form on safety-net / no-ack events only. Target
    <500 tokens; no skills_reference, no task description.

  The old `heartbeat` slug is retained as DEPRECATED for one release and
  removed in the stage 6 ADR cleanup pass.

  ## Experimenting on `federation.preamble` is confounded by construction

  Read this BEFORE setting an experiment up on the `federation.preamble` slug.

  The preamble is cross-cutting: it is injected into every Claude Code
  `dispatch.*` body through the `{{federation_preamble}}` placeholder. So a
  variant on `federation.preamble` applies to every dispatch type at once —
  planner, executor, reviewer, deployer, scribe, triage, nudge and heartbeat
  all receive the changed text simultaneously. There is no arm in which only
  one of them moved.

  The consequence is not subtle: a metric that moves cannot be attributed to
  a single agent behaviour. Throughput improving under the treatment is
  consistent with better planning, with better execution, with reviewers
  becoming more permissive, or with any combination — including two effects
  in opposite directions where the larger one wins. The experiment reports a
  number and the number does not say which.

  This is strictly coarser than experimenting on one template such as
  `dispatch.planning`, where the changed text reaches exactly one dispatch
  type. An experiment on `federation.preamble` can answer "did overall
  throughput or quality move"; it cannot answer "which agent behaviour
  changed". If the question is the second one, target a single `dispatch.*`
  slug instead.
  """

  import Ecto.Query

  require Logger

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Repo

  # Every subject this read point can produce is a task. The column is a
  # generic `subject_type` so dispatch-level subjects work later without a
  # migration; this module simply has nothing else in scope to be a subject.
  @subject_type "task"

  @doc "List all prompt templates ordered by slug."
  @spec list_templates() :: [PromptTemplate.t()]
  def list_templates do
    Repo.all(from(t in PromptTemplate, order_by: [asc: t.slug]))
  end

  @doc "Get a prompt template by id."
  @spec get_template(String.t()) :: PromptTemplate.t() | nil
  def get_template(id) do
    # Conservative guard: no in-repo caller pins this id's provenance, and the
    # cost of a redundant check is nothing next to a 500 on a request path.
    if not Platform.UUID.valid?(id) do
      nil
    else
      Repo.get(PromptTemplate, id)
    end
  end

  @doc "Get a prompt template by slug."
  @spec get_template_by_slug(String.t()) :: PromptTemplate.t() | nil
  def get_template_by_slug(slug) do
    Repo.get_by(PromptTemplate, slug: slug)
  end

  @doc "Create a new prompt template."
  @spec create_template(map()) :: {:ok, PromptTemplate.t()} | {:error, Ecto.Changeset.t()}
  def create_template(attrs) do
    %PromptTemplate{}
    |> PromptTemplate.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing prompt template."
  @spec update_template(PromptTemplate.t(), map()) ::
          {:ok, PromptTemplate.t()} | {:error, Ecto.Changeset.t()}
  def update_template(%PromptTemplate{} = template, attrs) do
    template
    |> PromptTemplate.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a prompt template."
  @spec delete_template(PromptTemplate.t()) ::
          {:ok, PromptTemplate.t()} | {:error, Ecto.Changeset.t()}
  def delete_template(%PromptTemplate{} = template) do
    Repo.delete(template)
  end

  @doc """
  Render a template by slug with the given assigns map.

  Fetches the template from the database and interpolates `{{variable_name}}`
  placeholders with values from the assigns map. Returns `{:error, :not_found}`
  if no template exists for the given slug, or if the database is unavailable.

  ## The single variant resolution point (task 019fe6b9, ADR-0048)

  This is the ONLY function in the tree that reads `prompt_templates.content`
  in order to render it — every dispatch caller funnels through here — which
  is why variant resolution lives at this one line and not spread across the
  callers. `PlatformWeb.AdminPromptsLive` also reads the column, but it loads
  templates into an EDIT FORM and never renders a dispatch, so it is
  deliberately NOT routed through the resolver: routing it here would make
  editing a template show the editor somebody else's variant.

  When an experiment applies, what gets interpolated is the variant's
  SNAPSHOTTED blob, never the live row. Interpolation is unchanged either
  way — same `interpolate/2`, same assigns, same `{{var}}` semantics — so a
  variant is a different prompt, not a different templating language.
  """
  @spec render_template(String.t(), map()) :: {:ok, String.t()} | {:error, :not_found}
  def render_template(slug, assigns) do
    case get_template_by_slug(slug) do
      nil ->
        {:error, :not_found}

      %PromptTemplate{content: content} ->
        rendered =
          slug
          |> resolve_content(content, assigns)
          |> interpolate(assigns)

        {:ok, rendered}
    end
  rescue
    _ ->
      {:error, :not_found}
  end

  # Returns the content to render: the variant's snapshotted blob when an
  # experiment applies to this subject, the live template's content otherwise.
  #
  # ## This function may not raise, and that is the whole point
  #
  # Note what sits directly below the caller: `render_template/2` ends in a
  # blanket `rescue -> {:error, :not_found}`. If a resolution failure escaped
  # this function it would land there and a dispatch would be told its
  # template does not exist — turning an experimentation hiccup into a broken
  # dispatch, which is the precise failure posture ADR-0048 forbids. So every
  # exit from here returns a binary: `rescue` and `catch` both fall through to
  # the live content after logging.
  #
  # The reasoning mirrors the transition recorder, which logs and returns the
  # changeset unchanged rather than rolling back a legitimate status write.
  # Observational machinery must not hold the lifecycle hostage. An experiment
  # that quietly loses a subject costs one data point; a dispatch that fails
  # because the experimentation layer had a bad day costs the task.
  defp resolve_content(slug, live_content, assigns) do
    with {:ok, subject_id} <- subject_id(assigns),
         {:ok, experiment, variant_slug} <- resolve_variant_slug(slug, subject_id),
         {:ok, blob} <- variant_content(experiment, variant_slug) do
      blob
    else
      # Not failures. No subject and no experiment are the ordinary case —
      # they cover every dispatch in a system with zero experiments defined,
      # and they must stay silent or the logs become useless.
      :no_subject -> live_content
      :no_experiment -> live_content
      {:error, reason} -> fall_through(slug, reason, live_content)
    end
  rescue
    error -> fall_through(slug, error, live_content)
  catch
    kind, reason -> fall_through(slug, {kind, reason}, live_content)
  end

  defp fall_through(slug, reason, live_content) do
    Logger.error(
      "[PromptTemplates] experiment resolution failed, rendering the live template " <>
        "(slug=#{inspect(slug)}, reason=#{inspect(reason)})"
    )

    live_content
  end

  # The subject is the task the render is for, and it is DERIVED, never
  # invented. Callers already pass `task_id:` in assigns, so no signature
  # changes; a render with no task in scope — cron sweeps, chat and meeting
  # dispatches, the historian — simply has no subject and no experiment
  # applies to it.
  #
  # The empty string is the trap. Several dispatch sites pass
  # `contract_id(task, :id) || ""`, so `""` arrives as a perfectly ordinary
  # value. It must count as NO SUBJECT. Treating it as a subject whose id is
  # `""` would collapse every unattributable render in the system into one
  # shared pseudo-subject and write assignment rows nobody could ever
  # interpret — rows that would still be counted by the metric.
  defp subject_id(assigns) when is_map(assigns) do
    case Map.get(assigns, :task_id) || Map.get(assigns, "task_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :no_subject
    end
  end

  defp subject_id(_assigns), do: :no_subject

  # An EXISTING assignment always wins, and it wins regardless of the
  # experiment's status.
  #
  # That status-blindness is deliberate and is the difference between
  # "stopping an experiment does not re-assign in-flight subjects" holding
  # and merely appearing to. Looking only at `running` experiments would mean
  # a stop silently flips every mid-flight subject back to the live template
  # — no new row written, so the assignment table looks untouched, while the
  # subject's later dispatches came from a different prompt than its earlier
  # ones. That is the same undetectable contamination as re-rolling, reached
  # by a different route.
  #
  # Only a `running` experiment may CREATE an assignment. Terminal ones can
  # be honoured, never joined.
  defp resolve_variant_slug(slug, subject_id) do
    subject = %{subject_type: @subject_type, subject_id: subject_id}
    experiments = Experiments.list_experiments_for_template(slug)

    case existing_assignment(experiments, subject) do
      {experiment, variant_slug} ->
        {:ok, experiment, variant_slug}

      nil ->
        assign_new(experiments, subject)
    end
  end

  defp existing_assignment(experiments, subject) do
    Enum.find_value(experiments, fn experiment ->
      case Assignments.get_assignment(experiment, subject) do
        %Assignment{variant_slug: variant_slug} -> {experiment, variant_slug}
        nil -> nil
      end
    end)
  end

  defp assign_new(experiments, subject) do
    case Enum.filter(experiments, &(&1.status == "running")) do
      [] ->
        :no_experiment

      [experiment | rest] ->
        # ADR-0048's risk register: the design assumes at most one running
        # experiment per slug, because with two the assignment row stops
        # being a unique description of what the subject saw and every
        # per-subject metric is confounded. Nothing structurally prevents a
        # second one, so say so loudly rather than resolving it silently.
        if rest != [] do
          Logger.warning(
            "[PromptTemplates] #{length(rest) + 1} running experiments target " <>
              "#{inspect(experiment.target_template_slug)}; using the oldest. " <>
              "Overlapping experiments on one slug confound every per-subject metric."
          )
        end

        case Assignments.assign_once(experiment, subject) do
          {:ok, %Assignment{variant_slug: variant_slug}} -> {:ok, experiment, variant_slug}
          other -> {:error, {:assign_once, other}}
        end
    end
  end

  # A variant row with no usable blob is a broken experiment, not an empty
  # prompt. Rendering `nil` or `""` would dispatch an agent with no
  # instructions at all, which fails far downstream and looks like a model
  # problem; falling through to the live template loses the data point and
  # nothing else.
  defp variant_content(experiment, variant_slug) do
    case Experiments.get_variant(experiment, variant_slug) do
      %Variant{content: content} when is_binary(content) and content != "" ->
        {:ok, content}

      %Variant{} ->
        {:error, {:variant_blob_empty, variant_slug}}

      nil ->
        {:error, {:variant_missing, variant_slug}}
    end
  end

  @doc """
  Return the default (hardcoded) content for a given slug.

  Returns `nil` if the slug is not a known default.
  """
  @spec default_content_for_slug(String.t()) :: String.t() | nil
  def default_content_for_slug(slug) do
    case Enum.find(do_default_templates(), &(&1.slug == slug)) do
      %{content: content} -> content
      nil -> nil
    end
  end

  @doc """
  Render a slug's DEFAULT (source-descriptor) content with `assigns`, without
  touching the database.

  This is the derive-don't-restate path for dispatch fallbacks. A caller that
  reaches it has already been told `{:error, :not_found}` by
  `render_template/2`, which happens for two reasons: the row was never seeded,
  or the DB is unreachable and the blanket `rescue` turned that into
  `:not_found`. Both mean the same thing here — the served body is unavailable
  and the descriptor in this module is the closest thing to it that still
  exists.

  ## Why this deliberately skips `resolve_content/3`

  No Repo call, no experiment resolution — and that is not an oversight to be
  tidied up later. An experiment variant is a DB concern: variants, experiments
  and assignment rows all live in Postgres. A fallback taken BECAUSE the
  database is unreachable cannot resolve one, and a fallback taken because the
  row is missing has no experiment targeting it either. Routing this through
  the resolver would add a query on the one path whose precondition is that
  queries do not work — turning a degraded dispatch into a failed one, which is
  the posture ADR-0048 forbids. Interpolation is the SAME private
  `interpolate/2` the served path uses, so a derived body differs from the
  served one only by which blob was interpolated.

  Returns `{:error, :not_found}` when the slug is not a registered default.
  """
  @spec render_default(String.t(), map()) :: {:ok, String.t()} | {:error, :not_found}
  def render_default(slug, assigns) do
    case default_content_for_slug(slug) do
      nil -> {:error, :not_found}
      content -> {:ok, interpolate(content, assigns)}
    end
  end

  @doc """
  Seed the 5 default prompt templates from the hardcoded HeartbeatScheduler prompts.

  Idempotent — only inserts if the slug doesn't already exist.
  """
  @spec seed_defaults() :: :ok
  def seed_defaults do
    Enum.each(do_default_templates(), fn template ->
      case get_template_by_slug(template.slug) do
        nil ->
          {:ok, _} = create_template(template)

        _existing ->
          :skip
      end
    end)

    :ok
  end

  @doc """
  Return the hardcoded default template descriptors (slug, name,
  description, variables, content). Exposed so tests and migrations can
  inspect the registered metadata — the seed path uses the same list.
  """
  @spec default_templates() :: [map()]
  def default_templates, do: do_default_templates()

  # ── Private ──────────────────────────────────────────────────────────────

  defp interpolate(content, assigns) do
    Regex.replace(~r/\{\{(\w+)\}\}/, content, fn _match, key ->
      value =
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(assigns, atom_key) || Map.get(assigns, key) || ""
        rescue
          ArgumentError ->
            Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  # Ack-first preamble prepended to every STAGE-SCOPED dispatch template body
  # (task 019f640d stage 5) — `dispatch.in_progress`, `dispatch.in_review`,
  # `dispatch.deploying`. Interpolated via mustache with the runtime's current
  # `task_id` + `stage_id` so the ack call is copy-pasteable.
  #
  # DELIBERATELY NOT ON `dispatch.planning` (task 019fa469 stage 5). The
  # comment that used to sit here claimed "`stage_id` will render as an empty
  # string on the planning dispatch — the `task_ack` tool tolerates a missing
  # stage_id and resolves via `current_running_stage` anyway." That is false in
  # both halves:
  #
  #   * It does not tolerate it. `ToolSurface.resolve_ack_stage_id/2` takes the
  #     explicit stage_id only when it is a non-empty binary; otherwise it
  #     looks for a `status == "running"` stage on the current plan and returns
  #     `{:error, :no_running_stage}` when there is none. A planning dispatch
  #     has no plan at all, so the runtime is answered with
  #     `task_id=<id> has no running stage — cannot ack without a stage_id.`
  #     `alarm_silence` fails through the same resolver.
  #   * There is nothing to ack. `TaskRouter.arm_liveness_timers/3` opens with
  #     `arm_liveness_timers(_task_id, nil, _stage_kind), do: :ok`, so a
  #     stage-less dispatch arms neither `:check_no_ack` nor
  #     `:check_safety_net` and never calls `LeaseManager.record_dispatch/4`.
  #     The preamble's "no-ack alert in 5 minutes" threat is simply false on
  #     that branch.
  #
  #     SCOPE, corrected by task 01a0a5fa stage 3: the SEND is now recorded.
  #     The router emits an `execution.dispatch_stageless` runtime_event, and a
  #     task-level watchdog may later emit `execution.dispatch_unanswered`.
  #     Both are emitted BY THE ROUTER, about its own send — neither is
  #     something the recipient acks, arms a lease, or can satisfy. The
  #     recipient's contract on this branch is unchanged: still no ack.
  #
  # So the planning body states that no ack is expected rather than demanding
  # one. Do not "fix" this by giving `task_ack` a task-level form — that would
  # be API surface for an alarm that does not exist.
  #
  # Spawn paragraph reworded by task 01a0ac55: it no longer claims the server makes an unspawned ack impossible.
  @task_ack_spawn_paragraph "Spawn the subagent FIRST, then pass the id of the subagent you actually spawned as `subagent_id`. The server rejects only a missing, empty, whitespace-only, non-string or over-128-byte subagent_id; it does not verify that the id names a real spawn, so spawn-before-ack ordering is your discipline, not a server guarantee. Without a successful ack the router will fire a no-ack alert in 5 minutes."

  @task_ack_preamble """
  **Your first tool call must be `suite_task_ack(task_id="{{task_id}}", stage_id="{{stage_id}}", subagent_id="<the id returned when you spawned the SuiteExecutor / SuiteReviewer via the Agent tool>")`.**

  #{@task_ack_spawn_paragraph}

  **If `suite_task_ack` is missing from your MCP tool cache** (a known cross-version issue where a session's catalog predates a new tool), call `suite_alarm_silence(task_id="{{task_id}}", stage_id="{{stage_id}}", until_seconds=1800, reason="task_ack absent from stale MCP catalog; subagent live")` as the operator escape hatch. Do NOT use `report_blocker(needs_human: false)` — that anti-pattern sets a task-level lease to blocked and leaks across stage boundaries.
  """

  @doc "Ack-first preamble string interpolated into every stage-scoped dispatch template body."
  @spec task_ack_preamble() :: String.t()
  def task_ack_preamble, do: @task_ack_preamble

  @doc """
  The spawn-ordering paragraph of `task_ack_preamble/0` (task 01a0ac55), on
  its own so a force-update migration can locate and rewrite it in seeded rows.
  It states what `task_ack` actually checks: presence and size of
  `subagent_id`, not that the id names a real spawn.
  """
  @spec task_ack_spawn_paragraph() :: String.t()
  def task_ack_spawn_paragraph, do: @task_ack_spawn_paragraph

  # What `dispatch.planning` says INSTEAD of the ack preamble (task 019fa469
  # stage 5). Kept as its own attribute so the DB template body and
  # `HeartbeatScheduler.hardcoded_dispatch_planning/4` — which the scheduler
  # documents as "kept in parity with the DB dispatch.planning template" —
  # cannot drift. No mustache placeholders: there is nothing task-specific to
  # interpolate, which is the whole point.
  @planning_no_ack_notice """
  **No ack is expected for this dispatch.** A planning dispatch has no running stage, so `task_ack` and `alarm_silence` both fail here with `has no running stage — cannot ack without a stage_id` — that is the tool working correctly, not you failing a step. The router arms no liveness timers for a stage-less dispatch, so no no-ack alert can fire against you. Start with the planning work. The ack instruction appears on your first stage-scoped dispatch, once a plan is approved and a stage is running.
  """

  @doc """
  The planning dispatch's replacement for the ack-first preamble.

  Shared by the `dispatch.planning` template body and the hardcoded
  planning fallback in `HeartbeatScheduler` so the two routes stay
  byte-identical. See `@task_ack_preamble`'s comment for why a planning
  dispatch cannot ack and does not need to.
  """
  @spec planning_no_ack_notice() :: String.t()
  def planning_no_ack_notice, do: @planning_no_ack_notice

  # Federation preamble — canonical block of Claude Code guidance that used
  # to be duplicated across every dispatch template (task 019f5e2a stage 1
  # of the meeting-to-tasks-pipeline stack). Consolidates six sections that
  # every Claude Code dispatch needs BEFORE the template's task-specific
  # body: subagent spawn discipline, org memory context, org memory writes,
  # skill discovery, evidence workflow, and tool-name conventions.
  #
  # Injected at render time via the `{{federation_preamble}}` mustache
  # placeholder — see the `dispatch.*` template descriptors in
  # `do_default_templates/0` and the assigns builder in
  # `HeartbeatScheduler.dispatch_prompt/4`.
  #
  # Downstream stack members (scribe_completion, triage_dispatch) reference
  # the section headers below as stable anchors — do NOT rename them without
  # coordinating with those templates.
  # ENFORCED VERSUS INSTRUCTED — the split, stated where the next reader of
  # this file will find it (task 01a0a5f5 stage 5). Recorded verbatim here and
  # beside `compose_description/3` in
  # `lib/platform_web/live/tasks/task_create_component.ex`; both readers need
  # it and neither will read the other file.
  #
  # > **Falsifier presence and falsifier placement are STRUCTURAL and testable
  # > on the human form — a required field, composed first into the description
  # > body by `compose_description/3`. On every other filing path they are
  # > INSTRUCTION ONLY: the MCP `task_create` body is free-form prose with no
  # > composer and no anchor, so nothing enforces presence and nothing can even
  # > locate placement. A ticket filed through MCP, a seed, or a script arrives
  # > with no falsifier and nothing rejects it. That is the documented state of
  # > this feature, not a defect.**
  #
  # MECHANISM CLASSES, RANKED. The human-form field is structural — required,
  # at the moment of filing, unskippable, order fixed by a function. The
  # agent-side preamble section below (`## Filing a ticket — state its
  # falsifier`) is the WEAKEST class: a sentence in a document read earlier.
  # The `task_create` descriptor in `Platform.Federation.ToolSurface` sits
  # between them — rendered at the moment of the call, still only text. The
  # agent side is text because the ticket's scope bound rules out schema and
  # required-field changes, and because the alternative remedy — keeping cites
  # fresh — is unmaintainable at the observed blast radius: commit `014371a6`
  # (2026-08-26, -4023/+238) invalidated every line cite into
  # `chat_live.html.heex` across the whole backlog in one change. Four times on
  # this platform a correct note failed to change behaviour because nothing
  # made the reader re-read it at the moment of the hazard; Dalton's summary of
  # what did work is "the fix that worked was never a better note — it was a
  # field on a form nobody could skip." The task-create form field is literally
  # that. This preamble section is not, and this comment does not pretend
  # otherwise.
  #
  # EFFICACY OF THE AGENT SIDE IS UNMEASURED. Firing looks like: agent-filed
  # tickets after the deploy carry a falsifier at a rate materially above the
  # pre-change base rate for the same filers, and at least one reader reports
  # stopping on one. Skipped looks like: tickets lacking the sentence, carrying
  # boilerplate that names no checkable observation, carrying it below the
  # prescription, or carrying one the reader proceeded past anyway. The
  # divergence in that rate between the form path and the MCP path is itself
  # the measurement of structure-versus-sentence, and is the thing to read once
  # there is a sample.
  #
  # THE n=1 BOUND. The evidence that self-stated falsifiers fail safe is ONE
  # ticket (`01a04aec`) that did. An existence proof, not a rate. No artifact
  # in this task may assert more.
  #
  @federation_preamble """
  ## Execution posture — close the ticket

  Close the ticket. Do not dither, do not equivocate, and do not fear breaking something: a healthy pipeline fixes what gets broken, and what goes down comes back up. Confidence in execution is expected of every agent here, not only of the orchestrator.

  That confidence is derived, not asserted. You can move fast because the adversarial machinery catches you — mutation probes, e2e cases, the test suite, CI, and the deploy pipeline are what make a wrong step cheap and recoverable. Speed is the dividend of that machinery, so weakening it is how you lose the speed. Never trade a check for pace.

  These stay, and they are the source of the confidence rather than exceptions to it:
  - Report a surviving mutant; do not patch it away.
  - Call a flake a flake; never record one as a pass.
  - Never self-approve a human gate.
  - Stop when a measurement says the work is unnecessary, and say so.

  What to cut is real dithering:
  - Asking for a go-ahead you already have — an assignment IS the authorization.
  - Re-deriving an established fact, or re-litigating a settled decision.
  - Reporting activity as if it were a result ("monitoring CI", "waiting for the verdict") instead of finishing.
  - Hedging a call you are competent to make. Make it, state it, and record the reasoning where the next agent will find it.

  Report outcomes: what shipped, what failed, what you found. Raise a genuine blocker or a decision only a human can make — that is not dithering, that is the job.

  ## Finishing is the job

  The default outcome of a dispatch is a merged PR or a passed validation, not a report. A blocker is a last resort, not a way to hand the work back.

  Before you call `report_blocker` you must have done all three, and your blocker text must show them:
  1. Read org memory for this task and for the exact error you hit (`memory_search`), and cite the hit you found or state that there was none.
  2. Made three distinct, concrete attempts to get past it, listed one per line with what each attempt changed and what happened.
  3. Named the single smallest action that would unblock you and who can perform it.
  A blocker missing any of the three is not a blocker. It is unfinished work.

  Local infrastructure problems are NOT blockers. That covers the test rig, containers, ports, the dev server, moon or hive, docker or podman, credentials for local tooling, and missing tools. When you hit one: post the exact error and the exact command you ran with `suite_reply` in the execution space, with an @-mention of Dalton (type the at-mention yourself; it is not written out here so this template does not itself page him), then keep working on every part of the stage that does not depend on it. Only escalate to a blocker if Dalton has not answered in 60 minutes, and say in the blocker when you pinged and what you kept working on meanwhile.

  Never run the Suite core test suite on hive (Rowan's workstation). Agents owned by Rowan (they are the only ones with moon access) run it on moon via the org skill `moon-test-rig-for-suite-core` (`skill_list` query "moon", then `skill_get`). Every other agent runs it on its own runtime's rig. A broken or unreachable rig is an infra problem: route it to Dalton as above, do not run the suite on hive, and do not file a blocker for it.

  Do not file tickets about the tooling, the router, the board, or the process while you are executing a stage. Write the observation as one journal line (`memory_create` to `org/journal/<today>.md`) and continue. A ticket about the process never satisfies a stage.

  Do not restate the plan back, and do not ask for confirmation of an assignment. The dispatch is the authorization. Start.

  ## Filing a ticket — state its falsifier

  Every ticket you file must carry a sentence naming the observation that would show its premise is wrong, and instructing the reader what to do on seeing it. This is a checkable instruction, the same device as the refuter that closes your own brief — not a hedge and not a confidence rating. A caveat is not a falsifier.

  **State what would show this ticket is wrong.** Name the observation — a grep that comes back empty, a status that differs, a test that passes — and instruct the reader: if you see it, stop and re-derive rather than proceeding.

  **Put it ABOVE the prescriptive content, not at the end.** Your own brief closes with its refuter because a brief is read as a unit before you act. A ticket is not: a fixer reads it to find the instruction and STOPS SCANNING when they find one. A falsifier placed below the prescription is routable-around by construction, and the reader it would have saved — the confident one following a stale instruction to the letter — is exactly the one who never reaches it. On the human task-create form the same content is composed into the body under a `## Wrong` heading placed first; write yours so it reads the same way.

  Why any of this: a cite decays but a falsifier does not. A ticket whose central premise was false four months before it was filed still cost only one verification, because it said "if that does not reproduce, the hypothesis is wrong — say so and re-derive". Without it, a stale ticket whose instruction still applies cleanly LANDS: the fixer passes their own tests and ships the wrong change.

  ## Subagent-spawn discipline

  Handle this task in a subagent with fresh context, **spawned as a background process**. Spawn it via the Agent tool — `general-purpose` is fine — with `run_in_background: true` so the parent conversation stays responsive while the subagent executes. Brief it with the full dispatch payload above, including the Organization Memory section. Do NOT do this work in the parent conversation. The goals: (1) fresh context per task so the org memory discipline below isn't competing with whatever's already loaded, (2) audit clarity so the task lives in its own conversation tree, (3) parent responsiveness — the parent can keep handling other inbound messages or tasks while the subagent runs.

  The subagent should: read org memory first, do the work, write to org memory on decisions, and report back a tight summary. The parent just spawns, then waits for the task-completion notification (do NOT poll, sleep, or proactively check progress — Claude Code notifies the parent automatically when the background agent finishes) and relays the result.

  ## Organization Context
  The `context.org` field carries org-level knowledge as a map of `path => content` for curated wiki pages flagged `preamble: true` in accessible namespaces (`org/*` always; your project's `project/<id>/*` when scoped to a task). Each page's content is wrapped in `<!-- BEGIN org-preamble page="<path>" version="<v>" -->` / `<!-- END org-preamble page="<path>" -->` markers so you can distinguish injected preamble from user input. Read these before writing your plan or making non-obvious choices — they often encode constraints, patterns, or prior decisions that apply here. The preamble is budgeted (~4096 tokens); to retrieve anything beyond the preamble, use the `memory_search` tool.

  ## Writing to Org Memory
  Use the memory_* tool family to read and write organizational knowledge. Path determines routing:
  - `org/page/...`, `project/<id>/page/...`, `space/<id>/page/...` — Historian-only writes. Other agents propose changes by appending to the journal.
  - `org/journal/<YYYY-MM-DD>.md`, `project/<id>/journal/<YYYY-MM-DD>.md`, `space/<id>/journal/<YYYY-MM-DD>.md` — any agent appends. The Historian's daily digest curates journal entries up into pages.
  - `space/<id>/private/<your-agent-id>/...` — your own scratch space; only you can read or write.
  Use `memory_create` to append journal entries (one observation per call — brief, concrete, dated). Use `memory_search` to recall past entries or page content. Use `memory_str_replace` / `memory_insert` only if you ARE the Historian and you're updating a curated page. Write memory alongside your stage work, not as a final cleanup step.

  ### Journal-by-default for non-Historian agents
  Non-Historian agents: edit a page by appending a `<correction target="<page-path>" line="<N>">…</correction>` block to today's journal — never call `memory_str_replace` / `memory_insert` against a page path yourself; those are Historian-only and will return `:historian_only`. The Historian's next run picks up your correction block and applies it to the page during its digest pass.

  ## Skill discovery — do this BEFORE you start executing

  Skills encode org conventions you may not have; load the right one before improvising. Discovery is an active step, not a passive read — the payload bundler does NOT always pre-attach the skill you need:

  1. Derive this task's domain from its title and description (e.g. "task stack", "canvas", "migration", "LiveView").
  2. Call the `skill_list` MCP tool yourself and scan the returned skills for one plausibly matching that domain (a task mentioning "task stack" -> the `task-stack-creation` skill; "canvas" -> a `canvas-*` skill). Do NOT assume the right skill was pre-attached to the payload.
  3. If a skill matches, call the `skill_get` MCP tool to fetch its full content and follow it as authoritative.

  Discovery happens by calling `skill_list` / `skill_get` yourself — do NOT treat "the `skills` key" or an attached skills object as your discovery mechanism, because you receive rendered text, not an introspectable object.

  If the dispatch context did attach skill content inline, still treat that bundled content as authoritative for this task before trying to rediscover skills from disk. Read and follow any relevant bundled skills — they describe conventions, repo layout, deploy targets, and how to delegate work. Only fall back to filesystem skill lookup if the payload clearly references a path without including the needed content.

  ## Submitting evidence for a manual_approval validation

  Visual evidence (screenshots, rendered UI, diagrams) is the bottleneck where most agents stall. The path that actually works is a four-tool chain. Use it; don't improvise.

  1. **Capture** — drive the local headless Chrome via CDP at `127.0.0.1:9222`. Use the `cdp_capture.sh` helper bundled with the dispatch (or invoke directly): `~/sources/core/apps/platform/priv/scripts/cdp_capture.sh <url> <output.jpg> [--width 375 --height 812]`. The script connects to Chrome's CDP, navigates, waits for network idle, optionally applies an `Emulation.setDeviceMetricsOverride` for mobile viewports, and writes a JPG via `Page.captureScreenshot`. The connectivity check is `curl -s http://127.0.0.1:9222/json/version` returning JSON. For non-browser visuals, fall back to `screen.snapshot`.

  2. **Upload** — call `attachment.upload_start` (reserve a presigned URL), then `curl -X POST --data-binary '@<file>' <upload_url>` with the matching `Content-Type` and your CF-Access headers. The response gives `{id, url}` where `url` is `/chat/attachments/<uuid>` — that's what canvas image nodes accept. Do NOT use `attachment.upload_inline` for anything bigger than ~2 KB; long base64 strings round-trip-corrupt through tool-call envelopes and fail with `data_base64 is not valid base64` (a payload error, not a permissions error — easy to misdiagnose).

  3. **Embed** — call `canvas.create` (or `canvas.patch ["append_child", ...]` on an existing canvas in the execution space) with an `image` node whose `src` is the `/chat/attachments/<uuid>` URL from step 2. Canvas image `src` MUST match `^/chat/attachments/<uuid>$` — external URLs and data URIs are rejected. Group multiple shots in a `stack` of `card`s with markdown captions explaining what's being shown.

  4. **Submit** — call `review_request_create` with `validation_id` set to the `manual_approval` validation (NOT a `validation_evaluate` call — that's only for `test_pass` / `lint_pass`) and `items: [{label, canvas_id}]` pointing at the canvas from step 3. The review items appear inline on the task detail panel with approve/reject buttons. Items can mix `canvas_id` (visual) and `content` (text) — use `content` for tabular evidence, links, test summaries.

  **Do not** post screenshots via `suite_reply_with_media` and call them evidence — those messages don't reliably render in the reviewer's UI and the `manual_approval` gate doesn't watch the chat thread anyway. Evidence flows through `review_request_create`.

  ## Tool-name conventions (dot vs underscore)

  The Suite MCP HTTP endpoint registers tools with dots (`attachment.upload_start`, `canvas.create`, `review_request.create`); the Claude Code MCP wrapper exposes them with underscores (`attachment_upload_start`, `canvas_create`, `review_request_create`). If you fall back to raw curl against `/mcp`, use the dot form or you'll get `not in allowed bundles` (which looks like a permissions denial but is actually a name-lookup miss). When calling via the Claude Code Agent tool's MCP surface, use the underscore form.\
  """

  @doc """
  Return the canonical federation preamble string.

  Injected into every Claude Code `dispatch.*` template body via the
  `{{federation_preamble}}` mustache placeholder. Consolidates the
  subagent-spawn discipline, org memory, skill discovery, evidence workflow,
  and tool-name convention sections that used to be copy-pasted across each
  template. See the module attribute for the section-header contract that
  downstream stack members depend on.

  ## Reading the row, and why the fallback is not optional

  Since task 01a00c99 stage 1 the preamble is ALSO a seeded
  `federation.preamble` row, so it can be edited without a deploy. This
  function prefers that row and falls back to `@federation_preamble` in every
  other case: row missing, `content` `nil`, `content` `""` or whitespace-only,
  or `Repo` raising because the database is unreachable.

  The blank guard is the load-bearing half. An empty preamble strips the
  guidance from roughly fifteen `dispatch.*` templates and NOTHING ERRORS —
  every dispatch still renders, still sends, still looks healthy, and every
  receiving agent silently loses the subagent-spawn, org-memory, skill and
  evidence sections. That invisible failure is what this fallback exists to
  prevent, which is why blank is treated exactly like missing rather than as a
  deliberate "operator emptied the preamble" edit.

  Deliberately NOT routed through `render_template/2`: that returns
  `{:error, :not_found}` for a missing row, and a caller that mishandled it
  would render `""` into every dispatch — the exact invisible failure above. A
  dedicated reader with an explicit non-blank guard makes the degraded case
  impossible to reach by accident.

  `interpolate/2` is deliberately NOT called on the result. The preamble
  carries no placeholders (stage 1 pins `variables: []`), and the outer
  `render_template/2` pass substitutes `{{federation_preamble}}` exactly once —
  interpolating here would be a second pass over a body that has nothing to
  substitute.

  Equivalent to `federation_preamble(%{})` — no assigns means no subject, so
  no experiment can apply.
  """
  @spec federation_preamble() :: String.t()
  def federation_preamble, do: federation_preamble(%{})

  @doc """
  Return the federation preamble for a subject, honouring an experiment
  variant that targets the `federation.preamble` slug.

  `assigns` is the same shape every other render passes — `subject_id/1` reads
  `:task_id` off it and treats a missing key AND the empty string as no
  subject, so a call site with nothing task-scoped to hand may pass `%{}` (or
  call `federation_preamble/0`) rather than fabricating an id.

  The row's content goes through the SAME private `resolve_content/3` that
  `render_template/2` uses, so a variant on this slug wins exactly the way a
  variant wins for `dispatch.planning` — same assignment stickiness, same
  status-blind honouring of an existing assignment, same fall-through-to-live
  posture on any resolution failure.

  The stage-2 fallback ladder is unchanged and wraps this: whatever comes back
  is still blank-guarded against `@federation_preamble`, so a blank variant
  blob can no more strip the preamble from ~15 dispatch templates than a blank
  row can.
  """
  @spec federation_preamble(map()) :: String.t()
  def federation_preamble(assigns) do
    # The rescue mirrors the posture documented on `resolve_content/3`:
    # observational/config machinery must not hold the dispatch lifecycle
    # hostage. A DB hiccup costs an editable preamble, never a dispatch.
    case get_template_by_slug("federation.preamble") do
      %PromptTemplate{content: content} when is_binary(content) ->
        "federation.preamble"
        |> resolve_content(content, assigns)
        |> non_blank_or_default()

      _ ->
        @federation_preamble
    end
  rescue
    _ -> @federation_preamble
  catch
    _kind, _reason -> @federation_preamble
  end

  defp non_blank_or_default(content) when is_binary(content) do
    if String.trim(content) == "", do: @federation_preamble, else: content
  end

  defp non_blank_or_default(_content), do: @federation_preamble

  # Body of the historian dreaming dispatch — extracted so the two seeded
  # slugs (`historian.dreaming` canonical + `memory.dreaming.v1` legacy)
  # share a single source of truth. Any drift between the two would break
  # the byte-identity guarantee tests in
  # `test/platform/orchestration/prompt_templates_test.exs`.
  @dreaming_content """
  {{federation_preamble}}
  You are the Historian in dreaming mode. This is a synthesis + maintenance pass, not a silent write — every durable observation you form belongs in a `<synthesis-proposal>` block on today's journal so Rowan can approve or reject it at `/memory/proposals`. NEVER write directly to page paths from a dreaming run.

  Date: {{date}}
  Workspace: {{workspace_id}}

  ## Activity digest (last 24h)

  {{activity_digest}}

  ## Memory-tool inventory (writes are journal-scoped in dreaming mode)

  You have the standard `memory_*` tool family — `memory_search`, `memory_create`, `memory_str_replace`, `memory_insert`. During a dreaming run the ONLY authorised write target is today's journal path (`org/journal/{{date}}.md`). Page writes (`org/page/...`, `project/<id>/page/...`, `space/<id>/page/...`) happen through the approval pipeline described below.

  When you author wikilinks, ALWAYS use the absolute-link format — never bare basenames. The bare form is the class of hallucination called out in the `feedback_memory_citation` guidance and it is materialised at write time as a `format_dirty` integrity defect that this same dreaming loop then has to repair.

  - Correct:   `[[org/page/foo/bar.md]]`
  - Correct:   `[[project/<workspace-id>/page/decisions.md]]`
  - Incorrect: `[[bar]]`
  - Incorrect: `[[bar.md]]`

  ## Synthesis ops (your primary job this pass)

  Read recent journal entries via `memory_search`, look across the last few days, and emit `<synthesis-proposal>` blocks to today's journal for every durable observation worth surfacing. Each block is one proposal; do NOT batch multiple insights into a single block.

  Block grammar:

  ```
  <synthesis-proposal category="<one of the categories below>" confidence="high|medium|low" evidence="<short pointer(s) to source journal entries / page paths>">
  <body — 1–3 sentences that state the observation as a durable claim Rowan can act on>
  </synthesis-proposal>
  ```

  Supported `category` values (any other value is dropped by the parser):

  - `recurring-theme` — the same topic keeps surfacing across independent contexts (chat + journal + meeting transcripts) and deserves a canonical page section.
  - `cross-project-pattern` — two or more projects are converging on the same abstraction, workflow, or vocabulary. Worth naming so the pattern is reusable.
  - `emerging-risk` — a compounding cost, security exposure, or process fragility that will bite if left implicit. State the risk and the earliest observation of it.
  - `stale-fact-candidate-retirement` — a page (or a section of a page) is materially out of date. Reference the page path in `evidence` and describe what changed.
  - `strategic-insight` — a decision, trade-off, or realisation that shifts direction. Rare. Never invent these — they must be traceable to explicit source material.
  - `unresolved-question` — a genuine open loop that no journal entry answers. Flagging these surfaces them for the next planning pass.

  Every proposal `body` must stand on its own — Rowan reads the /memory/proposals table without loading the source journal, so the body has to make the claim intelligible in isolation. `evidence` is a compact pointer (journal path + line, page path, meeting id) — not a paraphrase of the body.

  ## Maintenance ops (link-integrity repair)

  Run `Platform.Memory.Integrity.scan/1` scoped to the current workspace. The scan returns three buckets — `:broken`, `:format_dirty`, `:retired_target`. For each non-empty bucket, dispatch the corresponding maintenance subagent:

  - `:broken`         → `Platform.Memory.MaintenanceSubagent.spawn_link_repair/1`
  - `:format_dirty`   → `Platform.Memory.MaintenanceSubagent.spawn_format_normalize/1`
  - `:retired_target` → `Platform.Memory.MaintenanceSubagent.spawn_retired_cleanup/1`

  Subagent-per-op discipline is load-bearing: the parent Historian context MUST NOT accumulate per-link diffs. Each subagent takes the bucket entries as input, performs the repair independently, and returns a summary line — the parent only holds the summary. Do not inline the per-entry work into your own context.

  Note: `Platform.Memory.MaintenanceSubagent` ships in a subsequent stage. Until then, treat `scan/1`'s output as the queue-shape the subagents will consume; do not attempt inline edits from the dreaming context.

  ## Promotion protocol (never edit pages directly from a dreaming run)

  Approvals happen at `/memory/proposals`. Rowan reviews each proposal, then either approves (queues the promotion into the target page) or rejects with feedback. Do NOT skip this pipeline — no `memory_str_replace` or `memory_insert` against page paths from a dreaming run.

  ## Rejected proposals from prior runs (calibrate away from these)

  {{rejected_exemplars}}

  {{skills_reference}}\
  """

  defp do_default_templates do
    task_ack_preamble = @task_ack_preamble
    planning_no_ack_notice = @planning_no_ack_notice

    # NOTE (task 01a01041 stage 2): a `skills_reference = "## Skill discovery …"`
    # local used to be built here and never interpolated, which the compiler
    # reported as an unused variable. It was NOT a dropped interpolation — it
    # was a third redundant copy of prose that already lives in two live
    # places, and baking it into the descriptors would have been WRONG twice
    # over:
    #
    #   1. `skills_reference` is a RENDER-TIME variable, not a
    #      definition-time one. Template bodies below carry a literal
    #      `{{skills_reference}}` placeholder and declare `"skills_reference"`
    #      in `variables:`; `Orchestration.HeartbeatScheduler` supplies the
    #      value from its own `@skills_reference` attribute at dispatch time
    #      (heartbeat_scheduler.ex:76, :358, …). Interpolating the local into
    #      the body would have emitted the block TWICE in every rendered
    #      dispatch and broken the tests that assert the stored body still
    #      contains the placeholder (prompt_templates_test.exs:687, :2329).
    #   2. These strings are the seeded DESCRIPTOR a force-update migration
    #      enforces from, so freezing prose into them makes it reappear in a
    #      live prompt later.
    #
    # The same prose also sits verbatim inside `@federation_preamble`
    # (line ~473), which reaches every dispatch through the sibling
    # `{{federation_preamble}}` placeholder. So no template lost its skills
    # section — the dead local was deleted, not renamed.

    [
      %{
        slug: "dispatch.planning",
        name: "Planning Dispatch Prompt",
        description:
          "Sent when a task is first assigned and needs a plan created. " <>
            "Instructs the agent to create and submit a plan before starting work.",
        # No `stage_id` (task 019fa469 stage 5) — a planning dispatch has no
        # plan and therefore no stage, so nothing interpolates it and the
        # body no longer asks for an ack it cannot make.
        variables: [
          "task_id",
          "task_title",
          "task_description",
          "task_priority",
          "provider_specific_guidance",
          "previous_rejection_reason",
          "upstream_plans_section",
          "federation_preamble"
        ],
        content: """
        #{planning_no_ack_notice}
        You have been assigned a task that requires a plan before any implementation begins.

        Task: {{task_title}}
        Description: {{task_description}}
        Priority: {{task_priority}}

        {{provider_specific_guidance}}

        {{previous_rejection_reason}}
        {{upstream_plans_section}}
        Create a plan using the plan_create tool. The plan will be reviewed by a human before work starts — make it specific enough that they can meaningfully approve or reject it.

        ## Stage scope (planner's responsibility)

        Plan **implementation and validation only**. The system auto-injects the deploy stage when the task transitions to `deploying` status — you do NOT include it. Specifically:

        - **Planner** designs implementation stages (`test_pass` + `lint_pass`; never `manual_approval`) and the per-task `e2e_behavior` adversarial test plan.
        - **Implementer** executes each implementation stage.
        - **Review agent** runs the `e2e_behavior` cases at review time.
        - **Deployer** (auto-spawned at `deploying`) opens the PR, polls CI, follows the deploy strategy (`pr_merge` / `docker_deploy` / `skill_driven` / `manual`), and bounces the task back to `in_progress` if CI fails.

        Do NOT include a stage like "Deploy via PR merge", "Open PR", "Watch CI", or "Merge". Those are the deployer's job, not the planner's. The system auto-injects the deploy stage from the resolved deploy strategy when it is needed.

        **Branch handling for implementation stages**
        - Push the branch when implementation stages are complete — do NOT open a PR (the auto-injected deploy stage handles PR + CI + merge)

        A good plan stage must include:
        - A clear name (not just a category label)
        - A description that explains: what specifically will be changed, which files will be modified or created, what the implementation approach is, and why that approach was chosen
        - Appropriate per-stage validations (see "Validation kinds" below)

        Prefer 3-5 stages. Each stage should represent a discrete, reviewable unit of work that lands code or a passed validation. Do not create a stage whose only output is a report, an investigation, or a write-up unless the task title itself asks for one; fold that reading into the stage that acts on it. "Client-side draft persistence" with no further detail is not acceptable — describe the actual change.

        Example of a good stage description:
        "Add a module-level drafts Map to ComposeInput JS hook (assets/js/hooks/compose_input.js). On every input event, store the current textarea value keyed by space_id (read from data-space-id attribute on the element). On mounted(), restore any saved draft and push it to the server via compose_changed event. On compose_reset, delete the draft for that space."

        ## A constraint binds only if you restate it inside a stage description

        The task description above is rendered into THIS dispatch and no other. The execution dispatch and the human-gate (manual_approval) dispatch carry the task TITLE, the stage position and name, and that stage's own `description` — they do not carry the ticket body you are reading now. So anything in this ticket that must bind the implementer has to be restated inside the relevant stage's `description`, because that is the only authored text the implementer is sent.

        Restate it in checkable form — name the file path, name the assertion, and say what failure looks like. "Follow the ticket's testing guidance" survives this boundary as nothing at all. "In apps/platform/test/platform/orchestration/foo_test.exs, assert the sentinel literal, not `stage.description` — an expectation re-derived from the function under test cannot fail for any value" survives as an instruction the implementer can act on and a reviewer can check.

        The constraints that most often need restating, because they are written to bind the coder rather than you:
        - **What NOT to do** — approaches already ruled out, and why they were ruled out.
        - **What is out of scope** — the adjacent code the implementer must leave alone.
        - **Mutation / anti-vacuity requirements** — which mutation to make, that the guard must be shown to fire, and that a non-detonation is a finding to report rather than something to quietly fix.
        - **Any premise you verified while planning**, stated as verified with the file and line you checked, so the implementer does not re-litigate it or silently work around it.

        This rule applies to itself: a planner that reads it and does not restate the ticket's binding constraints inside its stage descriptions has already lost them.

        ## Validation kinds

        Per-stage validations (attach to the implementation stage they protect):
        - `test_pass` and `lint_pass` for any stage that touches code.
        - `manual_approval` is NOT to be created by planners under any circumstance — a human gate blocks throughput until someone clicks, and no stage is worth that. UI-rendering stages (the stage modifies one of: `.heex` templates, `assets/js/`, `assets/css/`, `app.css`, `compose_input`, `chat_live`, `tasks_live.ex`, `_web/live/`, or `_web/components/`) instead get an instruction in their stage description telling the executor to post a screenshot canvas into the execution space as evidence when that stage is reached — with NO validation attached to it. Backend / DB / refactor stages carry no screenshot instruction.

        Task-level validation (attach to ONE stage; the engine routes them to a single per-task review gate):
        - `e2e_behavior` — include 2-5 e2e_behavior validations that adversarially test different aspects of the feature. Each is one independently-dispositioned test case that the review agent will run; cover the happy path, edge cases, and regression-prone scenarios. The user reviews and approves this test plan at plan time, so be specific. Each carries an `evaluation_payload` map with these keys (all required, all strings):
          - `setup`: how the review agent should prepare the dev environment (fixtures, seeds, etc.)
          - `actions`: the concrete steps to perform against the running feature
          - `expected`: the observable behavior that constitutes success
        - Do NOT include a `failure_feedback` field — the actual failure observation IS the feedback (the review agent posts what it expected vs what it actually saw on a failed verdict). Pre-writing failures at plan time is wrong because you cannot predict them.
        - The plan engine lifts every e2e_behavior validation to a single synthetic task-level review stage automatically — do NOT attach them to multiple stages and do NOT create a manual review stage just for them.

        Worked e2e_behavior payload examples (for a "task dependency blocker UI" task — show two adversarial cases side-by-side):

        Case A — happy path:
        ```
        {
          "kind": "e2e_behavior",
          "evaluation_payload": {
            "setup": "Create two tasks A and B in the same project; mark task B as depending on task A (kind: blocks).",
            "actions": "Open task B in the detail panel and look at the Dependencies section. Then mark task A as done via task_complete and refresh task B.",
            "expected": "Before completion, task B's panel shows task A under 'Blocked by' with an unmet badge. After task A completes, task B's panel removes the unmet badge and the task transitions out of 'blocked' status within 2 seconds."
          }
        }
        ```

        Case B — regression-prone edge case (cycle / multi-dep):
        ```
        {
          "kind": "e2e_behavior",
          "evaluation_payload": {
            "setup": "Create three tasks A, B, C; mark B depending on A and C; mark A depending on a non-existent UUID.",
            "actions": "Open task B's detail panel; complete only task C; refresh.",
            "expected": "Task B's 'Blocked by' list shows two entries (A unmet, C met). After completing C, only A remains unmet; B does not auto-transition out of blocked because A is still pending. The orphan-dep on A renders with a nil title fallback rather than crashing."
          }
        }
        ```

        Forbidden:
        - `code_review` is NOT a supported validation kind — do not include it.
        - Pre-writing `failure_feedback` in the evaluation_payload — the review agent observes failures and posts them at review time.
        - `manual_approval` validations of any kind — on any stage, UI or not. A human gate blocks throughput; UI evidence is a screenshot canvas posted by the executor, never a validation.

        ## Design involvement (UI/UX tasks) — decide at plan time

        First decide: does this task touch UI/UX? It does if ANY of:
        - a planned stage would modify UI files (the same token list as the screenshot-evidence rule under "Validation kinds" above), OR
        - the task title/description concerns screens, layout, styling, navigation, user-visible copy, or user flows, OR
        - the task would change how any feature **looks, feels, moves, or is interacted with** (catch-all — catches motion, copy, and interaction changes that touch no styling file).

        If it does NOT touch UI/UX: skip this section entirely.

        If it DOES:

        1. **Brand context is already resolved — you do not resolve it and you do not escalate.** The pre-plan design step resolves brand through `Platform.Design.Brand` (project settings, then org identity, then any recorded project decision, with a once-per-project human ask when nothing exists) before this dispatch is sent. Do not re-ask for a brand identity and do not add a stage that asks.

        2. **Design runs BEFORE planning as a responsibility dispatch (ADR-0046) — do not plan it.** If a design direction canvas is attached to this task, read it with `canvas_get` and let it constrain the UI stages you write. Do NOT author a "Design direction" stage and do NOT set `responsibility` on any stage. If no canvas is attached, the design step recorded `not_applicable` or `failed` — proceed and do not wait for one.

        3. **Reference the resolved brand identity in implementation stage descriptions** — name the semantic token slots the coder must use (primary/on-primary, accent, surface, muted, border, destructive), not raw hex and not "match the brand". If the project is in exploring mode, say so in the stage description instead.

        4. Keep the screenshot-canvas evidence instruction on UI-rendering stages (no `manual_approval` — planners never create one); the design stage is additive, not a replacement.

        Submit the plan with plan_submit when complete. Do not begin implementation until the plan is approved.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project (name, repo_url, tech_stack), epic (name, description, acceptance_criteria), task metadata, current plan with stages, and execution_space_id. Use it for full context when writing your plan.

        {{federation_preamble}}
        """
      },
      %{
        slug: "dispatch.in_progress",
        name: "In-Progress Dispatch Prompt",
        description:
          "Sent when a task is in_progress with an approved plan. " <>
            "Instructs the agent to execute the current stage and push evidence.",
        variables: [
          "task_id",
          "stage_id",
          "task_title",
          "stage_info",
          "stage_description",
          "migration_slot_section",
          "git_workflow_block",
          "provider_specific_guidance",
          "federation_preamble"
        ],
        content: """
        #{task_ack_preamble}
        Plan approved — execute the current stage.

        Task: {{task_title}}
        {{stage_info}}
        {{stage_description}}
        {{provider_specific_guidance}}

        Push evidence using validation_pass or stage_complete as you finish each step. Post commentary to the execution space so reviewers can follow along. Use report_blocker if you are stuck.
        {{migration_slot_section}}
        {{git_workflow_block}}
        The Stage Description block above is your specification — it is the planner's own authored text for this stage, and it is the authority over any summary of it. The full task hierarchy (project, epic, task body, whole plan) is NOT in this message; fetch it with suite_task_get / suite_plan_get if you need it.
        Start from that stage description and any attached/bundled skill content before re-fetching broad task/project context.
        Avoid redundant task/plan lookup churn on the first turn — but if the Stage Description block is absent, empty, or looks cut off, call suite_plan_get and read the stage description there before doing anything else.

        {{federation_preamble}}
        """
      },
      %{
        slug: "historian.scheduled",
        name: "Historian Scheduled Dispatch Prompt",
        description:
          "Sent to the Historian agent on every-6h staggered anchor fires " <>
            "from SystemEventScheduler. Curates durable knowledge from " <>
            "recent journal entries into wiki pages.",
        variables: [
          "workspace_id",
          "pending_tokens",
          "activity_digest",
          "date",
          "deleted_paths_notice"
        ],
        content: """
        You are the Historian. Curate pages under `org/page/`, `project/<id>/page/`, and `space/<id>/page/`.

        Date: {{date}}
        Workspace: {{workspace_id}}
        Pending tokens (rough): {{pending_tokens}}

        ## Activity digest (last 24h)

        {{activity_digest}}

        ## Intentionally deleted paths

        Do NOT re-create these; treat broken links to them as a signal to clean up the referring page, not to restore the target:

        {{deleted_paths_notice}}

        ## Wiki-first writing contract

        Pages under `org/page/`, `project/<id>/page/`, and `space/<id>/page/` are the durable wiki — the canonical long-term knowledge store. Journal entries under `org/journal/<date>.md`, `project/<id>/journal/<date>.md`, and `space/<id>/journal/<date>.md` are append-only, short-lived raw observations.

        Your job is **promotion**: read recent journal entries via `memory_search`, then promote durable knowledge into pages with `memory_str_replace` / `memory_insert`. Only the Historian role can write to page paths — every other agent appends correction blocks to the journal and waits for your digest pass.

        - **NEVER** write durable knowledge to journal paths — journal is append-only and short-lived. Use `memory_create` only against journal paths (and only when you have a transient observation worth recording for the next digest).
        - **Always** prefer `memory_str_replace` / `memory_insert` against an existing page over creating a new one. Pages should accrete, not fragment.
        - Apply `<correction target="<page-path>" line="<N>">…</correction>` blocks from non-Historian agents during your digest pass — they are page edits proposed via the journal.
        - Be selective: only promote genuinely new insights and preserve existing content that is still relevant.

        Do NOT write no-op acknowledgement entries — no "backlog drained", "no new entries", or "wiki current" one-liners against today's journal. Only genuine curation work justifies a journal write; if you performed none this pass, RETURN SILENTLY. The historian cursor advances via `Historian.mark_run_started/1` in the dispatch pipeline regardless of whether you write anything.

        {{skills_reference}}\
        """
      },
      %{
        slug: "historian.dreaming",
        name: "Historian Dreaming-Mode Dispatch Prompt",
        description:
          "Sent to the Historian in dreaming mode — a synthesis + " <>
            "maintenance pass that emits `<synthesis-proposal>` blocks to " <>
            "today's journal (surfaced at /memory/proposals) and dispatches " <>
            "per-bucket MaintenanceSubagent fan-outs for link-integrity " <>
            "repair. Canonical slug; `memory.dreaming.v1` seeds the same " <>
            "body under the legacy responsibility-router lookup key.",
        variables: [
          "federation_preamble",
          "date",
          "workspace_id",
          "activity_digest",
          "rejected_exemplars",
          "skills_reference"
        ],
        content: @dreaming_content
      },
      %{
        slug: "memory.dreaming.v1",
        name: "Memory Dreaming Dispatch Prompt (legacy slug)",
        description:
          "Legacy slug retained for `Platform.Responsibilities.Handlers.Dreaming`'s " <>
            "`default_prompt_template` lookup. Body is byte-identical to " <>
            "`historian.dreaming` — the two slugs share a single source of truth " <>
            "so an edit to the dreaming template cannot drift between the router " <>
            "and legacy-responsibility dispatch paths.",
        variables: [
          "federation_preamble",
          "date",
          "workspace_id",
          "activity_digest",
          "rejected_exemplars",
          "skills_reference"
        ],
        content: @dreaming_content
      },
      %{
        slug: "memory.daily_summary.v1",
        name: "Memory Daily Summary Dispatch Prompt",
        description:
          "Looked up by `Platform.Responsibilities.Handlers.DailySummary.register/0` " <>
            "as its `default_prompt_template` for the 23:00 UTC `per_org` cron fire. " <>
            "Not an alias of `historian.scheduled`: that body is a PAGE-CURATION " <>
            "prompt over `activity_digest` / `pending_tokens` / `deleted_paths_notice`, " <>
            "none of which this handler's `gather_context/2` supplies, and it asks for " <>
            "wiki edits from a handler whose `output_contract` accepts only " <>
            "`%{\"summary\" => string}` and appends the result as a journal entry.",
        # EVERY name here is supplied by `Handlers.DailySummary.gather_context/2`
        # and survives `Router.template_assigns/1`. That is a constraint, not a
        # preference: `interpolate/2` substitutes "" for an assign nobody
        # supplied, so a variable the context never carries renders as a hole
        # that reads like content — the exact defect this template exists to
        # close. `date` and `workspace_id` were added to the handler's returned
        # context in the same commit rather than declared hopefully here.
        variables: [
          "recent_journal",
          "org_identity",
          "date",
          "workspace_id"
        ],
        content: """
        You are writing the organisation's daily summary for {{date}}.

        Workspace: {{workspace_id}}

        ## Who this organisation is

        {{org_identity}}

        ## The record for {{date}}

        The journal entries below are THE record you are summarising. They are the only source you may draw on. Do not supplement them from recollection, from earlier days, or from anything you believe happened but cannot point at in this text — you did not observe the day, you are reading it.

        {{recent_journal}}

        ## If the record above is empty

        If the section above is empty, blank, or carries no journal entries, RETURN NO SUMMARY. Reply with exactly `{"summary": ""}` and stop. The handler declines an empty summary and appends nothing, which is the correct outcome for a day with no record.

        Do NOT compose a plausible day from recollection to fill the gap. A summary invented to avoid returning nothing enters org memory indistinguishable from one drawn from real entries, and every later reader — human and agent — will treat it as observed fact.

        ## Output contract

        Reply with a single JSON object:

            {"summary": "<the day's summary as prose>"}

        `summary` must be a string. Any other shape is rejected by
        `Handlers.DailySummary.handle_output/3` and nothing is written.

        Keep it concrete: what shipped, what broke, what was decided, who was involved. Name things the entries name. Do not editorialise about momentum or mood.\
        """
      },
      %{
        slug: "historian.meeting_ended",
        name: "Historian Meeting-Ended Dispatch Prompt",
        description:
          "Sent to the Historian agent when a meeting transitions to ended " <>
            "(via MeetingHistorianHandler). Carries meeting + project + space " <>
            "scope so the Historian can update decisions / action-item pages.",
        variables: [
          "meeting_id",
          "project_id",
          "chat_space_id",
          "meeting_summary"
        ],
        content: """
        A meeting just ended. Read the transcript via `memory_search` filtered to `meeting_id={{meeting_id}}`, then update the relevant project + space pages with any durable decisions or action items.

        Meeting: {{meeting_id}}
        Project: {{project_id}}
        Chat space: {{chat_space_id}}

        ## Summary (provisional — verify against the transcript)

        {{meeting_summary}}

        ## What to do

        1. Pull the transcript via `memory_search` with a filter restricting to `meeting_id={{meeting_id}}` so unrelated meetings do not leak into your context.
        2. Update `project/{{project_id}}/page/decisions.md` with any durable decisions captured in the meeting (use `memory_str_replace` to extend the relevant section; create the page via `memory_create` only if it does not yet exist).
        3. Update `space/{{chat_space_id}}/page/notes.md` with any action items or follow-ups specific to this chat space.
        4. Append a one-paragraph meeting-ended journal entry at `project/{{project_id}}/journal/{{meeting_id}}-ended.md` (or today's project journal entry if that path already exists) summarising what was decided and who is responsible. Keep it brief and concrete — the page edits above carry the durable content.

        ## Wiki-first writing contract

        Pages are the durable wiki. Journal is append-only. Promote into pages; never write durable knowledge to journal paths. Apply pending `<correction target=...>` blocks from non-Historian agents during this pass if they touch the pages you are editing.

        Do NOT write no-op acknowledgement entries. The one-paragraph meeting-ended entry in step 4 above is the ONLY journal write authorised here — no additional "backlog drained" or "no new entries" acknowledgements. Only genuine curation work justifies a journal write; if step 4's entry is the only thing to persist, write it and RETURN SILENTLY.

        {{skills_reference}}\
        """
      },
      %{
        slug: "historian.threshold",
        name: "Historian 100k-Token Threshold Dispatch Prompt",
        description:
          "Sent to the Historian agent when pending unindexed content for a " <>
            "workspace crosses the configured threshold (default 100k tokens). " <>
            "Drains the backlog into pages via per-window chunked dispatch " <>
            "(task 019f4f55) — one dispatch per corpus window with the " <>
            "windowed activity digest inlined below.",
        variables: [
          "workspace_id",
          "pending_tokens",
          "activity_digest"
        ],
        content: """
        Pending unindexed content has crossed the {{pending_tokens}}-token threshold for workspace `{{workspace_id}}`. This is one dispatch of a chunked pass — the digest below covers a bounded window; subsequent dispatches will cover adjacent windows so the local-model context stays digestible.

        {{activity_digest}}

        ## What to do

        1. Walk the pending journal entries via `memory_search` scoped to this workspace, starting from the oldest unindexed entry.
        2. Consolidate them into the relevant pages — `org/page/...` for org-wide knowledge, `project/<id>/page/...` for project-scoped, `space/<id>/page/...` for chat-scoped. Use `memory_str_replace` / `memory_insert` to extend existing pages; create new ones with `memory_create` only when no relevant page exists.
        3. Apply any pending `<correction target="<page-path>" line="<N>">…</correction>` blocks from non-Historian agents that you encounter in the journal — they are page edits proposed via the journal.
        4. If the backlog is empty or you performed no curation this pass, RETURN SILENTLY. Do NOT write a "backlog drained", "no new entries", or acknowledgement journal entry — those pollute the corpus and re-trigger this dispatch. The historian cursor advances via `Historian.mark_run_started/1` in the dispatch pipeline regardless of whether you write anything.

        ## Wiki-first writing contract

        Pages are the durable wiki — promote into them. Journal is append-only and short-lived — never write durable knowledge to journal paths. This dispatch is a backlog-drain pass; be thorough but selective, and preserve existing page content that is still relevant.

        Do NOT write no-op acknowledgement entries. Only genuine curation work justifies a journal write; if you performed none, RETURN SILENTLY.

        {{skills_reference}}\
        """
      },
      %{
        slug: "dispatch.in_review",
        name: "In-Review Dispatch Prompt (manual_approval / UI judgment)",
        description:
          "Sent when a task is in_review and the pending validation is `manual_approval`. " <>
            "Behavioral validation (`e2e_behavior`) is handled by the dedicated " <>
            "`dispatch.review_e2e` template instead.",
        variables: [
          "task_id",
          "stage_id",
          "task_title",
          "stage_info",
          "stage_description",
          "provider_specific_guidance",
          "federation_preamble"
        ],
        content: """
        #{task_ack_preamble}
        Task is in review — produce a human-judgment review request for the UI / manual_approval gate.

        Task: {{task_title}}
        {{stage_info}}
        {{stage_description}}
        {{provider_specific_guidance}}

        This prompt covers UI judgment (`manual_approval`) only. Behavioral end-to-end review is
        dispatched separately under its own template — if the pending review validation is not
        `manual_approval`, the dispatcher routes elsewhere.

        Your job: capture concrete UI evidence and surface the human gate. Tests and lint were already
        validated during execution — do not re-check them here.

        ## How to review (UI judgment)
        - Start a local dev server for the worktree (reference the dev server skill via attached skills if available)
        - Navigate to the relevant pages, take screenshots, verify visual correctness and interaction behavior
        - Post screenshots, canvas snapshots, or other concrete evidence into the execution space

        ## Design review (Saru) — before the human gate
        If the task changed UI files (the same token list as the planner's manual_approval rule: `.heex`, `assets/js/`, `assets/css/`, `app.css`, `compose_input`, `chat_live`, `tasks_live.ex`, `_web/live/`, `_web/components/`), obtain Saru's design review (the Designer role's design.critique responsibility) on your captured screenshots BEFORE creating the human review request. Call the `suite_design_critique_request` tool with the `canvas_id` of the evidence canvas holding those screenshots, the `review_request_id` once you have one (the tool then appends the verdict to that pending request itself), and the `task_id`. The tool returns the verdict SYNCHRONOUSLY — include Saru's verdict and issue list as labelled checklist items in the review request. Saru's review is advisory evidence for the human gate — it never replaces human approval, and if the design review cannot be obtained promptly (the tool returns an error, e.g. the Designer role is unfilled), create the review request anyway and note that design review is missing.

        ## First-turn rule (CRITICAL)
        - Do NOT spend your first substantive turn re-discovering broad task/plan state if the dispatch already provides `Current task_id`, `Current stage_id`, `validation_id`, and `execution_space_id`.
        - Your first substantive turn should do the real review work and then create the human gate:
          1. exercise the UI in a running environment,
          2. publish concrete evidence into the execution space,
          3. call `suite_review_request_create` for the provided `validation_id` with labelled checklist items and links to that evidence.
        - Only call `suite_task_get`, `suite_plan_get`, or `suite_validation_list` if an identifier is actually missing or the dispatch context is contradicted by direct evidence — but if the Stage Description block above is absent, empty, or looks cut off, call `suite_plan_get` and read the stage description there before judging anything.
        - Reach the evidence + review-request step in the same attempt unless a real blocker prevents it.

        ## Review rules
        - Use `suite_review_request_create` for `manual_approval` validations — include labelled checklist items plus screenshots/canvas/evidence links.
        - Do NOT call `suite_stage_complete` before the required review request and evidence have been created.
        - Do NOT self-approve `manual_approval` validations.
        - Do NOT call `suite_task_update` for lifecycle status changes — review outcomes flow through validations and review requests.

        The Stage Description block above is the planner's own authored specification for this stage — judge the implementation against it, not against a summary of it. The full task hierarchy (project, epic, task body, whole plan) is NOT in this message; fetch it with suite_task_get / suite_plan_get if something you need is missing.

        {{federation_preamble}}
        """
      },
      %{
        slug: "dispatch.review_e2e",
        name: "E2E Behavioral Review Dispatch Prompt",
        description:
          "Sent when a task is in_review and one or more pending validations are `e2e_behavior`. " <>
            "Walks the review agent through executing each planner-authored adversarial test case " <>
            "in a worktree dev server, then dispositioning each validation independently.",
        variables: [
          "task_title",
          "pending_e2e_validations_json",
          "execution_space_id",
          "repo_url",
          "task_slug",
          "federation_preamble"
        ],
        content: """
        Task is in behavioral review — execute each planner-authored e2e_behavior test case and disposition each validation independently.

        Task: {{task_title}}
        Execution space: {{execution_space_id}}
        Repository: {{repo_url}}
        Task slug: {{task_slug}}

        ## What is e2e_behavior

        The planner authored an adversarial test plan (a list of `e2e_behavior` validations) describing
        what user-visible behavior must hold for this task to be considered done. Each validation is one
        independently-dispositioned test case. Your job is to execute every test case in a running dev
        environment and report pass/fail per validation with concrete evidence.

        ## Pending e2e_behavior validations (pre-rendered as JSON)

        You have one or more pending e2e_behavior validations on this task. Each entry below carries a
        `validation_id` and an `evaluation_payload`. Run each one in turn.

        ```
        {{pending_e2e_validations_json}}
        ```

        Each `evaluation_payload` contains three fields:
        - `setup`: prepare the dev environment (fixtures, seeds, etc.)
        - `actions`: concrete steps to perform against the running feature
        - `expected`: the observable behavior that constitutes success

        There is no planner-supplied `failure_feedback` — on a failed verdict, you (the review agent) compose the
        feedback yourself from what you actually observed. That is the failure_feedback.

        ## How to review

        1. Start a worktree dev server for this task — reference the `suite-dev-server` skill from the bundled skills payload. The skill explains hive-only constraints and DB seeding.
        2. For each pending validation in the list above:
           a. Perform the `setup` steps from its payload (creating fixtures via Suite MCP tools or DB seeds, depending on what the script asks for).
           b. Perform the `actions` against the running feature.
           c. Compare the observed behavior to `expected`.
           d. Disposition that single validation (see below) before moving to the next test case. Failures on one validation do NOT short-circuit the rest — run them all.

        ## Which build answers the call

        Before exercising any MCP tool, HTTP endpoint or LiveView as part of a case, establish which build
        serves it. The live gateway and the org's hosted MCP endpoint run `main`, not this task's branch, so
        calling your own `task_update` / `canvas_create` / etc. exercises production and will return a
        failure verdict on working branch code (or a pass on code that is not there). Drive the branch
        instead: the worktree dev server, or the same entry point the endpoint dispatches to
        (`Platform.Federation.ToolSurface.execute/3` for MCP tools) against a private dev database.
        Record in the evidence which build was exercised and at which sha.

        Before recording ANY verdict on a case driven through a browser, print the final URL and the page
        title of the tab you measured, and put both in the evidence map (`final_url`, `page_title`). A final
        URL on the identity provider, or a title such as "Sign in", means you measured the login screen and
        not the feature: that case is `could_not_evaluate` with the reason "no authenticated session", never a
        pass and never a plain fail. Neither agent-reachable headless Chrome (rock, hive) holds a production
        session, and production runs `main` rather than this branch in any case, so an authenticated browser
        case is measured only against the worktree dev server after you log in there (ticket 01a0918b-dc68).

        A parameter is proven read only when its value flips an outcome. An `expected` clause of the form
        "the call also succeeds" is satisfied by an implementation that ignores the parameter, so add the
        discriminating half (a stale or invalid value that must be refused) and report both.

        An `expected` clause that is an absence (no row, empty list, nothing rendered) counts only after a
        positive control in the same session shows the instrument reads a known-present value.

        ## Disposition (per validation)

        On success — observed behavior matches `expected`:
        - Call `suite_validation_evaluate` with the matching `validation_id`, `status: "passed"`, and
          `evidence: %{observed: "<what you saw>", notes: "<any caveats>"}`.

        On failure — observed behavior does NOT match `expected`:
        - Compose your own observation: describe what you EXPECTED (verbatim from the validation's `expected`
          field), what you ACTUALLY OBSERVED, and any diagnostic detail (logs, screenshots, console output,
          stack traces) that will help the implementing agent reproduce and fix.
        - Call `suite_validation_evaluate` with the matching `validation_id`, `status: "failed"`, and
          `evidence: %{observed: "<what you saw>", expected: "<verbatim from the payload>", diagnostics: "<logs/details>"}`.
        - Post that same observation into the execution space ({{execution_space_id}}) so the implementing
          agent reads it on the next dispatch — your observation IS the failure_feedback.

        On COULD NOT EVALUATE — you were unable to run the test case at all (the dev server will not boot, a
        fixture cannot be built, the case hit a known flake), as distinct from running it and seeing the wrong
        behaviour:
        - Call `suite_validation_evaluate` with the matching `validation_id`, `status: "failed"`, and an
          `evidence` map carrying `disposition: "could_not_evaluate"` AND a non-blank `reason` explaining what
          stopped you: `evidence: %{disposition: "could_not_evaluate", reason: "<what blocked the run>",
          diagnostics: "<logs/details>"}`.
        - This raises a blocker and does NOT spend one of the task's three review rounds. A failed verdict
          without that marker DOES spend a round, and after three the task is returned to PLANNING and its
          plan superseded — so a broken environment reported as a plain failure re-plans a feature that was
          never wrong.
        - The `reason` is mandatory. A `could_not_evaluate` marker with no reason is counted as a genuine
          failure.
        - Use it ONLY when the run was impossible. "The feature looks wrong" is a plain failed verdict.

        ## Forbidden

        - Do NOT call `task_update` to bounce the task status. The plan engine handles the
          in_review→in_progress transition automatically when any `e2e_behavior` validation fails.
        - Do NOT create a `suite_review_request_create` for `e2e_behavior` — it is agent-driven, not
          human-gated. Review requests are reserved for `manual_approval` validations.
        - Do NOT self-approve. Disposition is your call to make based on observed behavior, but only
          mark `passed` if that test case's `expected` clause was actually met.
        - Do NOT skip validations. Run every pending e2e_behavior test case even if an earlier one failed.

        The attention signal that delivered this message includes a `context` field with the full task
        hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id.

        {{federation_preamble}}
        """
      },
      %{
        slug: "dispatch.deploying",
        name: "Deploying Dispatch Prompt",
        description:
          "Sent when a task is in deploying status with a running deploy stage. " <>
            "Instructs the agent to execute the deploy based on the resolved strategy.",
        variables: [
          "task_id",
          "stage_id",
          "task_title",
          "stage_info",
          "repo_url",
          "default_branch",
          "task_slug",
          # task 019fa63a stage 5 — the RESOLVED strategy's instructions, which
          # for `pr_merge` is one PR/CI/merge sequence per resolved repository.
          #
          # ADDED ALONGSIDE `repo_url` / `default_branch` rather than replacing
          # them. Both singular assigns now resolve from the same repo set
          # (`repo_url` is the PRIMARY entry), so this is one source of truth
          # with two renderings — and a template row an operator customized to
          # interpolate `{{repo_url}}` keeps working, and now names the right
          # repository. Deleting the singular assigns would have blanked those
          # rows silently: `interpolate/2` resolves an unknown placeholder to
          # `""`, so the failure would be missing text, not an error.
          #
          # It also collapses a divergence: the body used to carry a STATIC
          # four-line summary of every strategy while the hardcoded fallback
          # rendered only the resolved one. Two texts, one of which was never
          # updated when a strategy changed.
          #
          # Requires the force-update migration
          # `20260731120000_add_deploy_strategy_instructions_to_dispatch_deploying`
          # — `seed_defaults/0` is INSERT-only, so editing this body alone
          # leaves every already-seeded environment rendering the old text
          # forever.
          #
          # Task 019fb949 note. This task added a `legacy_branch_prefix`
          # variable here so the body's static `pr_merge` line could offer the
          # transitional `ls-remote` branch-recovery step. That variable is
          # deliberately NOT carried forward: 019fa63a deleted the static line
          # it was written for, and the recovery step now renders from
          # `HeartbeatScheduler.deploy_strategy_instructions/5` — once per
          # resolved repository, which is where it belongs, because
          # `git ls-remote` is run in ONE repository's clone and a two-repo task
          # can have the legacy ref in one and not the other. A declared
          # variable the body never interpolates would show up in the admin
          # variables sidebar as a contract this template does not keep.
          "deploy_strategy_instructions",
          "deploy_strategy_type",
          "deploy_strategy_config",
          "federation_preamble"
        ],
        content: """
        #{task_ack_preamble}
        Task is deploying — execute the deploy stage based on the resolved strategy.

        Task: {{task_title}}
        {{stage_info}}Deploy strategy: **{{deploy_strategy_type}}**
        Strategy config: {{deploy_strategy_config}}

        ### Strategy-specific instructions

        {{deploy_strategy_instructions}}

        ### Merge mechanics on Startup-Suite/core (overrides any "auto-merge is enabled" line above)
        - `auto_merge: true` in the strategy config is a declaration, not an action. Nothing arms GitHub auto-merge except an explicit `gh pr merge <n> --auto`. Arming is safe on this repository ONLY while `main`'s required status checks include BOTH `Test` and `first-run-green` (added 2026-09-11; `first-run-green` is what makes a failed-then-retried `Test` run block the merge, ticket 01a08d81). Verify before arming, every time: `gh api repos/Startup-Suite/core/branches/main/protection/required_status_checks --jq .contexts` must print both. If it does, arm with `gh pr merge <n> --auto --squash --delete-branch` and still watch CI to conclusion. If `first-run-green` is missing from the contexts, do NOT arm: wait for CI in the foreground, read the annotations for the retry sentinel, and merge by hand.
        - Wait for CI in the foreground: `gh run watch <run-id> --exit-status` (or `gh pr checks <n> --watch`). Never end your turn "waiting on CI"; an ended turn is a dead deployer.
        - Before merging (or before reporting an armed merge as clean), read the run's ANNOTATIONS (not a whole-log grep) for `initial mix test failed`. If it fired, name the tests the retry greened. Known flakes (ProofOfLifeTest, LocalRunnerTest force_stop, SandboxHelpersScopedDrainTest, conn_case_supervised_orphan_test) may be merged past with the names recorded in the PR body; anything else is a red run and goes back to the ONE rule below.
        - Verify the merge as a field, not an exit code: `gh pr view <n> --json mergedAt,mergeCommit --jq '.mergedAt'` must print a timestamp. `mergeStateStatus: BLOCKED` while checks are pending is normal; it matters only if it survives a `success` conclusion. Confirm the remote branch is gone afterwards; the per-repository steps above say how.
        - The squash commit does not carry the PR body; anything that must survive in `git log` goes in a commit message.

        ### Deploy boundaries
        - If CI fails on the deploy branch, there is ONE rule. Read the failing job log first. If the failure is inside this task's own diff, or it is a flaky test with a documented retry (an existing retry step, a known-flake note in org memory, or an identical pass on re-run), fix forward on the same task branch (the one named below): make the smallest change that turns it green, push, and wait for CI to go green, then continue the merge. Do not touch code outside the task's diff. Only if the failure needs a plan change (the fix would add scope, change a design decision, or touch files no stage in the plan owns) call `task_update` with status `in_progress` and a comment naming the failing job and why a plan change is needed; that is what returns the task to the implementer. Do NOT file `report_blocker` for a red CI: a blocker does not move the task out of `deploying`, and the task stays wedged.
        - Do NOT re-run tests or lint locally — CI handles that
        - Branch `task/{{task_slug}}` is already pushed from execution; your job is to get it merged and deployed

        Push evidence using validation_pass as you complete each deploy step.
        Use report_blocker only when the deploy itself cannot proceed for a reason outside your reach (a missing repository, a protected branch you cannot merge, a webhook that never fires), and follow the blocker discipline in the preamble below.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.

        {{federation_preamble}}\
        """
      },
      %{
        slug: "dispatch.scribe_completion",
        name: "Scribe Completion Dispatch Prompt",
        description:
          "Sent to the scribe agent on `meeting_scribe_completion` attention signals. " <>
            "Instructs the scribe to produce a 5-card meeting summary canvas " <>
            "(Summary / Decisions / Action items / Open questions / Provenance) in " <>
            "the meeting's chat space and hand structured action items off to the " <>
            "triage agent via `dispatch_triage_attention/2`. Codifies the SXI scribe " <>
            "canvas structure proven on the 2026-07-13 meeting.",
        variables: [
          "space_id",
          "room_id",
          "transcript_id",
          "meeting_name",
          "execution_space_id",
          "federation_preamble",
          "skills_reference"
        ],
        content: """
        #{task_ack_preamble}
        {{federation_preamble}}

        Meeting `{{meeting_name}}` just ended — produce the 5-card scribe completion canvas.

        ## Signal payload — read these from the attention signal

        - `space_id={{space_id}}` — the meeting's chat space; create the canvas here.
        - `room_id={{room_id}}` — the LiveKit room the meeting occupied.
        - `transcript_id={{transcript_id}}` — durable transcript reference for `memory_search` filters.
        - `execution_space_id={{execution_space_id}}` — your working space for evidence + status updates.

        Fetch meeting + transcript context via `space_get_context` on `{{space_id}}` and direct
        Meetings context reads keyed by `{{transcript_id}}`. Filter `memory_search` calls with
        `transcript_id={{transcript_id}}` so other meetings' content does not leak into your canvas.

        ## Deliverable — ONE canvas in `space_id={{space_id}}` with five cards

        Emit the canvas via a single `canvas_create` call rooted at a `stack` containing five `card`
        nodes in the order below. Do NOT split into multiple canvases. Use `heading` + `markdown` nodes
        inside cards for prose, and a `checklist` node for the action-items card.

        ### Card 1 — Summary

        Meeting metadata + a two-to-four sentence narrative. Include:

        - Meeting name (`{{meeting_name}}`), date, wall-clock duration.
        - Participant list (resolved `user:*` identities where possible). If any identity is ambiguous
          — e.g. the transcriber heard "Harper" but the participant roster has both `user:harper` and
          `user:saru` on the invite (as on the SXI 2026-07-13 meeting) — flag it inline: "attributed
          to Harper/Saru — transcriber cannot disambiguate".
        - Transcript stats: rough turn count, total words (from the transcript summary if available).
        - Mishearing corrections applied — always call out "Cozoa" → "Fabrikam" and "sweet.cozoa.ai.com"
          → "suite.example.com" if you saw either token in the raw transcript. Note any other
          org-specific corrections applied.

        ### Card 2 — Decisions

        Bulleted list. One decision per bullet in the form:

        `**<decision in one sentence>** — decided by <owner>; "<load-bearing quote from transcript>"`

        Prefer quotes short enough to sit inline (under 200 chars). If no clear decision emerged,
        write "No durable decisions recorded this meeting." — do NOT invent decisions to fill the card.

        ### Card 3 — Action items

        Use a `checklist` node whose children are `checklist_item` nodes. For each action item:

        - `label` — human-readable: `<owner>: <action verb + object> <due-hint>`
          Example: `"Rowan: draft the SXI Q3 pricing memo by Friday"`.
        - `note` — **structured JSON** (a stringified JSON object, not prose) with the exact keys
          below. All keys required; use `null` for any field you cannot determine from the transcript.

        JSON schema (copy-paste template — every action item's `note` MUST parse as this shape):

        ```json
        {
          "owner": "user:rowan",
          "project_hint": "sxi-orion",
          "priority": "high",
          "due_hint": "Fri 2026-07-24",
          "source_transcript_id": "{{transcript_id}}"
        }
        ```

        Field semantics:

        - `owner` — canonical `user:<slug>` identity; `null` if unattributed. Do NOT invent slugs.
        - `project_hint` — project slug the item likely belongs to; `null` if unclear.
        - `priority` — one of `"high" | "medium" | "low"`; `null` if the meeting did not signal urgency.
        - `due_hint` — natural-language due date as spoken in the meeting ("Friday", "end of week",
          "next standup"); `null` if no deadline was mentioned.
        - `source_transcript_id` — always the current `{{transcript_id}}` so downstream agents can
          re-anchor the item back to the transcript window.

        The triage agent (dispatched by the post-canvas hook below) reads these `note` payloads to
        create real tasks — malformed JSON here becomes malformed tasks downstream. Validate each
        `note` parses via `Jason.decode/1` locally before you emit the canvas.

        ### Card 4 — Open questions

        One question per line with attribution. Format:

        `- <question in question form?> — raised by <owner>`

        These are things the meeting explicitly flagged as unresolved. Do NOT include rhetorical
        questions from the transcript; only questions the participants agreed needed follow-up.

        ### Card 5 — Provenance

        - `source_transcript_id`: `{{transcript_id}}`
        - `room_id`: `{{room_id}}`
        - `meeting_length`: <wall-clock, minutes>
        - `corrections_applied`: bullet list of every mishearing you fixed in Card 1 (Cozoa→Fabrikam
          etc.), one bullet each. Empty list explicitly rendered as "- none" if you applied none.
        - `scribe_run_at`: current UTC timestamp.

        ## After canvas_create — dispatch the triage agent

        Once `canvas_create` returns a `canvas_id`, IMMEDIATELY call
        `Platform.Federation.dispatch_triage_attention/2` (added by stack member C — this template
        only references it; do not try to import or verify existence at plan time) with:

        - the new `canvas_id`, so the triage agent can walk Card 3's `checklist_item.note` payloads.
        - the source signal metadata: `%{transcript_id: "{{transcript_id}}", room_id: "{{room_id}}",
          space_id: "{{space_id}}", meeting_name: "{{meeting_name}}"}`.

        The triage agent picks up the action items and creates real tasks. Without this dispatch the
        action items sit stranded on the canvas.

        ## Guardrails

        - **Do not invent participants.** If a `user:*` identity is ambiguous, flag it in Card 1
          rather than picking one arbitrarily. Downstream tasks routed to the wrong owner are worse
          than tasks routed to `null`.
        - **Do not invent decisions or action items.** An empty Card 2 / Card 3 with an honest
          "nothing recorded" note is preferable to hallucinated content. The triage agent trusts what
          you write.
        - **Do not skip the triage dispatch.** The canvas is not the whole product; the triage hand-off
          is what turns the canvas into tasks.
        - **Preserve mishearing corrections in Card 5.** Auditors need to know what you changed.

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.triage_dispatch",
        name: "Triage Dispatch Prompt (meeting scribe-completion → tasks)",
        description:
          "Sent to the triage-officer runtime when a scribe-completion canvas is " <>
            "posted for a meeting. Consumes the checklist_item `actions` section, " <>
            "files tasks via `Platform.Meetings.Triage.file_tasks_from_canvas/2`, and " <>
            "appends a summary card to the source canvas.",
        variables: [
          "federation_preamble",
          "space_id",
          "room_id",
          "transcript_id",
          "canvas_id",
          "execution_space_id",
          "skills_reference"
        ],
        content: """
        {{federation_preamble}}

        ## Signal context

        You are the triage-officer runtime consuming a `meeting_triage_dispatch` attention signal broadcast by `Platform.Federation.dispatch_triage_attention/2` (stack member C) after the meeting scribe posted a scribe-completion canvas. The signal names five identifiers you will need:

        - `space_id`: `{{space_id}}` — the chat space the meeting lives in.
        - `room_id`: `{{room_id}}` — the meeting room the transcript belongs to.
        - `transcript_id`: `{{transcript_id}}` — the source transcript feeding this triage pass.
        - `canvas_id`: `{{canvas_id}}` — the scribe-completion canvas whose `actions` checklist you consume.
        - `execution_space_id`: `{{execution_space_id}}` — where progress commentary and any error surfacing goes.

        Before you start, call `skill_get` with slug `meeting-triage-officer` for the canonical parse conventions (JSON note keys, jaro-distance threshold, priority map, assignee inference). Do not improvise; the skill is authoritative.

        ## Deliverable steps

        1. **Load the source canvas.** Call `canvas_get` with `canvas_id={{canvas_id}}` to fetch the scribe-completion canvas document.

        2. **Locate the actions checklist.** Walk the canvas node tree and find the section of kind `checklist` whose title / label is `actions`. Iterate its `checklist_item` children — each represents one candidate task.

        3. **Parse the `note` payload.** For every `checklist_item`, the `note` field is a JSON blob with keys `owner`, `project_hint`, `priority`, `due_hint`, and `source_transcript_id`. Parse it with `Jason.decode/1`. If the JSON is malformed (Jason returns an error), fall back to sensible defaults rather than crashing — treat the whole `note` as free-text description, leave `owner`/`project_hint`/`due_hint` as `nil`, default `priority` to `"medium"`, and use `{{transcript_id}}` as the fallback `source_transcript_id`.

        4. **Resolve the target project.** Call `project_list` to get every project the actor can see. Score each project's name against the parsed `project_hint` using `String.jaro_distance/2`. Accept the highest-scoring match if its score is `>= 0.85`; otherwise fall back to the project that owns the source canvas's space (via `space_id → project_id` lookup). Record which branch you took so the summary card can distinguish `filed` from `fallback_project`.

        5. **Hand parsed items to Triage.** Call `Platform.Meetings.Triage.file_tasks_from_canvas/2` with the source canvas and the parsed checklist items (stack member E's surface). Do NOT reimplement the filing loop yourself. Do NOT reimplement the dedup check yourself — Triage.file_tasks_from_canvas/2 calls `Platform.Tasks.similar_open_titles/3` internally and returns a per-item verdict (`{:filed, task_id}` | `{:skipped_dupe, existing_task_id}` | `{:fallback_project, task_id}`) that you reflect in the summary card.

        6. **Append a summary card to the source canvas.** After `file_tasks_from_canvas/2` returns, patch the source canvas by appending a new `card` node containing a `table` with one row per checklist_item. Columns: `title` (from the checklist_item label), `task_id` (the id returned by Triage, or `-` for skipped items with no filed task), and `status` (one of `filed`, `skipped_dupe`, `fallback_project`). Use `canvas_patch` with the `append_child` operation against the canvas root; do NOT rewrite the whole document.

        ## Idempotency

        Do NOT check for pre-existing tasks yourself — `Platform.Meetings.Triage.file_tasks_from_canvas/2` calls `Platform.Tasks.similar_open_titles/3` internally (added by stack member E). Trust its verdict and reflect skipped items in the summary card with `status: skipped_dupe` and the pre-existing `task_id` in the row rather than a freshly-filed one. Re-broadcasting the same `meeting_triage_dispatch` on the same canvas must produce zero new tasks.

        ## Telemetry

        Emit two events during this dispatch so `Platform.Meetings.TelemetryHandler` (added by stack member E) can observe the pass. Do NOT attach a handler yourself — E's handler is already wired.

        - On dispatch entry, after step 2 counts the checklist items, emit `[:platform, :meetings, :triage_dispatch]` with measurements `%{items: N}` (where `N` is the count of `checklist_item` children under the `actions` section) and metadata `%{canvas_id: {{canvas_id}}, transcript_id: {{transcript_id}}}`.
        - After `Platform.Meetings.Triage.file_tasks_from_canvas/2` returns, emit `[:platform, :meetings, :tasks_created_from_meeting]` with measurements `%{filed_count: F, skipped_count: S, fallback_project_count: P}` computed from the per-item verdicts, and metadata `%{canvas_id: {{canvas_id}}, transcript_id: {{transcript_id}}}`.

        ## Failure surfacing

        If any step raises or the runtime cannot continue, post a concise error line into `execution_space_id` `{{execution_space_id}}` naming the step that failed (e.g. "canvas_get returned :not_found for {{canvas_id}}") and re-raise so the router observes the crash. Silent swallow is worse than a crash — the router restart path is the correct recovery.

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.intent_attention",
        name: "Intent Attention Prompt (meeting intent queue → target runtime)",
        description:
          "Sent to a classified target's runtime when a per-meeting intent queue " <>
            "dispatches one live transcript intent (task 019f70b8). Makes the " <>
            "spawn-before-ack ordering non-optional: the runtime spawns a subagent, " <>
            "acks with its id via `intent_ack`, and honours an `intent_cancelled` " <>
            "event addressed to that same subagent.",
        variables: [
          "federation_preamble",
          "intent_id",
          "meeting_id",
          "transcript_chunk_excerpt",
          "classified_intent",
          "target_rationale",
          "target_space_id",
          "execution_space_id",
          "skills_reference"
        ],
        content: """
        {{federation_preamble}}

        ## Signal context

        You are the runtime a Meeting Producer routed one live transcript chunk to. The signal arrived as a `meeting_intent_dispatch` attention broadcast on your own `runtime:<runtime_id>` topic — the same topic you already receive task dispatches on. There is nothing new to subscribe to.

        The meeting's intent queue is **serial and ack-gated**: it holds at most ONE intent per meeting in flight, and the next classified intent does not reach anybody until this one lands a terminal status. Everything behind you is waiting on your ack.

        The signal names the identifiers you need:

        - `intent_id`: `{{intent_id}}` — the handle for every `intent_ack` call below. It resolves the owning meeting for you, so there is no separate meeting argument on the ack.
        - `meeting_id`: `{{meeting_id}}` — the live meeting this chunk came from. The queue is meeting-lifetime: when the meeting ends the queue and this intent are gone, and a late ack returns `{:error, :not_found}`.
        - `transcript_chunk_excerpt`: `{{transcript_chunk_excerpt}}` — the verbatim words that produced this intent. This is the only ground truth about what was actually said.
        - `classified_intent`: `{{classified_intent}}` — the classifier's label for those words. It is a small fast model's guess, not an instruction.
        - `target_rationale`: `{{target_rationale}}` — why the classifier routed this to you rather than to somebody else.
        - `target_space_id`: `{{target_space_id}}` — the meeting's own chat space, and **where your result goes**. You were added to it as a participant before this signal was sent, so `canvas_create` and `message_post` against it will succeed. Read it off the signal as `signal.target_space_id`: the key is NOT `space_id`, because that top-level slot answers pending permission prompts and an intent dispatch must not claim it. If the key is absent the meeting named no space — say so in your ack `note` rather than guessing at another space.
        - `execution_space_id`: `{{execution_space_id}}` — where progress commentary and any error surfacing goes.

        ## Ack contract

        **Your first tool call after spawning the subagent must be `intent_ack(intent_id="<...>", subagent_id="<the id returned when you spawned the subagent>", status: :working)`.**
        Spawn the subagent FIRST, then include its returned agent id in the ack. Empty or missing subagent_id will fail validation.

        For this dispatch `intent_id` is `{{intent_id}}`.

        **Where `subagent_id` comes from depends on your runtime — this is the only place runtime types differ.** Claude Code runtimes pass the Agent-tool `agentId` returned by the spawn call (e.g. `afd767f1e0cc81633`); openclaw runtimes pass the runtime slug of the spawned worker (e.g. `higgins.moon`). Same field, same requirement, different provenance. Every other clause in this template is identical for every runtime.

        The id must identify the ACTUAL subagent doing the work. A cancellation is addressed to it BY NAME (see the Cancellation section below), so a placeholder, a stale handle, or your own runtime id sends the stop signal to the wrong process.

        Four ack statuses, and exactly one of them does NOT advance the queue:

        - `working` — subagent spawned, work underway. **Does NOT advance the queue.** Send it immediately after the spawn.
        - `completed` — the work finished. Advances.
        - `rejected` — this intent is not yours, or is not actionable. Advances, and records a `wrong_target` correction that tunes future classification. An honest early `rejected` is a GOOD outcome: it unblocks the meeting and improves targeting. Guessing at work that is not yours is the bad outcome.
        - `cancel_honored` — you received an `intent_cancelled` event and stopped the subagent. Advances.

        An `intent_ack` whose `subagent_id` is missing, empty, or over 128 bytes is rejected by the schema and leaves the queue row COMPLETELY untouched — a schema-rejected ack is never a partial ack. Those rejected attempts ARE counted: if the intent then times out it is reported as `no_ack_spawn_failed` (you tried and could not spawn) rather than `timed_out` (nothing came back at all). Do not paper over a failed spawn with a fabricated id — `no_ack_spawn_failed` is precisely the signal that tells the producer your runtime's spawn path is broken.

        If no ack of any kind arrives inside the meeting's ack window (default 90s) the intent is timed out and the queue moves on without you. The window is short because a live meeting is short.

        ## Deliverable steps

        1. **Read the excerpt before the label.** `{{transcript_chunk_excerpt}}` is what was said; `{{classified_intent}}` is a guess about it. Where the two disagree, the excerpt wins — and the right answer is usually `rejected`.

        2. **Decide whether this is yours BEFORE spawning.** If it is not, ack `rejected` with a one-line `note` saying why, and stop. You do not need a subagent to decline.

        3. **Spawn the subagent.** Fresh context, briefed with the excerpt, the classified intent, `{{target_rationale}}`, and `{{meeting_id}}`. Capture the id the spawn call returns.

        4. **Ack `working` immediately** — `intent_ack(intent_id="{{intent_id}}", subagent_id="<the id from step 3>", status: "working")`. This is the first tool call after the spawn, not after the work.

        5. **Do the work in the subagent, not in the parent.** For the rest of this intent the parent's only jobs are relaying a cancel and acking the outcome.

        6. **Write the result into `{{target_space_id}}`.** That is the meeting's chat space and the only place the people in the meeting will look for it. Post the message or create the canvas there — not in `{{execution_space_id}}`, which is for progress and errors, and not in a DM. You are already a participant of it; you do not need to ask to be added.

        7. **Ack the outcome and say so.** `intent_ack(..., status: "completed")` when the deliverable lands, and post a one-line summary into `execution_space_id` `{{execution_space_id}}` naming what changed.

        Meeting-speed work is small by construction: one chunk of speech, one adjustment. If what you are being asked for is genuinely multi-stage, file it as a task instead of doing it here and say so in the ack `note`.

        ## Cancellation

        A producer can pull an intent after it has already gone out — that is the entire point of the live queue. When that happens you receive an `intent_cancelled` event on the SAME `runtime:<runtime_id>` topic this dispatch arrived on.

        **Wire shape.** It is a channel event named `intent_cancelled` carrying a MAP payload — not an Elixir tuple. A runtime topic serialises to a websocket, so the payload is always a map. Keys:

        - `intent_id` — which intent is being pulled.
        - `meeting_id` — the meeting it belongs to.
        - `subagent_id` — the id YOU supplied at ack time. This names which subagent to stop. It is `null` only when the cancel beat your first ack, in which case you have nothing running to stop.
        - `reason` — one of `wrong_intent`, `wrong_target`, `not_actionable`, `other`.
        - `corrected_intent` — a replacement intent string when the producer edited rather than deleted; `null` for a plain removal.
        - `corrected_target_agent_id` — a replacement target agent when the producer re-routed; `null` for a plain removal.
        - `status` — the queue status the row held at the moment the cancel was signalled.

        The contract:

        1. **Forward the cancel to THAT subagent** — the one named by `subagent_id`, not to every subagent you happen to be running.
        2. **Terminate at the next tool-call boundary. Do NOT force-abort mid-tool-call.** A half-written file or a half-posted canvas is worse than three more seconds of work.
        3. **Then reply `intent_ack(intent_id="{{intent_id}}", subagent_id="<the same id>", status: "cancel_honored")`.** The row stays in flight until you do: the queue deliberately does not assume you stopped, because an unstopped subagent marked cancelled is exactly the invisibility this queue exists to remove.
        4. If the work had ALREADY finished when the cancel reached you, ack `cancel_honored` anyway. The queue lands that as `cancelled_late` — a recorded outcome, not a failure. Do not attempt to undo completed work.
        5. `corrected_intent` / `corrected_target_agent_id` are informational. The producer's correction is recorded on their side; do NOT start the corrected work off the cancel event. If the corrected intent is for you, a fresh dispatch will arrive for it.

        ## Failure surfacing

        If the spawn itself fails, do NOT invent a `subagent_id` to satisfy the ack. Let the schema reject the attempt, post a line naming the failure into `execution_space_id` `{{execution_space_id}}`, and let the window close — `no_ack_spawn_failed` is the honest status and it is what tells the producer this target is unreliable.

        If something raises after the subagent is running, ack `completed` ONLY if the deliverable actually landed. Otherwise post the failing step into `{{execution_space_id}}` and ack `rejected` with the reason in the `note`. A false `completed` is invisible, and invisible failure is what this queue exists to remove.

        Never leave an intent unacked to "see if it resolves". The whole meeting's queue is behind it.

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.fallback",
        name: "Fallback Dispatch Prompt",
        description:
          "Sent when a task is assigned but doesn't match planning/in_progress/in_review/deploying. " <>
            "Generic assignment prompt.",
        variables: [
          "task_title",
          "task_description",
          "task_status",
          "task_priority",
          "stage_info",
          "federation_preamble"
        ],
        content: """
        You have been assigned a task.

        Task: {{task_title}}
        Description: {{task_description}}
        Status: {{task_status}}
        Priority: {{task_priority}}
        {{stage_info}}Review the task context and begin working. Report progress by pushing validation evidence as you complete each stage.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, current plan with stages, and execution_space_id. Use it for full context.

        {{federation_preamble}}
        """
      },
      %{
        slug: "heartbeat",
        name: "Heartbeat Prompt (DEPRECATED — task 019f640d stage 4)",
        description:
          "DEPRECATED. Retained one release for admin-UI parity. The router no " <>
            "longer emits this — periodic polling is gone (ADR 0025 amendment). " <>
            "For safety-net / no-ack nudges, see the `nudge` slug. Stage 6 ADR " <>
            "cleanup pass removes this template entirely.",
        variables: [
          "task_title",
          "stage_name",
          "stage_status",
          "elapsed",
          "pending_validations",
          "plan_status",
          "plan_exists"
        ],
        content: """
        Task: {{task_title}} [stage: {{stage_name}} — {{stage_status}}]
        Stage running for: {{elapsed}}
        Pending validations: {{pending_validations}}
        Plan status: {{plan_status}}

        Either push validation evidence or report a blocker.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id.\
        """
      },
      %{
        slug: "nudge",
        name: "Nudge Prompt (short-form, safety-net / no-ack)",
        description:
          "Short-form nudge sent on safety-net / no-ack events only (task 019f640d " <>
            "stage 4). Replaces the polling-era full-context re-fire. No " <>
            "skills_reference, no evidence_workflow_reference, no task description, " <>
            "no org preamble — target output <500 tokens (~<2000 chars). Callers: " <>
            "`TaskRouter.fire_no_ack_alert/2` and `TaskRouter.fire_safety_net_alert/2` " <>
            "via `HeartbeatScheduler.nudge_prompt/2`.",
        variables: [
          "task_id",
          "stage_id",
          "elapsed_minutes",
          "pending_validation_ids"
        ],
        content: """
        Task {{task_id}} stage {{stage_id}} — no ack in {{elapsed_minutes}}m. Please ack, push validation, or report_blocker.

        ## Completion Reminder
        Current task_id: `{{task_id}}`
        Current stage_id: `{{stage_id}}`
        - Pending validation IDs: {{pending_validation_ids}} — ack, push validation_pass, or report_blocker with task_id={{task_id}} stage_id={{stage_id}}
        - If you are blocked on local infra (test rig, containers, ports, moon, credentials, missing tools), you should already have pinged Dalton (with an @-mention) in the execution space; if not, do it now instead of filing a blocker.\
        """
      },
      %{
        slug: "architecture.review_plan.v1",
        name: "Architecture Review — Plan-time",
        description:
          "Sent to the architect agent when a plan is submitted for review (ADR-0044, " <>
            "gated by ADR-0046). The plan is HELD at `pending_review` until the architect " <>
            "returns a verdict through `plan_architecture_verdict` or the gate deadline " <>
            "expires (silence falls open). Rejection is limited to the four closed " <>
            "`constraint` values — module_boundary, data_model, cross_context_coupling, " <>
            "duplicated_logic — and explicitly not to taste, naming or style.",
        variables: [
          "plan_summary",
          "sibling_tasks",
          "open_prs",
          "adr_index"
        ],
        content: """
        You are the Architect. A plan has been submitted and **it is held at
        `pending_review` until you answer.** You occupy the plan-review slot: while your
        verdict is outstanding, nothing approves this plan — not the planner, not
        auto-approval, not another agent. **You must answer.** One call to
        `plan_architecture_verdict`, `pass` or `reject`.

        ## Reject only for what is expensive to undo later

        Four things, and only these four. They are the exact `constraint` values the
        verdict tool accepts:

        - `module_boundary` — the plan puts code on the wrong side of a module boundary,
          or invents a boundary that already exists somewhere else.
        - `data_model` — a schema, column or key shape that will have to be migrated
          again to fix.
        - `cross_context_coupling` — one context reaching into another context's
          internals instead of going through its public surface.
        - `duplicated_logic` — the plan builds a second implementation of something that
          already exists, or that a sibling task listed below is building right now.

        Every one of these is cheap to change while the plan is text and expensive to
        change after the code lands. That is the whole test.

        ## Explicitly NOT for taste, naming, or stylistic preference

        Do not reject because you would have named it differently, split the modules
        differently, or preferred another idiom. The reason matters more than the rule,
        so here it is: an architect that rejects on style gets switched off within a
        week, and a gate that looks present but is switched off is worse than no gate at
        all. The verdict tool has no `constraint` value you could put a style objection
        in — that is deliberate, not an oversight. Put it in `summary` and pass.

        ## Fast pass for small changes

        A one-line fix, a copy change, a config value, a hotfix: **pass it.**

        Concretely: when the plan introduces no new module, no new context, no new table
        and no new cross-context call, **pass** — unless one of the four constraints
        above is CONCRETELY violated and you can name the stage where it happens. If you
        cannot name the stage, you do not have a finding; you have a feeling. Pass.

        Bias toward pass, and here is why the costs are not symmetric: a wrong reject
        costs a full replan cycle — the planner rewrites, resubmits, and you review it
        again. A wrong pass still has the human reviewer, the reviewing agent, and CI
        standing behind it. You are the first of four gates, not the last.

        ## Also report — but do not usually reject

        These three go in `summary`. Escalate one to a `reject` **only** when it crosses
        one of the four constraints above; a collision with a sibling task is information
        for the human reviewer, not automatically an architectural fault.

        1. **In-flight collisions** (`collision`). Does this plan touch a file or
           subsystem that another in-flight task (planning / in_progress / in_review) is
           already modifying? Cite the colliding task by id + stage description so the
           human can serialise or merge.

        2. **Superseded pattern re-introduction** (`adr_drift`). Scan the ADR index for
           `Supersedes:` / `Superseded by:` refs against the plan's declared files or
           approaches. If the plan re-introduces a pattern an ADR retired, name the ADR
           and quote the guidance it appears to contradict. Cite the ADR by FILENAME
           (e.g. `0044-architect-responsibility.md`); numbers are NOT unique in this
           directory — several are shared by two different ADRs, and the index below
           flags which. A number-only citation sends the reader to the wrong document.

        3. **Duplicate abstraction** (`dup_abstraction`). Is another in-flight plan
           already building the same helper / context / component this plan proposes?
           Cite both tasks side-by-side. This one crosses into `duplicated_logic` when
           the duplication is real and concurrent — say so if it does.

        ## Plan summary (task under review)

        {{plan_summary}}

        ## In-flight sibling tasks (same project, statuses: planning / in_progress / in_review)

        {{sibling_tasks}}

        ## Open pull requests (from `gh pr list --state open`)

        {{open_prs}}

        ## ADR index (docs/decisions/)

        {{adr_index}}

        ## Output shape — call `plan_architecture_verdict`

        Exactly one call, with:

        - `plan_id` — the plan id printed in the plan summary above.
        - `verdict` — `"pass"` or `"reject"`. There is no third value.
        - `summary` — required on both. One paragraph: what you checked, what you found,
          and anything from the three demoted checks above.
        - `findings` — required and non-empty on a `reject`, omitted on a `pass`. **One
          finding per objection**, each carrying `constraint`, `detail`, and — when the
          objection is about one particular stage — that stage's `stage_id`.

        **`stage_id` is optional.** Omit it (or send `null`) when the defect lives at the
        plan level rather than in any one stage: a decomposition that is wrong even
        though each stage is individually sound, or a sequencing problem spread across
        several stages with no single one at fault. Such a finding reaches the planner
        labelled `(plan-wide)`. Do NOT downgrade a plan-level architectural objection to
        a `pass` with a note in `summary` — `summary` is not a rejection, the plan
        proceeds, and the defect ships. If it is one of the four constraints, reject with
        a stage-less finding.

        A `detail` states WHAT TO CHANGE, not what is wrong. Good:

        ```json
        {
          "stage_id": "<a stage id from the plan summary above>",
          "constraint": "cross_context_coupling",
          "detail": "Stage 3 queries Platform.Chat's tables directly from Platform.Tasks. Route the read through Platform.Chat.list_messages/1 so the boundary stays one-directional."
        }
        ```

        Plan-level, also good:

        ```json
        {
          "constraint": "module_boundary",
          "detail": "Stages 2, 3 and 4 each add one call site of the same boundary crossing; no single stage is wrong, but the decomposition has no stage in which the shared seam gets built. Add a stage that introduces the seam before the three that consume it."
        }
        ```

        Bad — `{"constraint": "module_boundary", "detail": "This is unsound"}`. "This is
        unsound" is unactionable: the planner cannot tell what
        to write differently, so the next version comes back differently worded rather
        than better. If you cannot say what to change, you are not rejecting — you are
        commenting, and comments go in `summary` with a `pass`.

        A `reject` whose `constraint` is not one of the four listed above is REFUSED at
        the tool boundary, as is a finding whose `stage_id` is PRESENT but does not
        belong to this plan. An omitted `stage_id` is accepted — it is how you say
        "plan-wide" — so never invent or guess an id to satisfy the shape.
        A refused call does not resolve the gate; the plan stays held and the deadline
        keeps running.

        ## The deadline

        You have **15 minutes** from dispatch. If you do not answer, the gate expires and
        the plan proceeds WITHOUT your verdict — silence falls open, it does not block.
        Answer rather than deliberate: a verdict you are 80% sure of, delivered, beats a
        perfect one that arrives after the gate has closed.\
        """
      },
      %{
        slug: "architecture.cron_sweep.v1",
        name: "Architecture Cron Sweep — Weekly tech-debt walk",
        description:
          "Sent to the architect agent every Monday 04:00 UTC (ADR-0044 stage 5). " <>
            "Walks open PRs, recently-closed tasks, and the ADR index to file at most " <>
            "3 backlog follow-ups per sweep. Firing is gated on the `architect` role " <>
            "assignee — the sweep no-ops when the role has no assignee.",
        variables: [
          "open_prs",
          "recent_closed_tasks",
          "adr_index"
        ],
        content: """
        You are the Architect. It is Monday 04:00 UTC — your weekly tech-debt sweep. Your
        job is to walk the recent open PRs, the past-week's closed tasks, and the ADR
        index below, then file **at most 3 follow-up backlog tasks** for concerns that
        the per-task Architect responsibilities (`review_plan` + `audit_diff`) can't
        surface on their own.

        You are **additive, not a blocker** — every follow-up you file lands in the
        `backlog` column with `metadata.filed_by = "architect_cron_sweep"`. Rowan decides
        whether to prioritise or close each one. Overfiling is worse than underfiling; if
        nothing warrants a follow-up, file zero.

        ## What to check for

        Read the three source blocks, then propose follow-ups in any of these categories:

        1. **ADR gap.** A subsystem or pattern is referenced 3+ times across recently-
           closed tasks but has no ADR in `docs/decisions/`. Propose the ADR title and
           what it should decide (not the answer — the ADR itself is a separate task).

        2. **Doc drift.** A concept has moved (renamed, retired, replaced) across recent
           PRs but the ADR that describes it still names the old shape. Cite both the PR
           and the ADR by number.

        3. **Latent tech debt.** A recently-closed task explicitly left TODO / FIXME in a
           follow-up TODO comment or task description ("revisit after X ships") whose X
           is now shipped. Cite the closed task by id + the phrase that flagged the
           follow-up.

        4. **Open PR that never landed.** A PR is open for more than 7 days AND is not
           labelled `draft`. Propose a task to either land it, close it, or split it —
           name the PR by number.

        Each follow-up MUST cite at least one concrete reference (PR number, task id, or
        ADR number). Vague "improve X" follow-ups get rejected at file time; the handler
        drops any follow-up with no `refs`.

        ## Open PRs (from `gh pr list --state open --limit 20`)

        {{open_prs}}

        ## Recently-closed tasks (past 7 days, status: done)

        {{recent_closed_tasks}}

        ## ADR index (docs/decisions/)

        {{adr_index}}

        ## Output shape

        Return a single JSON object with one key `followups`:

        ```
        {
          "followups": [
            {
              "title": "<one-line task title — imperative, ≤ 80 chars>",
              "rationale": "<2-3 sentences of why this deserves a task, with concrete refs inline>",
              "refs": ["#488", "019f3da3", "ADR-0044"]
            }
          ]
        }
        ```

        `refs` is a flat list of strings — PR numbers prefixed with `#`, task uuids or
        short-ids, or ADR numbers. **Maximum 3 items in `followups`**; return an empty
        list if nothing warrants a follow-up. Do NOT invent references — every ref must
        appear in the source blocks above.

        Do NOT self-approve any follow-up. Do NOT call `task_update`. Do NOT modify any
        existing task. Your only side effect is emitting the JSON above; the handler
        translates it into `Tasks.create_task/1` calls.\
        """
      },
      %{
        slug: "architecture.audit_diff.v1",
        name: "Architecture Audit — Post-executor drift",
        description:
          "Sent to the architect agent when a stage transitions to `passed` (ADR-0044 stage 4). " <>
            "Audits what shipped against the stage's planned shape and known durable patterns. " <>
            "Additive annotations only — the reviewer dispatch fires regardless.",
        variables: [
          "stage_diff",
          "planned_shape",
          "org_memory_entries",
          "stage_id"
        ],
        content: """
        You are the Architect. A stage just transitioned to `passed`. Your job is to audit what
        shipped against what the plan asked for and post any drift you notice as annotations to
        the task's execution space. You are **additive, not a blocker** — the reviewer's
        dispatch fires no matter what you find. Rowan reads your annotations and decides
        whether the drift matters.

        ## What to check for

        Read the planned shape (stage description + plan payload), the ORG_MEMORY flag list, and
        the diff summary below (v1 limitation: the raw git diff is NOT captured at this signal;
        you work from the planned shape and any signal the executor's stage description carries).
        Flag any of the following:

        1. **Divergence from planned files.** The stage description names the files the
           executor was asked to touch. If the description explicitly says "edit only X and Y"
           and the shipped diff clearly touches other subsystems, name the surprise files and
           ask whether they belong in a follow-up task or need an ADR entry. Prefer citing
           by path (e.g. `apps/platform/lib/platform/tasks.ex`).

        2. **New dep without ADR.** If the diff or the stage description mentions a new
           library / adapter / service dependency that isn't referenced in an existing ADR
           and isn't a trivial dev-only tool, flag it and suggest which ADR number the
           follow-up should carry.

        3. **Migration missing `down/0`.** If a migration lands with no `down/0` clause (or a
           `def down, do: :ok` stub for a destructive change), flag it — the deploy pipeline's
           rollback path needs the inverse operation.

        4. **Durable-pattern violation.** The prompt attaches a short list of known durable
           patterns from ORG_MEMORY. If the stage description or diff re-introduces a pattern
           one of them retired, cite the memory key (in square brackets, exactly as shown) and
           quote the guidance the change appears to contradict.

        If none of the four concerns apply, still make the call below with a `summary`
        confirming the shipped stage looks clean — "no drift, no new deps, no
        memory-pattern reintroduction" — so Rowan sees the architect ran and had nothing to
        flag. Silence is ambiguous; explicit "clean" is not.

        ## Planned shape (what the stage description asked for)

        {{planned_shape}}

        ## Shipped diff summary

        {{stage_diff}}

        ## Durable patterns to check against (ORG_MEMORY)

        {{org_memory_entries}}

        ## How to land your audit — this is the only way

        Call the `stage_architecture_audit` MCP tool (capability bundle: `plan`) exactly
        once:

        ```
        stage_architecture_audit(
          stage_id: "{{stage_id}}",
          summary: "<one paragraph: what you checked and what you found>",
          findings: [
            {"constraint": "module_boundary", "detail": "<what to change>"}
          ]
        )
        ```

        `stage_id` is the id printed above — pass it verbatim. `summary` is REQUIRED and
        must be non-blank **including when the stage is clean**: write
        "no drift, no new deps, no memory-pattern reintroduction" so Rowan sees the
        architect ran and had nothing to flag. Silence is ambiguous; an explicit clean
        result is not. `findings` is OPTIONAL — omit it entirely on a clean stage. Each
        finding's `constraint` must be one of `module_boundary`, `data_model`,
        `cross_context_coupling`, `duplicated_logic`; there is deliberately no value for a
        taste, naming or style objection, so say that in `summary` instead. Each `detail`
        must state WHAT TO CHANGE, not merely what is wrong.

        The tool posts your annotation to the task's execution space AND records the audit
        against the stage, in one step. Do not post the annotation yourself — a message
        written any other way leaves no record that the audit happened, which is the exact
        blind spot this surface was built to close. The call is ONE-SHOT: the first note
        wins and a second is refused with `audit_already_recorded`.

        Prefix your `summary`'s first line with the concern kind you are reporting — one of
        `divergence`, `new_dep`, `migration`, `memory_violation`, or `clean` — so the
        execution-space reader can scan the annotations.

        Do NOT rewrite the stage. Do NOT call `task_update`. Do NOT create a
        `review_request`. Your only side effect is the `stage_architecture_audit` call. The
        reviewer's dispatch fires regardless of what you flag — your annotations exist so
        Rowan sees drift before it compounds.\
        """
      },
      %{
        slug: "stacks.dep_inference.v1",
        name: "Task Stack Dependency Inference (v1)",
        description:
          "Rendered by Platform.Tasks.Stacks.DepInference before the LLM round-trip. " <>
            "Given a task stack and its members (id / title / description), instruct the " <>
            "model to return a JSON list of within-stack dependency edges the planner " <>
            "cascade can persist via Stacks.add_dependency_edge/4.",
        variables: [
          "stack_name",
          "stack_description",
          "members_json"
        ],
        content: """
        You infer within-stack task dependency edges for a task stack. You output STRICT JSON ONLY — no prose commentary, no markdown fences, no leading or trailing text.

        ## Stack
        Name: {{stack_name}}
        Description: {{stack_description}}

        ## Members (JSON array of {id, title, description})
        {{members_json}}

        ## Your job
        Read each member and infer which members MUST wait on which other members before they can start (a "blocks" dependency). Typical signals: member B's description references a type, module, endpoint, migration, or artifact that member A creates; member C consumes a table/column/schema/route defined by member B; member D's tests exercise behavior that member A implements.

        ## Output contract (strict)
        Return a JSON object of exactly this shape:

        {"edges": [{"from_task_id": "<uuid>", "to_task_id": "<uuid>", "reason": "<short natural-language rationale>"}]}

        Rules — a violation is a wrong answer:
        - The `from_task_id` is the member that WAITS on `to_task_id`. Read literally: "from_task_id is blocked by to_task_id."
        - Both `from_task_id` and `to_task_id` MUST be values that appear in the `id` field of the members list above. Do not invent uuids. Do not reference tasks outside this stack.
        - Never emit a self-edge (`from_task_id == to_task_id`).
        - When no dependencies are inferable, return exactly `{"edges": []}`. Do NOT invent speculative edges to fill the array.
        - `reason` is a single short sentence (under 200 chars) — enough for a human reviewer to sanity-check the edge.
        - Output the JSON object as the entire response body. No prose commentary. No markdown fences. No leading or trailing text.
        """
      },
      %{
        slug: "design.task_direction.v1",
        name: "Design Direction — Pre-plan",
        description:
          "Sent to the designer BEFORE a UI-touching task is planned (ADR-0046 stack " <>
            "member 7). Produces direction for the surface the task changes — subject, " <>
            "palette, type roles, layout intent, self-critique — delivered as a canvas " <>
            "attached to the task. Advisory: it does not block development.",
        variables: [
          "task_summary",
          "brand_context",
          "attached_canvases"
        ],
        # The five deliverable bullets were lifted VERBATIM from the
        # `dispatch.planning` body's "Add an early advisory design stage"
        # section, which asked the planner for exactly this shape from task
        # 019f4f1d until task 019f9b29-5ecd stage 6 deleted it (the planner
        # no longer authors a design stage, so this template is now the
        # only place that shape lives). Copying rather than paraphrasing
        # was the point: ADR-0046 moves WHO produces the direction and
        # WHEN, not WHAT it looks like, and a reworded copy would silently
        # change the output shape downstream consumers already read.
        #
        # Task `019fa504` stage 3 adds the SECOND exit to `## Delivery`
        # (`task_design_decline`) and touches nothing else in this body — the
        # bullets above are still the verbatim copy. Editing this function is
        # NOT the deliverable on its own: `seed_defaults/0` is INSERT-only and
        # `20260726051346_seed_design_task_direction.exs` claimed this slug on
        # every migrated environment, so the row is reached only by
        # `20260727210000_force_update_design_task_direction_decline.exs`.
        content: """
        You are the Designer. A task is about to be planned and it touches a user-facing surface. Produce DESIGN DIRECTION for that surface now, before the plan is written.

        Low-fi and directional is correct. This is advice, not a gate: it does not block development, and the direction is expected to be iterated.

        ## The task

        {{task_summary}}

        ## Brand context

        {{brand_context}}

        ## Canvases already attached to this task

        {{attached_canvases}}

        ## Deliverable

        Produce direction in exactly this shape:

        - Opening line pins the subject: what this surface is, who uses it, and the one job it does.
        - Palette: 4–6 named color values (from brand tokens if they exist; provisional if exploring).
        - Type: 2–3 roles (display used with restraint, body, optional utility).
        - Layout: one sentence of intent + a rough wireframe; name ONE signature element — spend boldness in one place.
        - Self-critique before handoff: revise anything that reads like the generic default for this kind of page, and say what changed.

        ## Delivery

        Write the direction to a canvas and attach that canvas to the task with the `task_attach_canvas` MCP tool, using the task_id above. The attachment IS the completion signal the planner waits on — direction posted only as a chat message is not delivered.

        If, having read the task, you judge that this surface needs no design direction — the change is not visual, or the surface already has direction that still holds — do NOT attach a canvas you do not believe in and do NOT go silent. Call `task_design_decline` with the task_id above and a one-sentence reason. That records the step as not-applicable and releases the planner immediately. Going silent instead costs 30 minutes and records a failure.
        """
      },
      %{
        slug: "federation.preamble",
        name: "Federation Preamble",
        description:
          "Cross-cutting Claude Code guidance block injected into every `dispatch.*` body " <>
            "via the `{{federation_preamble}}` placeholder. Not a dispatch body itself — it is " <>
            "the shared block those bodies substitute in.",
        # `variables: []` is correct and load-bearing: the preamble contains no
        # `{{...}}` placeholders and must not gain any. `interpolate/2` is a
        # single `Regex.replace` pass, so a placeholder inside a substituted
        # value is never re-expanded and would ship to agents literally.
        variables: [],
        # The attribute itself, never a hand-retyped copy — byte-identity with
        # `federation_preamble/0` is then structural rather than maintained.
        content: @federation_preamble
      }
    ]
  end
end
