defmodule Platform.Responsibilities.Handlers.ArchitectureReviewPlan do
  @moduledoc """
  `architecture.review_plan` responsibility provider (ADR-0044 stage 3,
  task `019f3da3`).

  Stage 1 (`32e92bcc`) shipped the registration placeholder + ADR
  0044. Stage 2 (`e7e91ebd`) wired the plan-submit `fire/2` hook in
  `Platform.Tasks.submit_plan_for_review/1` behind the
  `try/rescue/catch :exit` guard mandated by the progressive-enhancement
  contract. This stage 3 revision fills in the real content:

    * `gather_context/2` composes three `ContextProviders` slots. No
      payload is built here any more —
      `Platform.Responsibilities.ContextProviders` is the single
      per-slot resolver, so the Router's batch path and this handler
      see identical payloads.

      `:plan_payload` (task 019f9b28-6ca7 stage 3) REFUSES an
      unresolvable plan and the refusal propagates out of
      `gather_context/2`: ADR-0046 runs this pass strictly after plan
      submission, so "no plan" means a broken trigger, not an empty
      review.

      `:sibling_tasks` (stage 4) NEVER refuses, and the asymmetry is the
      design. It resolves siblings through a stack → epic → bounded
      project-window ladder, and "no siblings" is an ordinary correct
      state for a standalone task, not a wiring bug. Its old private
      implementation here walked every in-flight task in the project
      with no limit at all; the slot caps the project window at 10 and
      discloses every drop in the rendered block.

      `:adr_index` (stage 5) never refuses either, and for a reason
      that belongs to the deployment rather than the trigger: release
      images ship no `docs/`, so an unreachable directory is the
      production steady state. It is keyed on FILENAME, not number —
      `docs/decisions/` holds four numbers that each name two different
      ADRs — and carries status, collision and supersession flags so
      the architect can tell a live decision from a retired one.
    * `render_instruction/1` renders `architecture.review_plan.v1` from
      the DB (falls back to the hardcoded template body when the DB
      row is missing so early-boot dispatch doesn't crash).
    * `build_prompt/1` is the M6 Router callback; it returns
      `{:ok, %{system:, user:}}` so the Router hands the pre-built
      prompt to the ExternalDispatcher without the legacy template
      render path.
    * `handle_output/3` posts the architect's annotations to the plan's
      execution space via `Platform.Orchestration.ExecutionSpace.post_log/2`
      — additive, not a blocker. If the space can't be resolved (task
      hasn't been assigned yet) we log and return `:ok` rather than
      crashing the Router.

  ## Spec (unchanged from stage 1)

    * `key` — `"architecture.review_plan"`
    * `feature` — `"architecture"`
    * `trigger_kind` — `event_topic` with `topic: "plan:submitted"`
    * `scope` — `per_project`
    * `context_provided` — `["plan_payload", "sibling_tasks", "adr_index"]`
    * `default_prompt_template` — `"architecture.review_plan.v1"`
    * `cost_profile` — `low_freq_capable`

  ## `similar_tasks/2` opt-in

  Task `019f3dbb` (vectorize-tasks) is landing a
  `Platform.Tasks.similar_tasks/2` helper that could enrich the
  duplicate-abstraction check. This handler probes for it via
  `Code.ensure_loaded?/1` and uses it if present; if not the sibling
  walk alone is enough for v1 and no error is raised.

  ## Native-vs-external dispatch

  The Router only calls `build_prompt/1` / `handle_output/3` for
  `kind: "external"` agents. Native agents (Suite-internal) get an
  AgentResponder signal and run their own attention prompt loop — the
  `context_provided` slots this handler declares are surfaced via the
  usual context bundler on the receiver side. Stage 3 tests exercise
  the handler functions directly; that all three slots actually reach
  the model on a live external dispatch is asserted on the outbound
  request bytes in
  `test/platform/responsibilities/architecture_context_bridge_test.exs`
  (task 019f9b28-6ca7 stage 6).
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  @key "architecture.review_plan"
  @feature "architecture"
  @template_slug "architecture.review_plan.v1"

  # ADR-0046 decision 7. Written into `architecture_verdict["summary"]`
  # when the external reply carries no parseable verdict, so the row says
  # WHY the gate fell open rather than only that it did. Read by tests
  # and greppable in prod; the machine-readable half is
  # `state: "dispatch_failed"` plus
  # `planning_step_outcomes["architecture"]["outcome"] = "failed"`.
  @unparseable_verdict_summary "unparseable_verdict — the architect's reply carried no " <>
                                 "parseable verdict object; the gate fell open (ADR-0046 " <>
                                 "decision 7) and the plan proceeded without a verdict."

  # Shape of the `:sibling_tasks` slot when the anchor task can't be
  # resolved. The slot itself never errors (it is optional context), so
  # this only covers the defensive arm and the refusal-rendering path in
  # `empty_context/1`. Kept in sync with
  # `ContextProviders.empty_siblings/1`.
  @empty_siblings %{
    scope: :no_anchor,
    total: 0,
    shown: 0,
    truncated?: false,
    dropped: 0,
    unplanned_excluded: 0,
    tasks: []
  }

  # Shape of the `:adr_index` slot when the directory can't be read.
  # Same role as `@empty_siblings`: the slot never errors, so this
  # covers the defensive arm and the refusal-rendering path in
  # `empty_context/1`. Kept in sync with
  # `ContextProviders.unavailable_index/2`.
  @unavailable_adr_index %{
    available?: false,
    reason: :adr_dir_unreachable,
    dir: nil,
    total: 0,
    shown: 0,
    truncated?: false,
    dropped: 0,
    dropped_files: [],
    number_collisions: %{},
    title_collisions: %{},
    entries: []
  }

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
        trigger_kind: "event_topic",
        # Plan-submit hook fired by
        # `Platform.Tasks.submit_plan_for_review/1` (ADR-0044 stage 2).
        # The Router doesn't subscribe to this topic through Phoenix.PubSub
        # because the caller invokes `Responsibilities.fire/2` directly
        # — the `topic` slot is documentation for operators inspecting
        # the row.
        trigger_config: %{"topic" => "plan:submitted"},
        scope: "per_project",
        context_provided: ["plan_payload", "sibling_tasks", "adr_index"],
        output_contract: %{
          "comments" => "list[map]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.architecture",
          "status" => "active",
          "role" => "architect",
          "adr" => "0044"
        }
      }
    ]
  end

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def gather_context(_responsibility, ctx) when is_map(ctx), do: do_gather_context(ctx)

  def gather_context(_responsibility, _ctx), do: {:error, :no_plan_payload}

  @doc """
  Assemble the architect prompt context from the plan payload the
  plan-submit hook fires.

  Public so tests can exercise the sibling-walk / ADR-index shape
  without standing up a fully-populated Router pipeline. Accepts the
  same map shape `Platform.Tasks.fire_architecture_review_plan/1`
  publishes: `%{plan: %Plan{}, plan_id: id, task_id: id}`.

  Unlike the arity-2 Provider callback this **always returns a map** —
  the refusal is rendered as `plan_payload.error` so callers that just
  want something to format keep getting one. Dispatch decisions must use
  the arity-2 callback, which propagates `{:error, :no_plan_payload}`.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx) when is_map(ctx) do
    case do_gather_context(ctx) do
      {:ok, gathered} -> gathered
      {:error, reason} -> empty_context(reason)
    end
  end

  @doc """
  Render the plan-review instruction for the architect agent by piping
  the gathered context through the `architecture.review_plan.v1`
  prompt template.

  Returns a non-empty string. When the DB row is missing (early boot,
  test seed skipped) we fall back to `default_content_for_slug/1` so
  the caller still gets renderable text.
  """
  @spec render_instruction(map()) :: String.t()
  def render_instruction(context) when is_map(context) do
    assigns = context_to_assigns(context)

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, rendered} when is_binary(rendered) and rendered != "" ->
        rendered

      _ ->
        # Fall back to the hardcoded default so a missing seed row
        # doesn't strand the caller. The default carries the full
        # prompt body verbatim from `do_default_templates/0`.
        fallback =
          case PromptTemplates.default_content_for_slug(@template_slug) do
            nil -> ""
            body -> body
          end

        interpolate_fallback(fallback, assigns)
    end
  end

  @impl true
  @doc """
  Build the (system + user) messages the Router hands to the external
  dispatcher (task 019f2570 bug 1 fix pattern — provider owns its
  prompt end-to-end).

  The system slot names the architect role and the GATE contract; the
  user slot is the rendered instruction from `render_instruction/1`.
  This callback lands the M6 arity-3 Provider protocol without churning
  the arity-2 fallbacks.

  ADR-0046 member 5 stage 4 rewrote the system slot. It used to say the
  architect's output was "additive" and that it "does not block plan
  approval"; both sentences became false the moment stage 3 landed the
  guard in `Tasks.approve_plan/3`, and a system slot that contradicts
  the user slot trains the model out of using the gate at all. The two
  now carry one claim.
  """
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    user = render_instruction(context)

    system =
      "You are the Architect on the Suite plan-review path (ADR-0044, gated by " <>
        "ADR-0046). The plan is HELD at `pending_review` until you return a verdict, " <>
        "and you must return one: `pass` or `reject`, via `plan_architecture_verdict`. " <>
        "Reject ONLY for `module_boundary`, `data_model`, `cross_context_coupling` or " <>
        "`duplicated_logic` — never for taste, naming or style. Bias toward pass; a " <>
        "wrong reject costs a full replan cycle, a wrong pass still has the human " <>
        "reviewer, the reviewing agent and CI behind it. Cite tasks by id and ADRs by " <>
        "FILENAME — `docs/decisions/` reuses numbers across different ADRs, so a number " <>
        "is not a reference the human reviewer can follow."

    {:ok, %{system: system, user: user}}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(%Responsibility{} = _responsibility, output, trigger_meta)
      when is_map(trigger_meta) do
    # ADR-0046 member 5 stage 4 — THE EXTERNAL VERDICT SURFACE.
    #
    # Runs AHEAD of the annotation, and its result is discarded. The
    # annotation is the human-readable trace; the gate is the
    # machine-readable one, and the two must not be able to take each
    # other down. A task with no execution space yet (the `nil` arm
    # below) would otherwise silently skip the settlement and leave the
    # plan held until stage 5's deadline collects it.
    #
    # There is no third state machine here: everything funnels into
    # `Tasks.record_architecture_verdict/3` via
    # `Tasks.resolve_architecture_gate/3`, the same single exit the MCP
    # tool and the human override use.
    _ = settle_architecture_gate(output, trigger_meta)

    post_architect_annotation(output, trigger_meta)
  end

  defp post_architect_annotation(output, trigger_meta) do
    task_id = extract_task_id(trigger_meta)

    with :ok <- ensure_task_id(task_id),
         %{} = space <- ExecutionSpace.find_by_task_id(task_id),
         comment when is_binary(comment) and comment != "" <- extract_comment(output) do
      post_annotation(space.id, comment)
    else
      {:error, :missing_task_id} ->
        Logger.warning(
          "[architecture.review_plan] handle_output missing task_id in trigger_meta — " <>
            "keys=#{inspect(Map.keys(trigger_meta))}"
        )

        :ok

      nil ->
        Logger.info(
          "[architecture.review_plan] no execution space for task_id=#{inspect(task_id)} — " <>
            "skipping annotation post"
        )

        :ok

      "" ->
        Logger.debug(
          "[architecture.review_plan] empty architect comment payload — nothing to post"
        )

        :ok

      _ ->
        Logger.debug("[architecture.review_plan] unrecognised output payload — nothing to post")

        :ok
    end
  end

  @doc """
  Parse an architect verdict out of an external model reply.

  Accepts a map already carrying `"verdict"`, or a JSON object embedded
  in a content binary — the external dispatcher hands back raw content,
  so a fenced ```` ```json ```` block and a JSON object with prose either
  side of it both have to be tolerated.

  Returns `{:ok, %{resolution: :pass | :reject, summary: binary() | nil,
  findings: [map()]}}`, or `{:error, :unparseable}`.

  ## `{:error, :unparseable}` means FALL OPEN, not "block"

  Every rejection path in here ends in `resolve_architecture_gate(plan,
  :dispatch_failed)`. A model that answered in prose, answered with a
  verdict word that is not `pass` / `reject`, or rejected without a
  single actionable finding must not be able to park a task forever —
  ADR-0046 decision 7. The costs are asymmetric in the same direction
  the prompt argues: falling open restores today's behaviour (the plan
  proceeds to its human reviewer), failing closed strands the task and
  needs a human to dig it out.

  A `"reject"` with no surviving finding is deliberately `:unparseable`
  rather than a reject. Findings are dropped here when their
  `constraint` is outside `Plan.architecture_constraints/0` or their
  `stage_id` does not belong to the plan under verdict — the same two
  rules `plan_architecture_verdict` refuses on. The tool can refuse and
  let the architect retry; this path has no caller to refuse to, so a
  reject that reduces to nothing actionable is treated as no verdict at
  all rather than stored as an objection the planner cannot act on.
  """
  @spec parse_verdict(term(), [binary()]) ::
          {:ok, %{resolution: :pass | :reject, summary: binary() | nil, findings: [map()]}}
          | {:error, :unparseable}
  def parse_verdict(output, stage_ids \\ []) do
    with {:ok, object} <- verdict_object(output),
         {:ok, resolution} <- verdict_resolution(Map.get(object, "verdict")) do
      findings = sanitize_findings(Map.get(object, "findings"), stage_ids)

      cond do
        resolution == :reject and findings == [] ->
          {:error, :unparseable}

        true ->
          {:ok,
           %{
             resolution: resolution,
             summary: verdict_summary(Map.get(object, "summary")),
             findings: findings
           }}
      end
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  # ── ADR-0046 member 5 stage 4: external verdict settlement ───────────

  defp settle_architecture_gate(output, trigger_meta) do
    case extract_plan_id(trigger_meta) do
      nil ->
        Logger.debug(
          "[architecture.review_plan] handle_output carried no plan_id — " <>
            "no gate to settle (keys=#{inspect(Map.keys(trigger_meta))})"
        )

        :ok

      plan_id ->
        case parse_verdict(output, plan_stage_ids(plan_id)) do
          {:ok, %{resolution: resolution, summary: summary, findings: findings}} ->
            apply_gate_resolution(plan_id, resolution,
              summary: summary,
              findings: findings
            )

          {:error, :unparseable} ->
            # FALL OPEN AND SAY SO. `:dispatch_failed` also writes
            # `planning_step_outcomes["architecture"] = "failed"` inside
            # `resolve_architecture_gate/3`, so "the plan proceeded" and
            # "the architect did not answer" stay distinguishable —
            # ADR-0046:83's conflation is the thing this records against.
            apply_gate_resolution(plan_id, :dispatch_failed,
              summary: @unparseable_verdict_summary,
              findings: []
            )
        end
    end
  end

  # Both branches above route through here, so `source: "handle_output"`
  # is stamped once. It is right for the unparseable branch too, and
  # that is the point: `state: "dispatch_failed", source: "handle_output"`
  # reads "the architect replied and we could not parse it", which is a
  # different fact from a `nil` source ("nothing came back at all"). That
  # is the one distinction `"source"` exists to carry — see `Plan`'s
  # moduledoc.
  defp apply_gate_resolution(plan_id, resolution, opts) do
    opts = Keyword.put_new(opts, :source, "handle_output")

    case Tasks.resolve_architecture_gate(plan_id, resolution, opts) do
      {:ok, _plan} ->
        Logger.info(
          "[architecture.review_plan] architecture gate resolved plan=#{plan_id} " <>
            "resolution=#{resolution} source=external"
        )

        :ok

      {:error, reason} ->
        # Never fatal. `:gate_not_open` is the ordinary state on a
        # dispatch that predates the gate, and `:gate_already_resolved`
        # is what a deadline that beat the model looks like.
        Logger.info(
          "[architecture.review_plan] architecture gate not settled plan=#{plan_id} " <>
            "resolution=#{resolution} reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[architecture.review_plan] architecture gate settlement raised plan=#{plan_id} " <>
          "reason=#{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[architecture.review_plan] architecture gate settlement exited plan=#{plan_id} " <>
          "reason=#{inspect(reason)}"
      )

      :ok
  end

  defp extract_plan_id(trigger_meta) when is_map(trigger_meta) do
    id =
      Map.get(trigger_meta, :plan_id) || Map.get(trigger_meta, "plan_id") ||
        case Map.get(trigger_meta, :plan) || Map.get(trigger_meta, "plan") do
          %Plan{id: id} -> id
          _ -> nil
        end

    if is_binary(id) and id != "", do: id, else: nil
  end

  defp plan_stage_ids(plan_id) do
    plan_id |> Tasks.list_stages() |> Enum.map(& &1.id)
  rescue
    _ -> []
  end

  defp verdict_object(%Plan{}), do: {:error, :unparseable}

  defp verdict_object(%{"verdict" => _} = output), do: {:ok, output}

  defp verdict_object(%{verdict: _} = output) do
    {:ok, Map.new(output, fn {k, v} -> {to_string(k), v} end)}
  end

  defp verdict_object(output) do
    case extract_comment(output) do
      binary when is_binary(binary) and binary != "" -> decode_embedded_json(binary)
      _ -> {:error, :unparseable}
    end
  end

  # Three candidates, cheapest first: the whole trimmed body, then each
  # fenced block, then the widest brace span. The external dispatcher
  # returns raw content — a model that wraps its JSON in a fence, or
  # narrates either side of it, is the common case, not the exception.
  defp decode_embedded_json(binary) do
    candidates = [String.trim(binary)] ++ fenced_blocks(binary) ++ brace_span(binary)

    Enum.find_value(candidates, {:error, :unparseable}, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{"verdict" => _} = map} -> {:ok, map}
        _ -> nil
      end
    end)
  end

  defp fenced_blocks(binary) do
    ~r/```(?:[a-zA-Z0-9_-]+)?[ \t]*\r?\n?(.*?)```/s
    |> Regex.scan(binary, capture: :all_but_first)
    |> Enum.map(fn [body] -> String.trim(body) end)
  end

  defp brace_span(binary) do
    with [{open, _} | _] <- :binary.matches(binary, "{"),
         [_ | _] = closes <- :binary.matches(binary, "}"),
         {close, _} <- List.last(closes),
         true <- close > open do
      [binary_part(binary, open, close - open + 1)]
    else
      _ -> []
    end
  end

  defp verdict_resolution(verdict) when is_binary(verdict) do
    case verdict |> String.trim() |> String.downcase() do
      "pass" -> {:ok, :pass}
      "reject" -> {:ok, :reject}
      _ -> {:error, :unparseable}
    end
  end

  defp verdict_resolution(_verdict), do: {:error, :unparseable}

  defp verdict_summary(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp verdict_summary(_summary), do: nil

  defp sanitize_findings(findings, stage_ids) when is_list(findings) do
    findings
    |> Enum.map(&sanitize_finding(&1, stage_ids))
    |> Enum.reject(&is_nil/1)
  end

  defp sanitize_findings(_findings, _stage_ids), do: []

  defp sanitize_finding(finding, stage_ids) when is_map(finding) do
    stage_id = finding_field(finding, "stage_id")
    constraint = finding_field(finding, "constraint")
    detail = finding_field(finding, "detail")

    if constraint in Plan.architecture_constraints() and stage_id in stage_ids and
         is_binary(detail) and String.trim(detail) != "" do
      %{"stage_id" => stage_id, "constraint" => constraint, "detail" => String.trim(detail)}
    end
  end

  defp sanitize_finding(_finding, _stage_ids), do: nil

  defp finding_field(finding, key) do
    case Map.get(finding, key) || Map.get(finding, String.to_existing_atom(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp load_plan(plan_id) when is_binary(plan_id) do
    Repo.get(Plan, plan_id)
  rescue
    _ -> nil
  end

  defp extract_task_id(trigger_meta) when is_map(trigger_meta) do
    Map.get(trigger_meta, :task_id) || Map.get(trigger_meta, "task_id") ||
      case Map.get(trigger_meta, :plan) || Map.get(trigger_meta, "plan") do
        %Plan{task_id: id} -> id
        _ -> nil
      end
  end

  defp ensure_task_id(id) when is_binary(id), do: :ok
  defp ensure_task_id(_), do: {:error, :missing_task_id}

  # The plan payload is no longer materialised here — `ContextProviders`
  # is the single per-slot resolver (task 019f9b28-6ca7 stage 1) and
  # `:plan_payload` is a slot like any other. A refusal propagates: the
  # Router's context-refusal arm stops the dispatch rather than sending
  # the architect an empty plan to review.
  defp do_gather_context(ctx) do
    case ContextProviders.gather_context(:plan_payload, ctx) do
      {:ok, %{plan_payload: payload}} ->
        {:ok,
         %{
           plan_payload: payload,
           sibling_tasks: fetch_sibling_tasks_slot(payload),
           adr_index: fetch_adr_index_slot(),
           similar_tasks: similar_tasks_hint(payload)
         }}

      {:error, reason} ->
        Logger.warning(
          "[architecture.review_plan] gather_context could not resolve a plan — " <>
            "refusing dispatch reason=#{inspect(reason)} keys=#{inspect(ctx_keys(ctx))}"
        )

        {:error, reason}
    end
  end

  defp ctx_keys(ctx) when is_map(ctx), do: Map.keys(ctx)
  defp ctx_keys(_ctx), do: []

  defp empty_context(reason) do
    %{
      plan_payload: %{
        missing?: true,
        error: reason,
        note: "no plan payload supplied (#{inspect(reason)})"
      },
      sibling_tasks: @empty_siblings,
      adr_index: @unavailable_adr_index,
      similar_tasks: []
    }
  end

  # The sibling walk is no longer materialised here either — it is the
  # `:sibling_tasks` slot on `ContextProviders`, which owns the
  # stack → epic → bounded-project-window ladder and every truncation
  # disclosure that goes with it.
  #
  # Unlike `:plan_payload` this slot NEVER refuses, and the difference
  # is deliberate. "This task has no siblings" is an ordinary, correct
  # state — a standalone task in a fresh project genuinely has none —
  # so refusing on it would stop the architect dispatch for the most
  # common shape in the system. Only `:plan_payload` is load-bearing
  # enough to refuse a dispatch over; the `case` below exists purely so
  # a future contract change can't silently crash the gather.
  #
  # Named `fetch_*_slot` rather than after the slot itself: this
  # function FETCHES a slot, it does not materialise one, and the two
  # used to be indistinguishable by name here. No private function in
  # this module is named after a context slot any more — the check that
  # ADR-0046 stack member 3 removed a resolver rather than adding a
  # fourth. The behavioural form of that check (each gathered slot is
  # byte-identical to `ContextProviders`' own output, which a rename
  # cannot satisfy) is in `architecture_context_bridge_test.exs`.
  defp fetch_sibling_tasks_slot(payload) do
    anchor = %{task_id: is_map(payload) && Map.get(payload, :task_id)}

    case ContextProviders.gather_context(:sibling_tasks, anchor) do
      {:ok, %{sibling_tasks: siblings}} ->
        siblings

      other ->
        Logger.warning(
          "[architecture.review_plan] sibling_tasks slot returned an unexpected shape: " <>
            "#{inspect(other)} — rendering an empty sibling block"
        )

        @empty_siblings
    end
  end

  # Probe for the (still-unlanded) `Tasks.similar_tasks/2`. It takes a
  # `%Plan{}`, so the plan is re-read from the payload's id — a query
  # that only ever runs once the helper actually exists.
  defp similar_tasks_hint(%{plan_id: plan_id}) when is_binary(plan_id) do
    if Code.ensure_loaded?(Tasks) and function_exported?(Tasks, :similar_tasks, 2) do
      case load_plan(plan_id) do
        %Plan{} = plan ->
          try do
            apply(Tasks, :similar_tasks, [plan, []])
          rescue
            _ -> []
          end

        _ ->
          []
      end
    else
      []
    end
  end

  defp similar_tasks_hint(_payload), do: []

  # The ADR walk is no longer materialised here either — it is the
  # `:adr_index` slot on `ContextProviders`, which owns the directory
  # resolution, the header parse, and the collision / supersession
  # flags. What used to be here emitted `%{file: name}` and nothing
  # else, and the prompt told the model to cite by number: this
  # directory has four numbers held by two ADRs each, so that
  # instruction produced confident citations of the wrong document.
  #
  # Like `:sibling_tasks`, this slot NEVER refuses. A prod release
  # image ships no `docs/` at all, so an unreachable index is the
  # steady state there — refusing on it would stop the architect
  # dispatching in production. It comes back `available?: false` with a
  # reason instead, and the renderer turns that into an explicit
  # instruction not to cite ADRs rather than into silence.
  defp fetch_adr_index_slot do
    case ContextProviders.gather_context(:adr_index, %{}) do
      {:ok, %{adr_index: index}} ->
        index

      other ->
        Logger.warning(
          "[architecture.review_plan] adr_index slot returned an unexpected shape: " <>
            "#{inspect(other)} — rendering the unavailable block"
        )

        @unavailable_adr_index
    end
  end

  # Turn the structured context map into a template-assigns map. Each
  # `{{variable}}` in the template gets a stringified block — the goal is
  # a readable prompt, not machine-parseable JSON.
  defp context_to_assigns(context) do
    %{
      plan_summary: format_plan_summary(Map.get(context, :plan_payload)),
      sibling_tasks: format_sibling_tasks(Map.get(context, :sibling_tasks, @empty_siblings)),
      open_prs: format_open_prs(Map.get(context, :open_prs, [])),
      adr_index: format_adr_index(Map.get(context, :adr_index, @unavailable_adr_index))
    }
  end

  defp format_plan_summary(nil), do: "(no plan summary available)"

  defp format_plan_summary(%{missing?: true} = payload) do
    "(no plan summary available — #{Map.get(payload, :note, "unknown")})"
  end

  defp format_plan_summary(%{} = payload) do
    stages = Map.get(payload, :stages) || []
    stage_lines = Enum.map_join(stages, "\n", &format_stage_line/1)

    """
    Task: #{Map.get(payload, :task_title) || "(untitled)"} (task_id: #{Map.get(payload, :task_id)})
    Task status: #{Map.get(payload, :task_status)}
    Task intent:
    #{format_task_description(Map.get(payload, :task_description))}

    plan_id: #{Map.get(payload, :plan_id)}
    Plan version: #{Map.get(payload, :plan_version)} (status: #{Map.get(payload, :plan_status)})
    Project: #{Map.get(payload, :project_id)}

    Stages (#{Map.get(payload, :stage_count, length(stages))}):
    #{stage_lines}
    """
    |> String.trim_trailing()
  end

  defp format_task_description(nil), do: "  (no task description recorded)"
  defp format_task_description(""), do: "  (no task description recorded)"

  defp format_task_description(description) when is_binary(description) do
    description
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  # The gates are the point: the architect must be able to tell a stage
  # that is protected from one that is not, and by what kind of gate.
  # Descriptions arrive pre-truncated from the `:plan_payload` slot —
  # re-truncating here would silently shrink the budget the slot sized.
  defp format_stage_line(stage) do
    pos = Map.get(stage, :position, "?")
    name = Map.get(stage, :name) || "(unnamed)"
    desc = Map.get(stage, :description) || ""
    status = Map.get(stage, :status) || "pending"

    header = "  - stage #{pos} — #{name} [#{status}]: #{desc}"

    # ADR-0046 member 5 stage 4: an id the model cannot see is an id it
    # invents, and `plan_architecture_verdict` refuses a finding whose
    # `stage_id` does not belong to the plan. Rendered defensively —
    # a payload without the key degrades to the old line rather than
    # printing `stage_id: `.
    [
      header,
      format_stage_id(Map.get(stage, :id)),
      format_gates(Map.get(stage, :validations) || [])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(format_e2e_expectations(Map.get(stage, :e2e_expected) || []))
    |> Enum.join("\n")
  end

  defp format_stage_id(id) when is_binary(id) and id != "", do: "    stage_id: #{id}"
  defp format_stage_id(_id), do: nil

  defp format_gates([]), do: "    gates: (none — this stage is unprotected)"

  defp format_gates(validations) when is_list(validations) do
    rendered =
      Enum.map_join(validations, ", ", fn validation ->
        "#{Map.get(validation, :kind)}(#{Map.get(validation, :status)})"
      end)

    "    gates: " <> rendered
  end

  defp format_e2e_expectations([]), do: []

  defp format_e2e_expectations(expectations) when is_list(expectations) do
    Enum.map(expectations, &"    e2e expects: #{&1}")
  end

  # The leading line is the point of the whole wrapper: it names which
  # of the three sibling tiers produced this list and, when a cap or a
  # filter dropped anything, says exactly how much. Absence must never
  # be silent — a model reads a short list as "there is nothing else",
  # not as "you were shown ten of sixty-three".
  defp format_sibling_tasks(%{tasks: []} = payload), do: sibling_scope_line(payload)

  defp format_sibling_tasks(%{tasks: tasks} = payload) when is_list(tasks) do
    Enum.join([sibling_scope_line(payload) | Enum.map(tasks, &format_sibling/1)], "\n\n")
  end

  defp format_sibling_tasks(_payload),
    do: "(sibling task list unavailable — the slot returned an unrecognised shape)"

  defp sibling_scope_line(%{scope: :no_anchor}),
    do: "[scope: no_anchor] sibling tasks unavailable — the trigger carried no resolvable task"

  defp sibling_scope_line(%{scope: :none} = payload) do
    "[scope: none] no sibling tasks — this task is in no stack and no epic, and its " <>
      "project has no other in-flight task with a submitted plan" <> unplanned_note(payload)
  end

  defp sibling_scope_line(%{scope: scope, total: 0}),
    do: "[scope: #{scope}] no sibling tasks — 0 other #{scope_noun(scope)}"

  defp sibling_scope_line(%{scope: scope} = payload) do
    counts =
      if payload.truncated? do
        "showing #{payload.shown} of #{payload.total} #{scope_noun(scope)}"
      else
        "#{payload.total} #{scope_noun(scope)}"
      end

    "[scope: #{scope}] " <> counts <> ", " <> scope_order(scope) <> unplanned_note(payload)
  end

  defp scope_noun(:stack), do: "stack members"
  defp scope_noun(:epic), do: "in-flight tasks in this epic"
  defp scope_noun(_scope), do: "in-flight tasks in this project"

  defp scope_order(:stack), do: "in stack position order"
  defp scope_order(:epic), do: "most recently created first"
  defp scope_order(_scope), do: "most recently updated first"

  defp unplanned_note(%{unplanned_excluded: count}) when is_integer(count) and count > 0 do
    " (a further #{count} in-flight task(s) in this project have no submitted plan and are " <>
      "omitted — no stage descriptions to collide with)"
  end

  defp unplanned_note(_payload), do: ""

  # Stage descriptions arrive pre-truncated from the `:sibling_tasks`
  # slot, same contract as the plan stages above — re-truncating here
  # would silently shrink the budget the slot sized.
  defp format_sibling(sibling) do
    stages = Map.get(sibling, :stages) || []

    stage_lines =
      Enum.map_join(stages, "\n", fn stage ->
        "    - #{Map.get(stage, :name) || "(unnamed)"}: #{Map.get(stage, :description) || ""}"
      end)

    stage_block =
      cond do
        stages != [] and Map.get(sibling, :truncated?) ->
          stage_lines <>
            "\n    (showing #{Map.get(sibling, :stages_shown)} of " <>
            "#{Map.get(sibling, :stage_count)} stages)"

        stages != [] ->
          stage_lines

        true ->
          "    (no stages yet)"
      end

    "- #{Map.get(sibling, :title) || "(untitled)"} " <>
      "(task_id: #{Map.get(sibling, :task_id)}, " <>
      "status: #{Map.get(sibling, :status)}, " <>
      stack_position_fragment(Map.get(sibling, :stack_position)) <>
      "latest_plan: #{Map.get(sibling, :latest_plan_status) || "n/a"})\n" <>
      stage_block
  end

  defp stack_position_fragment(position) when is_integer(position),
    do: "stack_position: #{position}, "

  defp stack_position_fragment(_position), do: ""

  defp format_open_prs([]),
    do: "(open PR list not gathered — this hook runs at plan submission, not at merge)"

  defp format_open_prs(prs) when is_list(prs) do
    Enum.map_join(prs, "\n", fn pr ->
      "- ##{Map.get(pr, :number, "?")} #{Map.get(pr, :title, "(untitled)")}"
    end)
  end

  # An unreadable index must arrive as an INSTRUCTION, not as silence.
  # A model handed an empty ADR block reads it as "this codebase has no
  # architectural decisions" and reasons from that; handed this line it
  # knows the walk failed and that any ADR it names would be invented.
  defp format_adr_index(%{available?: false} = payload) do
    "(ADR index unavailable — #{adr_unavailable_reason(Map.get(payload, :reason))}. " <>
      "Do not cite ADRs by number or filename in this pass; say the index was unavailable " <>
      "instead of naming a decision you cannot see.)"
  end

  defp format_adr_index(%{entries: entries} = payload) when is_list(entries) do
    Enum.join([format_adr_index_header(payload) | Enum.map(entries, &format_adr_entry/1)], "\n")
  end

  defp format_adr_index(_payload),
    do: "(ADR index unavailable — the slot returned an unrecognised shape)"

  defp adr_unavailable_reason(:adr_dir_empty),
    do: "`docs/decisions/` resolved but holds no `.md` files"

  defp adr_unavailable_reason(:adr_dir_unreadable),
    do: "`docs/decisions/` exists but could not be listed"

  defp adr_unavailable_reason(_reason),
    do: "`docs/decisions/` was not found — release images do not ship `docs/`"

  # The header carries the one instruction that makes the block usable:
  # cite by filename. `docs/decisions/` holds four numbers that name two
  # different ADRs each, so "ADR-0044" is not a reference — it is a
  # coin flip the model has no way of knowing it is making.
  defp format_adr_index_header(payload) do
    collisions = map_size(Map.get(payload, :number_collisions) || %{})
    total = Map.get(payload, :total, 0)
    shown = Map.get(payload, :shown, total)

    counts =
      if Map.get(payload, :truncated?) do
        "Showing the #{shown} highest-numbered of #{total} ADRs in `docs/decisions/` " <>
          "(#{Map.get(payload, :dropped, 0)} older ADR(s) omitted: " <>
          "#{Enum.join(Map.get(payload, :dropped_files) || [], ", ")})."
      else
        "All #{total} ADRs in `docs/decisions/`."
      end

    ambiguity =
      if collisions > 0 do
        " CITE ADRs BY FILENAME, NOT BY NUMBER — #{collisions} number(s) in this directory " <>
          "are each shared by more than one ADR, and the shared entries are flagged below."
      else
        " Cite ADRs by filename."
      end

    counts <> ambiguity
  end

  defp format_adr_entry(entry) do
    title = Map.get(entry, :title) || "(title not recorded)"
    status = Map.get(entry, :status) || "(status not recorded)"

    header = "- #{Map.get(entry, :file, "(unknown)")} — #{title} [#{status}]"

    Enum.join([header | adr_entry_flags(entry)], "\n")
  end

  defp adr_entry_flags(entry) do
    number_flag =
      if Map.get(entry, :number_ambiguous) do
        ["  ⚠ number #{Map.get(entry, :number)} is shared by another ADR — cite by filename"]
      else
        []
      end

    title_flag =
      if Map.get(entry, :title_ambiguous) do
        ["  ⚠ another ADR carries this same title — cite by filename"]
      else
        []
      end

    number_flag ++
      title_flag ++ Enum.map(Map.get(entry, :superseded_by) || [], &adr_supersession/1)
  end

  # A partial supersession is rendered as one, with the superseding
  # document's own words attached. ADR-0013 retired the attention-routing
  # SECTIONS of ADR-0008; reporting 0008 as dead would retire a live
  # decision, which is the same lie in the opposite direction.
  defp adr_supersession(%{partial?: true} = ref) do
    "  ⚠ partially superseded by #{Map.get(ref, :file)} — #{Map.get(ref, :note)}"
  end

  defp adr_supersession(ref) do
    "  ⚠ superseded by #{Map.get(ref, :file)}" <> adr_supersession_source(ref)
  end

  defp adr_supersession_source(%{source: :manual, note: note}) when is_binary(note),
    do: " (#{note})"

  defp adr_supersession_source(_ref), do: ""

  # Fallback interpolation when the DB row is missing — the hardcoded
  # default body carries the same `{{variable}}` placeholders, so we
  # apply the same mustache-style substitution PromptTemplates uses.
  defp interpolate_fallback("", _assigns), do: ""

  defp interpolate_fallback(content, assigns) when is_binary(content) do
    Regex.replace(~r/\{\{(\w+)\}\}/, content, fn _match, key ->
      value =
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(assigns, atom_key) || Map.get(assigns, key) || ""
        rescue
          ArgumentError -> Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  defp extract_comment(%{"comments" => [%{"content" => c} | _]}) when is_binary(c), do: c
  defp extract_comment(%{"comments" => [c | _]}) when is_binary(c), do: c
  defp extract_comment(%{"comment" => c}) when is_binary(c), do: c
  defp extract_comment(%{comment: c}) when is_binary(c), do: c
  defp extract_comment(str) when is_binary(str), do: str
  defp extract_comment(_), do: nil

  defp post_annotation(space_id, comment) when is_binary(space_id) and is_binary(comment) do
    case ExecutionSpace.post_log(space_id, format_annotation(comment)) do
      {:ok, _msg} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[architecture.review_plan] failed to post annotation space_id=#{space_id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_annotation(comment) when is_binary(comment) do
    prefix = "[architect] "

    if String.starts_with?(comment, prefix) do
      comment
    else
      prefix <> comment
    end
  end
end
