defmodule Platform.Agents.Delegation do
  @moduledoc """
  Who can be handed work right now, and who cannot — with the reason
  (task `01a0b491-0718-7001-8bba-bf50f119bb13` stage 2).

  ## Eligibility keys on DECLARED RUNTIME FEATURES, not on "the agent is online"

  An agent's brain and its mouth are separate `agent_runtimes` rows
  (task 01a06686, see `Platform.Meetings.join_capability/1`). A voice
  worker joins LiveKit and declares `["meeting_voice"]`; the work runtime
  that answers dispatches declares its own list, commonly `[]`. So the
  same agent appears TWICE in `Federation.federation_status/0`, and a
  naive "list the online agents" would hand a coding stage to a process
  whose entire job is to speak in a meeting.

  ## HONESTY BOUND ON THAT FIELD — do not lose this

  `metadata["client_info"]["features"]`, read through
  `AgentRuntime.client_features/1`, is the RUNTIME'S OWN CLAIM.
  `tool_surface.ex` already prints the warning and it is repeated here
  because this module is the second reader: the field **cannot**
  discriminate a build that ships a capability from a build that does
  not — measured, the plugin builds either side of `63229eb` send an
  identical feature list (`Platform.Federation.federation_status/0`
  moduledoc). It is sufficient for exactly one distinction, which is the
  one made here: telling a voice worker apart from a work runtime. It is
  not sufficient to prove a build, and nothing in this module should ever
  be read as proof of one. `proven` and `client_build` are where that
  question is answered.

  ## Which direction this filter fails

  `client_supports?/2` fails CLOSED — an undeclared capability is never
  read as present. This module deliberately fails the OTHER way, and the
  asymmetry is the point: a runtime that declares nothing is treated as a
  WORK runtime, because the work runtime is the row that honestly
  declares `[]` and a closed reading would return the empty list on a
  live install. Only an affirmative, voice-only declaration removes a
  runtime. "Voice-only" means the runtime declared a non-empty feature
  list that is entirely within `@voice_only_features` — an agent with a
  voice row AND a work row is eligible, via the work row.

  ## Why `ineligible_agents/0` exists

  An agent silently missing from a list is indistinguishable from an
  agent that does not exist. Callers that render eligibility must be able
  to SHOW the reason, so the companion returns the stored `reason_kind`
  and the full `reason` sentence rather than leaving the caller to infer
  an absence. Exclusions are returned regardless of connectivity: the
  judgement is about the agent, not about whether its socket is up right
  now.
  """

  import Ecto.Query, warn: false

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.DelegationExclusion
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  # Features that, ON THEIR OWN, mark a runtime as a voice worker rather
  # than something that can be handed a stage. `meeting_transcript` rides
  # with `meeting_voice` on the same worker; a runtime declaring only
  # transcript duty is equally not a work runtime.
  @voice_only_features ~w(meeting_voice meeting_transcript)

  @typedoc "An eligible agent and the union of features its work runtimes declared."
  @type eligible :: {Agent.t(), [String.t()]}

  @typedoc "An excluded agent with the kind and the full sentence of its reason."
  @type ineligible :: {Agent.t(), String.t(), String.t()}

  @doc """
  Agents that have at least one CONNECTED work runtime and no exclusion row.

  Returns `{agent, declared_features}` pairs sorted by agent name, where
  `declared_features` is the union of the feature lists declared by that
  agent's connected work runtimes (a voice row's features are not folded
  in — it is not the row that would do the work).
  """
  @spec eligible_agents() :: [eligible()]
  def eligible_agents do
    work_features_by_agent = connected_work_features_by_agent()

    agent_ids = Map.keys(work_features_by_agent) -- excluded_agent_ids()

    agent_ids
    |> load_agents()
    |> Enum.map(fn agent -> {agent, Map.fetch!(work_features_by_agent, agent.id)} end)
    |> Enum.sort_by(fn {agent, _features} -> agent.name end)
  end

  @doc """
  Every excluded agent with the kind and full text of its stored reason.

  Sorted by agent name. Not filtered by connectivity — an exclusion is a
  judgement about the agent and stays true while its runtime is down,
  which is precisely when a caller is most likely to mistake absence for
  nonexistence.
  """
  @spec ineligible_agents() :: [ineligible()]
  def ineligible_agents do
    rows = Repo.all(from(e in DelegationExclusion, select: {e.agent_id, e.reason_kind, e.reason}))

    agents = rows |> Enum.map(&elem(&1, 0)) |> load_agents() |> Map.new(&{&1.id, &1})

    rows
    |> Enum.flat_map(fn {agent_id, kind, reason} ->
      case Map.fetch(agents, agent_id) do
        {:ok, agent} -> [{agent, kind, reason}]
        :error -> []
      end
    end)
    |> Enum.sort_by(fn {agent, _kind, _reason} -> agent.name end)
  end

  @doc """
  Whether a runtime's DECLARED features mark it as a voice-only worker.

  `false` for an empty or absent declaration — see the moduledoc on which
  direction this fails and why.
  """
  @spec voice_only_runtime?(AgentRuntime.t() | %{metadata: map()}) :: boolean()
  def voice_only_runtime?(runtime) do
    case AgentRuntime.client_features(runtime) do
      [] -> false
      features -> Enum.all?(features, &(&1 in @voice_only_features))
    end
  end

  @doc "The feature names that, alone, identify a voice worker."
  @spec voice_only_features() :: [String.t()]
  def voice_only_features, do: @voice_only_features

  # %{agent_id => [feature]} over connected, active, non-voice-only runtimes.
  defp connected_work_features_by_agent do
    from(r in AgentRuntime, where: r.status == "active" and not is_nil(r.agent_id))
    |> Repo.all()
    |> Enum.filter(&RuntimePresence.online?(&1.runtime_id))
    |> Enum.reject(&voice_only_runtime?/1)
    |> Enum.reduce(%{}, fn runtime, acc ->
      features = AgentRuntime.client_features(runtime)
      Map.update(acc, runtime.agent_id, features, &Enum.uniq(&1 ++ features))
    end)
  end

  defp excluded_agent_ids do
    Repo.all(from(e in DelegationExclusion, select: e.agent_id))
  end

  defp load_agents([]), do: []

  defp load_agents(ids) do
    Repo.all(from(a in Agent, where: a.id in ^ids))
  end
end
