defmodule Platform.Responsibilities.Handlers.AgentsTeamCheck do
  @moduledoc """
  `agents.team_check` (task 01a1b6de stage 3): the lead agent's daily look at
  every agent on the install, and a short ask to the one human who can unstick
  each stuck one.

  The work is deterministic and happens in `gather_context/2`:
  `Platform.Agents.TeamCheck.statuses/1` reads presence and failure rows and
  classifies each agent with the pure
  `Platform.Agents.TeamCheck.Classifier.classify/1`. No model is called to
  classify. The leader's turn only phrases the asks for the agents
  `Platform.Agents.UnblockAsks` asked or re-asked on this fire (task 01a1b6de
  stage 4): each ask is an `agent_unblock_ask` Inbox item for the fixer, and
  the leader's message links to it. Stuck people (`PersonSetup`) are asked
  the same way, in their own Inbox.

  `build_prompt/1` REFUSES with `{:error, {:nothing_to_raise, reason}}` when no
  ask was sent, so a healthy install, or one whose stuck subjects were all
  asked within the re-ask interval, costs no turn.

  Granting access, rotating credentials or approving spend is NOT done here:
  the ask names who can and what to do.

  ## Data, not constants

    * schedule — `trigger_config` (`GoalCadence`), declared default daily at
      15:00 UTC. An admin cadence write marks it `operator_set` and it
      survives every boot's re-registration.
    * re-ask interval, offline threshold, lookback — `config :platform,
      Platform.Agents.TeamCheck` (72h, 120 min, 168h), overridden by the
      row's `metadata["operator_config"]`
      (`Responsibilities.put_operator_config/2`), which boot
      re-registration keeps. The re-ask interval is also the
      `agents.unblock_ask.reask_interval` experiment surface, which wins.

  ## Spec

    * `key` — `"agents.team_check"`
    * `feature` — `"agents"` (`Providers.Agents`)
    * `trigger_kind` — `cron`, default `"0 15 * * *"`
    * `scope` — `global`; dispatch gated on the `agents_leader` assignee
    * `default_prompt_template` — `"agents.team_check.v1"`
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Agents.TeamCheck
  alias Platform.Agents.UnblockAsks
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Responsibility

  @key "agents.team_check"
  @feature "agents"
  @template_slug "agents.team_check.v1"
  @default_expression "0 15 * * *"

  @system "You are the lead agent. The server has already checked every agent and " <>
            "classified what is blocking each stuck one; do not re-diagnose. For each " <>
            "agent listed, send its named fixer one short, direct message saying what " <>
            "to do. Never grant access, change credentials or approve spend yourself."

  @doc "Canonical key."
  def key, do: @key

  @doc "Canonical prompt template slug."
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # DEFAULT only: an operator cadence write carries "operator_set" and
        # is kept on every boot (`Responsibilities.upsert_by_key/1`).
        trigger_config: %{"expression" => @default_expression},
        scope: "global",
        context_provided: ["team_status", "raise_list"],
        output_contract: %{"asks" => "string"},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        # The interval, threshold and lookback defaults are config, not
        # declared metadata: what is declared here is replaced on every boot.
        metadata: %{
          "owner" => "platform.agents",
          "status" => "active",
          "role" => "agents_leader",
          "task" => "01a1b6de"
        }
      }
    ]
  end

  @impl true
  def gather_context(responsibility, ctx) do
    row = if match?(%Responsibility{}, responsibility), do: responsibility, else: nil
    now = (is_map(ctx) && Map.get(ctx, :now)) || DateTime.utc_now()
    {:ok, build_context(row, now)}
  end

  @doc """
  Statuses, the asks sent on this fire, and the rendered lines. The asks are
  `unblock_asks` rows (`UnblockAsks.sync_agents/2`, `sync_people/1`), so the
  next fire inside the interval does not ask again.

  `opts` are passed to both syncs and `TeamCheck.statuses/1`
  (`:federation`, `:users`, `:stuck_after_seconds`).
  """
  @spec build_context(Responsibility.t() | nil, DateTime.t(), keyword()) :: map()
  def build_context(row, now \\ DateTime.utc_now(), opts \\ []) do
    opts = Keyword.merge(opts, row: row, now: now)
    statuses = TeamCheck.statuses(Keyword.take(opts, [:row, :now, :federation]))

    sent =
      (UnblockAsks.sync_agents(statuses, opts) ++ UnblockAsks.sync_people(opts))
      |> Enum.filter(fn {outcome, _ask, _status} -> outcome in [:asked, :reasked] end)

    raise_list = Enum.map(sent, &raise_entry/1)

    %{
      statuses: statuses,
      raise: raise_list,
      reask_after_hours: TeamCheck.reask_after_hours(row),
      team_status: Enum.map_join(statuses, "\n", &status_line/1),
      raise_list: Enum.map_join(raise_list, "\n", &ask_line/1)
    }
  end

  defp raise_entry({_outcome, ask, %{agent_id: _} = status}),
    do: Map.merge(status, %{ask: ask, url: UnblockAsks.url(ask.id)})

  defp raise_entry({_outcome, ask, %{user: user}}) do
    %{
      agent_id: nil,
      person: user,
      ask: ask,
      url: UnblockAsks.url(ask.id),
      evidence: ask.evidence
    }
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    case Map.get(context, :raise) do
      [_ | _] ->
        {:ok, %{system: @system, user: render(context)}}

      _ ->
        {:error, {:nothing_to_raise, "no stuck agent is due to be raised"}}
    end
  end

  def build_prompt(_), do: {:error, {:nothing_to_raise, "no context"}}

  defp render(context) do
    assigns = %{
      "team_status" => Map.get(context, :team_status, ""),
      "raise_list" => Map.get(context, :raise_list, ""),
      "reask_after_hours" => to_string(Map.get(context, :reask_after_hours, ""))
    }

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, body} when is_binary(body) and body != "" ->
        body

      _ ->
        case PromptTemplates.render_default(@template_slug, assigns) do
          {:ok, body} -> body
          _ -> assigns["raise_list"]
        end
    end
  end

  @doc "One line per agent for the team view."
  def status_line(status) do
    "- #{status.agent_name} (#{status.kind}): #{status.class} — #{status.evidence}"
  end

  @doc "One line per ask sent: who, what is wrong, who fixes it, how, and its link."
  def ask_line(%{person: person, url: url} = entry) do
    "- #{person.name}: stuck on setup (#{entry.evidence}). Ask #{person.name} to " <>
      "finish those steps: #{url}"
  end

  def ask_line(status) do
    fixer =
      case status.fixer do
        %{name: name} when is_binary(name) -> name
        _ -> "the install owner (none is set)"
      end

    link = if is_binary(status[:url]), do: " The steps: #{status.url}", else: ""

    "- #{status.agent_name}: #{status.class} (#{status.evidence}). Ask #{fixer} to " <>
      "#{status.action}.#{link}"
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta), do: :ok

  @impl true
  def handle_refusal(_responsibility, refusal, _trigger_meta) do
    Logger.info("[agents.team_check] refused dispatch: #{inspect(refusal)}")
    :ok
  end
end
