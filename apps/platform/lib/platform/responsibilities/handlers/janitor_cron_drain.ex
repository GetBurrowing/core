defmodule Platform.Responsibilities.Handlers.JanitorCronDrain do
  @moduledoc """
  `janitor.cron_drain` responsibility provider (task `019fa1ac-6685` stage 1).

  The janitor pays down small internal chores on a schedule: the backlog
  tasks `architecture.cron_sweep` files (`metadata.filed_by ==
  "architect_cron_sweep"`) first, then other chores. This stage registers
  the responsibility and wires it through the Router; claiming
  (`Platform.Responsibilities.Janitor`, stage 2) and the hand-back path
  (stage 3) arrive later in the same task.

  ## Dispatch: the Responsibilities Router, nothing else

  This is a Router `cron` responsibility like `architecture.cron_sweep`. It
  is NOT a `Platform.Security.Sweeper`-style bespoke ticker and it adds no
  timer of its own: the Router's cron tick fires the row through
  `Router.fire_trigger/3`, the one funnel every trigger kind passes through.

  ## Schedule: Monday 06:00 UTC, two hours after the architect sweep

  `architecture.cron_sweep` stays weekly at Monday 04:00 UTC. It does a
  synchronous `gh pr list` and an LLM call per project, so it is not moved
  to nightly. The two-hour offset lets the sweep's capped follow-ups land in
  the backlog before this drain reads it.

  ## Assignment-gated firing, exactly as the architect

  Firing is gated on the `janitor` role having an assignee. Before calling
  any callback here, `Router.fire_trigger/3` resolves the assignee via
  `Platform.Roles.assignee_for/1`; when no agent holds the role it returns
  `{:ok, :unfilled}` without calling `gather_context/2`, `build_prompt/1`,
  the dispatcher, or `handle_output/3`. That is the same gate
  `Handlers.ArchitectureCronSweep` relies on, so there is no second in-handler
  check to drift from it. Assignment IS the enable signal.

  ## Spec

    * `key` — `"janitor.cron_drain"`
    * `feature` — `"janitor"`, resolved through the explicit
      `Platform.Responsibilities.Providers` registry to
      `Providers.Janitor`
    * `trigger_kind` — `cron` with `expression: "0 6 * * 1"`
    * `scope` — `global`. The plan calls this "installation scope";
      `global` is the `Responsibility.scopes/0` value that means it (one
      fire per installation, not per org or project)
    * `default_prompt_template` — `"janitor.cron_drain.v1"`
    * `cost_profile` — `low_freq_capable`

  ## Claiming (stage 2)

  `gather_context/2` is the one place the claim runs. The Router reaches it
  only after resolving a `janitor` assignee, so an unassigned janitor never
  claims. It resolves that same assignee again, calls
  `Platform.Responsibilities.Janitor.claim/1`, and renders ONLY the
  server-claimed task ids and titles into `claimed_tasks`; the claimed ids
  also travel as `claimed_task_ids`. A claim that rolls back refuses the
  dispatch (`{:error, {:janitor_claim_failed, reason}}`), so no prompt is
  ever built over a set the server did not commit. `handle_output/3`
  performs no writes.

  ## Routing, hand-back and audit (stage 3)

  After the claim commits, still inside `gather_context/2`:

    1. `Janitor.reconcile_stranded/1` ran FIRST, before the claim: a claim
       from an earlier run still sitting in `backlog` an hour on is handed
       back as `claim_not_routed`, so a run that died between claiming and
       routing cannot strand its tasks behind `handled_by: "janitor"`.
    2. `Janitor.route_claimed/2` moves exactly the claimed tasks
       `backlog -> planning` through `Tasks.transition_task/3`. From there
       the TaskRouter dispatches each to the planning assignee the claim
       set, and `auto_approve_plan: true` carries the plan into execution.
       A claim that cannot be routed is handed back on the spot. The
       janitor agent therefore never needs this dispatch to start the work:
       if the dispatch below fails, the routed tasks are already under the
       TaskRouter, not stranded in `backlog`.
    3. `Janitor.record_run/3` writes the run's claimed and refused outcomes
       to `audit_events` and a log line into each routed task's execution
       space. Hand-backs record themselves.

  Only ROUTED tasks reach the prompt. The model is told what the server
  selected; it selects nothing, and the hand-back it is told about
  (`janitor_hand_back`) acts only on a task the janitor claimed.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Janitor
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles

  @key "janitor.cron_drain"
  @feature "janitor"
  @template_slug "janitor.cron_drain.v1"
  @cron_expression "0 6 * * 1"

  # Per-run cap on tasks the janitor may pick up, mirroring the architect
  # sweep's own `@max_followups 3`. Enforced server-side by
  # `Janitor.claim/1`; read from there so the prompt and the claim agree.
  @max_tasks_per_run Janitor.max_tasks_per_run()

  @no_claimed_tasks "(none)"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The registered cron expression (Monday 06:00 UTC)."
  @spec cron_expression() :: String.t()
  def cron_expression, do: @cron_expression

  @doc "Per-run cap on claimed tasks."
  @spec max_tasks_per_run() :: pos_integer()
  def max_tasks_per_run, do: @max_tasks_per_run

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # Monday 06:00 UTC — two hours after `architecture.cron_sweep`
        # (`0 4 * * 1`). Dispatch is gated by the `janitor` role assignee
        # via `Roles.assignee_for/1` inside `Router.fire_trigger/3`.
        trigger_config: %{"expression" => @cron_expression},
        scope: "global",
        context_provided: [],
        output_contract: %{"summary" => "string"},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.janitor",
          "status" => "active",
          "role" => "janitor"
        }
      }
    ]
  end

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def gather_context(_responsibility, _ctx) do
    case Roles.assignee_for(@key) do
      %{id: agent_id} when is_binary(agent_id) ->
        _stranded = Janitor.reconcile_stranded()

        case Janitor.claim(agent_id: agent_id) do
          {:ok, result} ->
            routing =
              Janitor.route_claimed(result.claimed, agent_id: agent_id, run_id: result.run_id)

            Janitor.record_run(result, routing, agent_id: agent_id)
            {:ok, claimed_context(result, routing)}

          {:error, reason} ->
            {:error, {:janitor_claim_failed, reason}}
        end

      _unassigned ->
        # The Router gates on the assignee before calling here; reaching
        # this arm means the role was unassigned in between. Claim nothing.
        {:ok, do_gather_context()}
    end
  end

  @impl true
  @doc """
  Build the (system + user) messages for the dispatch. Firing is gated
  upstream at the Router by the `janitor` role assignee, so this always
  returns `{:ok, _}`.
  """
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    {:ok, %{system: system_prompt(), user: render_instruction(context)}}
  end

  @doc """
  The system turn. Distinct from the template body on purpose: a dispatch
  that carries this text went through `build_prompt/1`, one that does not
  fell back to the legacy template render.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    "You are the Janitor on the Burrow weekly chore-drain path. You work only the tasks the " <>
      "server claimed for you this run, at most #{@max_tasks_per_run}, and you hand back " <>
      "anything that is not small or that touches a protected area. " <>
      "The server has already moved each listed task into planning with you as its planning " <>
      "and execution assignee and plan auto-approval on, so the TaskRouter dispatches each one " <>
      "to you through the normal workflow; do not start, merge or deploy any task yourself. " <>
      "To hand a task back, call `janitor_hand_back` with its task_id, a reason " <>
      "(#{Enum.join(Janitor.hand_back_reasons() -- ["routing_refused", "stack_member", "claim_not_routed"], ", ")}), " <>
      "a one-line detail, and the paths you found. Finding a migration, vault.ex, auth, " <>
      "tenancy, secrets or deploy configuration in scope means you MUST hand it back."
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(%Responsibility{key: key}, _output, _trigger_meta) do
    Logger.info("[janitor] #{key} output received; no server-side writes in this build")
    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp do_gather_context do
    %{
      claimed_tasks: @no_claimed_tasks,
      claimed_task_ids: [],
      max_tasks_per_run: Integer.to_string(@max_tasks_per_run)
    }
  end

  # Only ROUTED claims reach the prompt: a claim handed back while routing
  # is no longer the janitor's to work.
  defp claimed_context(%{run_id: run_id}, %{routed: []}),
    do: Map.put(do_gather_context(), :janitor_run_id, run_id)

  defp claimed_context(%{run_id: run_id}, %{routed: routed}) do
    listing = Enum.map_join(routed, "\n", fn task -> "- #{task.id}: #{task.title}" end)

    %{
      do_gather_context()
      | claimed_tasks: listing,
        claimed_task_ids: Enum.map(routed, & &1.id)
    }
    |> Map.put(:janitor_run_id, run_id)
  end

  defp render_instruction(context) do
    assigns = %{
      "claimed_tasks" => to_string(Map.get(context, :claimed_tasks, @no_claimed_tasks)),
      "max_tasks_per_run" =>
        to_string(Map.get(context, :max_tasks_per_run, Integer.to_string(@max_tasks_per_run)))
    }

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, rendered} when is_binary(rendered) and rendered != "" ->
        rendered

      _ ->
        fallback = PromptTemplates.default_content_for_slug(@template_slug) || ""

        Enum.reduce(assigns, fallback, fn {name, value}, acc ->
          String.replace(acc, "{{#{name}}}", value)
        end)
    end
  end
end
