defmodule Platform.Meetings.IntentModel do
  @moduledoc """
  Which model the meeting intent classifier talks to (task 01a1e5da).

  The classifier used to take `base_url` and `model` off the
  `meetings.intent_classify` assignee only. A native agent has neither, so on
  an install without the Ollama env var every chunk raised inside the Ollama
  adapter and logged one "LLM call failed" warning. This module is the single
  place that decides the route; the classifier, the meeting top bar and
  `admin_health` all ask it rather than re-deriving the rule.

  `route/1` returns exactly one of:

    * `{:assignee, %{base_url: b, model: m}}` when
      `Platform.Agents.ModelRoute.endpoint/1` answers `{:ok, %{base_url: b,
      model: m}}` for the agent. That module holds the one endpoint rule
      (task 01a1e670); this is the path that already worked, unchanged.
    * `{:hosted, %{provider: p, module: mod, credentials: creds, model: m, base_url: b}}`
      when the assignee path is not usable and an install-level provider is
      configured under `config :platform, :meetings_intent_model`.
    * `{:error, :not_configured}` otherwise. No provider call is made.

  "Blank" means `nil`, `""` or whitespace only.

  The install-level setting is read through
  `Platform.Chat.ContextSummary.Config.read/2`, so it has the same shape as
  the chat context summary setting (`provider`, `model`, `base_url`,
  `api_key_env`), but it is a SEPARATE app-env key: turning on chat summaries
  must never start sending meeting transcripts to a provider, and vice versa.
  The default provider is `:none`; nothing is enabled implicitly.

  Credentials mirror `Platform.Chat.ContextSummary`: the env var NAMED by
  `api_key_env` wins, else the platform Vault slug (`"anthropic"` /
  `"openai"`); Ollama needs none. The starter allowance and native agents'
  own `anthropic-api-key` Vault rows are never used here.

  Test seam: `config :platform, :meetings_intent_provider, SomeModule`
  replaces the built-in adapter module on the hosted route.
  """

  alias Platform.Agents.ModelRoute
  alias Platform.Agents.Providers.Anthropic
  alias Platform.Agents.Providers.Ollama
  alias Platform.Agents.Providers.OpenAI
  alias Platform.Chat.ContextSummary.Config

  @responsibility "meetings.intent_classify"

  @defaults %{provider: :none, model: nil, base_url: nil, api_key_env: nil}

  @type route ::
          {:assignee, %{base_url: String.t() | nil, model: String.t()}}
          | {:hosted,
             %{
               provider: :anthropic | :openai | :ollama,
               module: module(),
               credentials: map(),
               model: String.t() | nil,
               base_url: String.t() | nil
             }}
          | {:error, :not_configured}

  @doc "The install-level intent model setting, as a map with atom keys."
  @spec config() :: map()
  def config, do: Config.read(:meetings_intent_model, @defaults)

  @doc "Resolve the model route for the given intent classifier assignee."
  @spec route(map() | nil) :: route()
  def route(agent) do
    case ModelRoute.endpoint(agent) do
      {:ok, endpoint} -> {:assignee, endpoint}
      {:error, :no_endpoint} -> hosted_route(config())
    end
  end

  @doc """
  `:ok`, `{:off, :not_configured}` or `{:off, :no_assignee}` for the current
  `meetings.intent_classify` assignee. An unassigned responsibility is the
  deliberate off state and is kept distinct from a missing model.
  """
  @spec status() :: :ok | {:off, :not_configured} | {:off, :no_assignee}
  def status do
    case Platform.Roles.assignee_for(@responsibility) do
      nil ->
        {:off, :no_assignee}

      agent ->
        case route(agent) do
          {:error, :not_configured} -> {:off, :not_configured}
          _ -> :ok
        end
    end
  end

  defp hosted_route(%{provider: :none}), do: {:error, :not_configured}

  defp hosted_route(%{provider: provider} = cfg)
       when provider in [:anthropic, :openai, :ollama] do
    {:hosted,
     %{
       provider: provider,
       module: adapter(provider),
       credentials: credentials(cfg),
       model: blank_to_nil(cfg.model),
       base_url: blank_to_nil(cfg.base_url)
     }}
  end

  defp hosted_route(_), do: {:error, :not_configured}

  defp adapter(provider) do
    case Application.get_env(:platform, :meetings_intent_provider) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> builtin_adapter(provider)
    end
  end

  defp builtin_adapter(:anthropic), do: Anthropic
  defp builtin_adapter(:openai), do: OpenAI
  defp builtin_adapter(:ollama), do: Ollama

  # Mirrors Platform.Chat.ContextSummary.llm_credentials/1.
  defp credentials(%{provider: :anthropic, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "anthropic"}
      key -> %{api_key: key}
    end
  end

  defp credentials(%{provider: :openai, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "openai"}
      key -> %{api_key: key}
    end
  end

  defp credentials(%{provider: :ollama, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{}
      key -> %{api_key: key}
    end
  end

  defp api_key_from_env(name) when is_binary(name) do
    if present?(name), do: blank_to_nil(System.get_env(name)), else: nil
  end

  defp api_key_from_env(_), do: nil

  defp present?(value), do: ModelRoute.present?(value)

  defp blank_to_nil(value), do: if(present?(value), do: value, else: nil)
end
