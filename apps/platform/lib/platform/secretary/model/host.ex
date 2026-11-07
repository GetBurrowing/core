defmodule Platform.Secretary.Model.Host do
  @moduledoc """
  The secretary's ONLY model path (task 01a1b721 stage 2): one isolated,
  tool-less question to the install's own native agent, on that agent's own
  subscription login, through the agent host (`Platform.AgentHost.oneshot/3`,
  services/agent-host/src/oneshot.ts).

  Deterministic gate, in this order, before anything is sent:

    1. the agent is `Platform.Roles.assignee_for("secretary.evaluate")`. That
       key sits in the EXISTING `triage_officer` bundle only to name WHOSE
       login answers: no responsibility is fired, the responsibilities Router
       and its agent responder are never involved, and the agent's chat
       session never sees the prompt;
    2. `Platform.Agents.NativeAgents.managed?/1`: an external, federated or
       HTTP agent, or no assignee at all, is `{:error, :no_subscription_ai}`.
       The prompt never leaves this install's own host;
    3. the host reports the agent `running`;
    4. `Platform.Agents.NativeLogin.login_view/1` is neither `:api_key` nor
       `:unsupported`: an agent on a saved API key is `{:error,
       :no_subscription_ai}` without a host call.

  The host's own refusal is the authoritative API-key check (it reads the
  agent's env-file names, its Claude settings and the CLI's own login
  status); a refusal `api_key_login` is also `{:error,
  :no_subscription_ai}`. This gate is only the early one.

  Never logs the prompt or the answer.

  ## The prompt's INPUTS block

  The prompt carries its inputs as one JSON object between `inputs_open/0`
  and `inputs_close/0`, each on a line of its own:
  `{"today": "YYYY-MM-DD", "brief_max_lines": n, "items": [item]}`, an item
  being `{ref_type, ref_id, kind, title, text, source, member, mentioned,
  deadline_at, family}`. The prompt tells the model everything inside the
  block is untrusted data. The dev fake host answers from it
  (`Platform.AgentHost.FakeHost.oneshot_answer/2`).
  """

  alias Platform.Accounts.User
  alias Platform.AgentHost
  alias Platform.Agents.{Agent, NativeAgents, NativeLogin}
  alias Platform.Roles

  @responsibility "secretary.evaluate"
  @inputs_open "<<<SECRETARY_INPUTS"
  @inputs_close "SECRETARY_INPUTS>>>"

  @typedoc "What one answered question returns."
  @type answer :: %{
          text: String.t(),
          usage: AgentHost.usage(),
          agent_id: Ecto.UUID.t(),
          model_version: String.t()
        }

  @doc "The bundle key whose assignee's login answers."
  @spec responsibility() :: String.t()
  def responsibility, do: @responsibility

  @doc "The line that opens the prompt's INPUTS block."
  @spec inputs_open() :: String.t()
  def inputs_open, do: @inputs_open

  @doc "The line that closes the prompt's INPUTS block."
  @spec inputs_close() :: String.t()
  def inputs_close, do: @inputs_close

  @doc """
  Ask the secretary's agent `prompt` on behalf of `user`: `{:ok, answer}`,
  `{:error, :no_subscription_ai}` when the gate (or the host's API-key check)
  refuses, `{:error, :refused, reason}` for any other host refusal, or
  `{:error, :not_connected | :timeout | :failed | :unsupported_host}`.

  `opts` go to `Platform.AgentHost.oneshot/3` (`:timeout`,
  `:max_output_tokens`).
  """
  @spec request(User.t(), String.t(), keyword()) ::
          {:ok, answer()}
          | {:error, :no_subscription_ai}
          | {:error, :refused, String.t()}
          | {:error, :not_connected | :timeout | :failed | :unsupported_host}
  def request(%User{}, prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, agent} <- eligible_agent() do
      case AgentHost.oneshot(agent, prompt, opts) do
        {:ok, %{text: text, usage: usage}} ->
          {:ok,
           %{text: text, usage: usage, agent_id: agent.id, model_version: model_version(agent)}}

        {:error, :refused, "api_key_login"} ->
          {:error, :no_subscription_ai}

        other ->
          other
      end
    end
  end

  @doc """
  The agent whose login would answer, when it passes the gate: `{:ok, agent}`
  or `{:error, :no_subscription_ai}`. Sends nothing.
  """
  @spec eligible_agent() :: {:ok, Agent.t()} | {:error, :no_subscription_ai}
  def eligible_agent do
    with %Agent{} = agent <- Roles.assignee_for(@responsibility),
         true <- NativeAgents.managed?(agent),
         true <- match?(%{state: :running}, AgentHost.status(agent)),
         true <- subscription_login?(NativeLogin.login_view(agent)) do
      {:ok, agent}
    else
      _ -> {:error, :no_subscription_ai}
    end
  end

  defp subscription_login?(:api_key), do: false
  defp subscription_login?(:unsupported), do: false
  defp subscription_login?(_view), do: true

  @doc "`host:<agent_id>:<harness>`, the evaluations' `model_version`."
  @spec model_version(Agent.t()) :: String.t()
  def model_version(%Agent{id: id} = agent) do
    harness =
      case NativeAgents.get_managed_runtime(agent) do
        %{harness: harness} when is_binary(harness) -> harness
        _ -> "unknown"
      end

    "host:#{id}:#{harness}"
  end
end
