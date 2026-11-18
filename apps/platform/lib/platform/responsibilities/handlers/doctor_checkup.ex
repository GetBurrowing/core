defmodule Platform.Responsibilities.Handlers.DoctorCheckup do
  @moduledoc """
  `doctor.checkup`: the doctor super agent's hourly look at install health.
  The one key in the `doctor` bundle.

  ## Trigger

  A Router cron, `0 * * * *` UTC (on the hour), `global` scope. Dispatch is
  gated on the `doctor` role having an assignee: `Router.fire_trigger/3`
  resolves it before calling anything here, so an unassigned doctor reads and
  heals nothing (`{:ok, :unfilled}`). Assignment is the enable signal.

  ## Heal first, then ask, then (maybe) think

  `gather_context/2` does the deterministic work, server side, before any
  model is involved:

    1. `Platform.Doctor.checkup/1` reads health (agents, stuck dispatches,
       unreachable responsibilities, held updates, agent host).
    2. Nothing found: `{:handled, %{healthy: true}}`. No dispatch, no tokens.
    3. `Platform.Doctor.heal/3` runs the closed list of safe heals.
    4. Every finding no agent may heal is put to the role's escalation human
       through `Platform.SuperAgents.escalate/4` (one DM message and one inbox
       row per question, asked once while the row is open).
    5. Only when something is left that needs diagnosis (an expired lease, an
       unreachable responsibility, or a question just asked) is the doctor
       agent dispatched, with the findings as its prompt. Otherwise the fire
       is `{:handled, summary}`.

  The model never decides whether a heal happens, and has no heal of its
  own: the prompt (`doctor.checkup.v1`) tells it to diagnose with read tools,
  write its diagnosis, and never stop, delete, roll back, deploy, migrate or
  change task status.

  ## Tool bundles

  `tool_bundles/0`: `context_read` (spaces and messages), `task` (task,
  lease and runtime-event reads for diagnosis), `memory` (its journal) and
  `messaging` (its diagnosis in the escalation DM). NOT `admin`: that bundle
  carries `admin_rpc`, `admin_restart`, `admin_deploy` and `admin_rollback`,
  and the server already reads what `admin_health` would.

  ## Output (external runtimes only)

  The Router calls `handle_output/3` only for a `kind: "external"` assignee.
  `{"summary", "escalations": [{"question", "detail"}]}`: each escalation is
  put to the escalation human like the server's own.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Doctor
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.SuperAgents

  @key "doctor.checkup"
  @feature "doctor"
  @template_slug "doctor.checkup.v1"
  @cron_expression "0 * * * *"
  @escalation_prefix "Doctor needs you: "
  @tool_bundles ~w(context_read task memory messaging)

  @system "You are the Doctor for this Burrow install. You diagnose; the server heals. " <>
            "Read with your tools, explain plainly, and never take a destructive action."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The registered cron expression (hourly, on the hour, UTC)."
  @spec cron_expression() :: String.t()
  def cron_expression, do: @cron_expression

  @doc "The tool bundles the doctor's runtime needs."
  @spec tool_bundles() :: [String.t()]
  def tool_bundles, do: @tool_bundles

  @doc "The inbox title prefix of every doctor escalation."
  @spec escalation_prefix() :: String.t()
  def escalation_prefix, do: @escalation_prefix

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        trigger_config: %{"expression" => @cron_expression},
        scope: "global",
        context_provided: ["findings", "report_space_id"],
        output_contract: %{"summary" => "string", "escalations" => "list[object]"},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.doctor",
          "status" => "active",
          "role" => Doctor.role(),
          "tool_bundles" => @tool_bundles
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = responsibility, _trigger_meta) do
    gather_context(responsibility, %{}, [])
  end

  @doc """
  `gather_context/2` with seams: `opts` is passed to `Doctor.checkup/1` and
  `Doctor.heal/3` (`:now`, `:restart`, `:reassess`); `opts[:checkup]` replaces
  the checkup itself (tests).
  """
  @spec gather_context(Responsibility.t(), map(), keyword()) ::
          {:ok, map()} | {:handled, map()}
  def gather_context(%Responsibility{} = responsibility, _trigger_meta, opts) do
    checkup = Keyword.get_lazy(opts, :checkup, fn -> Doctor.checkup(opts) end)

    if Doctor.healthy?(checkup) do
      {:handled, %{healthy: true}}
    else
      agent_id = assignee_id()
      user_id = SuperAgents.escalate_user_id(responsibility)
      result = Doctor.heal(checkup, agent_id, opts)
      asked = escalate_all(agent_id, user_id, result.escalations)

      summary = %{
        healed: length(result.healed),
        escalated: Enum.count(asked, &(&1 == {:ok, :asked})),
        findings: Doctor.render(checkup, result)
      }

      if needs_diagnosis?(checkup, asked) do
        {:ok,
         %{
           findings: summary.findings,
           report_space_id: report_space_id(agent_id, user_id)
         }}
      else
        {:handled, Map.delete(summary, :findings)}
      end
    end
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    assigns = %{
      "findings" => to_string(Map.get(context, :findings, "")),
      "report_space_id" => to_string(Map.get(context, :report_space_id) || "(none configured)")
    }

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, body} when is_binary(body) and body != "" ->
        {:ok, %{system: @system, user: body}}

      _ ->
        case PromptTemplates.render_default(@template_slug, assigns) do
          {:ok, body} -> {:ok, %{system: @system, user: body}}
          {:error, _} -> {:error, :template_missing}
        end
    end
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(%Responsibility{} = responsibility, output, _trigger_meta) do
    with {:ok, decoded} <- SuperAgents.decode(output) do
      escalations =
        decoded
        |> Map.get("escalations", [])
        |> List.wrap()
        |> Enum.flat_map(fn
          %{"question" => q} = e when is_binary(q) and q != "" ->
            [%{question: q, detail: to_string(e["detail"] || "")}]

          _ ->
            []
        end)

      escalate_all(assignee_id(), SuperAgents.escalate_user_id(responsibility), escalations)
      :ok
    end
  rescue
    error ->
      Logger.warning("[doctor.checkup] handle_output raised: #{Exception.message(error)}")
      {:error, :handle_output_failed}
  end

  # ── internals ──

  defp assignee_id do
    case Roles.assignee_for(@key) do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp escalate_all(agent_id, user_id, escalations) do
    Enum.map(escalations, fn %{question: question, detail: detail} ->
      if is_binary(agent_id) do
        SuperAgents.escalate(agent_id, user_id, question,
          detail: detail,
          prefix: @escalation_prefix,
          source: "doctor"
        )
      else
        {:skipped, :no_agent}
      end
    end)
  end

  # Expired leases and unreachable responsibilities need reading to explain;
  # a question just put to a human deserves the doctor's diagnosis beside it.
  # Standing human waits, healed crashes and already-open questions do not.
  defp needs_diagnosis?(checkup, asked) do
    checkup.expired_leases != [] or checkup.unreachable_responsibilities != [] or
      Enum.any?(asked, &(&1 == {:ok, :asked}))
  end

  defp report_space_id(agent_id, user_id) when is_binary(agent_id) and is_binary(user_id) do
    case SuperAgents.dm(agent_id, user_id) do
      {:ok, %{space_id: space_id}} -> space_id
      _ -> nil
    end
  end

  defp report_space_id(_agent_id, _user_id), do: nil
end
