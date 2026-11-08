defmodule Platform.Agents.AiConnect do
  @moduledoc """
  Get an agent ready to sign in to an AI plan (task 01a1b84b): the one step
  every Connect AI surface runs when the owner picks a provider, before the
  provider's own sign-in starts.

  `prepare/3` takes a target, either `:burrow` (the install's Burrow agent,
  `/setup/connect-ai`) or an `%Agent{}`, and a provider (`:claude_subscription`
  or `:codex`; `Platform.Agents.Burrow.harness_for/1` maps it to the harness).

  There is no shared or master connection. Each agent signs in on its own:
  this module only makes the agent native and starts it on the right harness,
  and the sign-in that follows is that agent's own (`claude auth login` or
  `codex login --device-auth`, run as the agent by the agent host). Nothing
  here reads, copies or falls back to Burrow's, another agent's or the
  install's credentials.
  """

  alias Platform.Agents.{Agent, Burrow, NativeAgents}

  @providers [:claude_subscription, :codex]

  @doc "The providers `prepare/3` accepts."
  @spec providers() :: [atom()]
  def providers, do: @providers

  @doc """
  Prepare `target` for `provider`, as `actor`.

    * `:burrow` delegates to `Platform.Agents.Burrow.ensure/2`, unchanged.
    * `%Agent{}`: `NativeAgents.adopt/3` turns a plain agent into a native one
      (an agent that is already native is left as it is), `NativeAgents.can_manage?/2`
      is checked again on the result, and `NativeAgents.run_on/2` applies the
      Burrow rule: a running agent keeps its harness, one that is not running
      and runs another harness is switched, and it is started.

  Returns `{:ok, agent}`, or `{:error, :forbidden | :unknown_provider | term()}`.
  """
  @spec prepare(map(), :burrow | Agent.t(), atom()) :: {:ok, Agent.t()} | {:error, term()}
  def prepare(actor, target, provider)

  def prepare(_actor, _target, provider) when provider not in @providers,
    do: {:error, :unknown_provider}

  def prepare(%{id: actor_id}, :burrow, provider) when is_binary(actor_id),
    do: Burrow.ensure(actor_id, Burrow.harness_for(provider))

  def prepare(actor, %Agent{} = agent, provider) do
    harness = Burrow.harness_for(provider)

    with {:ok, agent} <- NativeAgents.adopt(actor, agent, harness),
         true <- NativeAgents.can_manage?(actor, agent) || {:error, :forbidden} do
      NativeAgents.run_on(agent, harness)
    end
  end

  def prepare(_actor, _target, _provider), do: {:error, :forbidden}

  @doc """
  Record what an observation says about `agent`'s sign-in: a Codex agent
  first seen running is signed in to ChatGPT (`metadata["ai_login"] =
  %{"provider" => "chatgpt"}`). A no-op otherwise. Returns `:ok`.
  """
  @spec note_observed(Agent.t() | nil, map() | nil) :: :ok
  def note_observed(%Agent{} = agent, %{state: :running}) do
    case NativeAgents.get_managed_runtime(agent) do
      %{harness: "codex"} = runtime ->
        if is_nil(NativeAgents.ai_login(runtime)),
          do: NativeAgents.put_ai_login(agent, %{"provider" => "chatgpt"})

        :ok

      _ ->
        :ok
    end
  end

  def note_observed(_agent, _observed), do: :ok
end
