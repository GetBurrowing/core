defmodule Platform.Responsibilities.Handlers.UxFrictionWatch do
  @moduledoc """
  `ux.friction_watch`: the UX job, one responsibility in the DESIGNER bundle
  (task 01a1af00 stage 2). It reads chat for UI friction, groups it, and
  files `ux_findings` rows: a `decision` for a human to answer, or an `fyi`
  held for the weekly digest. It never changes code.

  ## Triggers

    * cron, weekly, Monday 08:00 America/Chicago, scope `per_org`
      (registered like `Handlers.Hr`'s daily sweep);
    * on demand, `Platform.Responsibilities.Router.fire("ux.friction_watch", meta)`.

  Both go through `Router.fire_trigger/3`, which resolves the assignee with
  `Platform.Roles.assignee_for/1` BEFORE calling here: with nobody holding
  the key it returns `{:ok, :unfilled}` and this module is never called (the
  `Handlers.JanitorCronDrain` gate). `gather_context/2` resolves the
  assignee again and does nothing when the role was unassigned in between.

  ## Server-side, tool-less: the Router never dispatches a prompt

  `gather_context/2` runs the whole pass in server code
  (`Platform.Ux.FrictionWatch.run/2`) and returns `{:handled, summary}`; the
  Router answers `{:ok, :handled}` without building a prompt, waking a
  runtime or calling an endpoint. The one model call is tool-less
  (`Platform.Agents.ToollessChat`, the `feedback.intake` pattern), so the
  chat text it groups has nothing to talk a model into calling. No runtime
  tools, no file writes, no git. `build_prompt/1` and `handle_output/3`
  refuse, so a stray dispatch path aborts rather than reaching an agent's
  ordinary tool-bearing runtime.

  ## Privacy scope

  Only spaces the assigned agent participates in
  (`Platform.Chat.list_spaces_for_agent/2`, archived excluded) INTERSECTED
  with the Historian digest partition
  (`Platform.Chat.digest_eligible_messages_query/1`, default `:internal`
  scope, which omits external and mixed spaces; see
  `Platform.Chat.external_space_ids/0`). The same partition
  `Platform.People.Appearances.collect/3` reads. Details in
  `Platform.Ux.FrictionWatch`.

  ## Threshold and variants

  `grouping_threshold`, `min_occurrences` and the prompt directive come from
  the `ux.friction_detection` surface (`Platform.Experiments.Surfaces.UxFrictionDetection`),
  resolved per fire like `Handlers.Hr` resolves `hr.profile`.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Ux.FrictionWatch

  @key "ux.friction_watch"
  @feature "ux"
  @template_slug "ux.friction_watch.v1"
  @cron_expression "0 8 * * 1"
  @timezone "America/Chicago"

  @doc "Canonical key for this responsibility (equals the designer bundle key)."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The registered cron expression (Monday 08:00, America/Chicago)."
  @spec cron_expression() :: String.t()
  def cron_expression, do: @cron_expression

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        trigger_config: %{"expression" => @cron_expression, "timezone" => @timezone},
        scope: "per_org",
        context_provided: [],
        output_contract: %{
          "groups" => "list[object]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.ux",
          "role" => "designer",
          "executor" => "platform.ux.friction_watch",
          "denied" => ~w(runtime_tools file_write git code_edit task_create)
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{key: @key}, ctx) when is_map(ctx) do
    agent = safe_assignee()
    {:ok, summary} = FrictionWatch.run(agent, run_opts(ctx))

    Logger.info(
      "[ux.friction_watch] status=#{summary.status} signals=#{summary.signals} " <>
        "created=#{length(summary.created)} deduped=#{length(summary.deduped)} " <>
        "below_threshold=#{length(summary.below_threshold)} failed=#{length(summary.failed)}"
    )

    {:handled, summary}
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @doc "Refuses: the pass ran server-side in `gather_context/2`; there is no prompt to send."
  @impl true
  @spec build_prompt(map()) :: {:error, :ux_friction_watch_server_side}
  def build_prompt(_context), do: {:error, :ux_friction_watch_server_side}

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[ux.friction_watch] no agent output is consumed; the pass runs server-side. Discarded."
    )

    {:error, :ux_friction_watch_server_side}
  end

  defp run_opts(ctx) do
    [
      now: fetch(ctx, :fired_at),
      workspace_id: fetch(ctx, :workspace_id),
      org_id: fetch(ctx, :org_id),
      recipient_user_id: fetch(ctx, :recipient_user_id)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp fetch(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      %DateTime{} = at -> at
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp safe_assignee do
    Roles.assignee_for(@key)
  rescue
    _ -> nil
  end
end
