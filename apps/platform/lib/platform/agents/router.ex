defmodule Platform.Agents.Router do
  @moduledoc """
  Central model router for the Agent Runtime.

  The router is responsible for:

    * selecting the model chain from an agent's `model_config`
    * resolving provider credentials through `Platform.Vault.get/2`
    * dispatching to the correct provider adapter
    * failing over to configured fallback models when a call fails

  Model strings use the runtime convention `"provider/model"`, for example:

      "anthropic/claude-sonnet-4-6"
      "openai-codex/gpt-5.4"

  Per-model overrides live under `agent.model_config["models"][model_key]` and may
  specify provider options like `credential_slug`, `max_tokens`, `temperature`,
  or `metadata`.
  """

  alias Platform.Agents.Agent
  alias Platform.Agents.Providers.{Anthropic, OpenAI}
  alias Platform.Repo

  @provider_modules %{
    "anthropic" => Anthropic,
    "openai" => OpenAI
  }

  @provider_aliases %{
    "anthropic" => "anthropic",
    "openai" => "openai",
    "openai-codex" => "openai"
  }

  @default_credential_slugs %{
    "anthropic" => "anthropic-oauth",
    "openai" => "openai-oauth",
    "openai-codex" => "openai-oauth"
  }

  @type provider_action :: :chat | :stream
  @type candidate :: %{
          full_model: String.t(),
          provider_key: String.t(),
          provider: String.t(),
          model: String.t(),
          settings: map()
        }

  @doc """
  Route a chat request through the configured model chain for `agent_or_ref`.

  Options:

    * `:model` - override the primary model for this call
    * `:fallbacks` - override fallback models for this call
    * `:credential_slug` - override the Vault slug used for all attempts
    * `:credentials` - raw credentials map/string to bypass Vault resolution
    * `:system`, `:max_tokens`, `:temperature`, `:metadata` - forwarded to the provider
    * `:session_id` - included in fallback telemetry metadata when present
  """
  @spec chat(Agent.t() | Ecto.UUID.t() | String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def chat(agent_or_ref, messages, opts \\ []) when is_list(messages) do
    route(agent_or_ref, :chat, messages, opts)
  end

  @doc """
  Route a streaming request through the configured model chain for `agent_or_ref`.
  """
  @spec stream(Agent.t() | Ecto.UUID.t() | String.t(), [map()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(agent_or_ref, messages, opts \\ []) when is_list(messages) do
    route(agent_or_ref, :stream, messages, opts)
  end

  @doc """
  Return the resolved ordered model chain for an agent.
  """
  @spec model_chain(Agent.t() | Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def model_chain(agent_or_ref, opts \\ []) do
    with {:ok, agent} <- fetch_agent(agent_or_ref),
         {:ok, candidates} <- build_candidates(agent, opts) do
      {:ok, Enum.map(candidates, & &1.full_model)}
    end
  end

  defp route(agent_or_ref, action, messages, opts) when action in [:chat, :stream] do
    with {:ok, agent} <- fetch_agent(agent_or_ref),
         {:ok, candidates} <- build_candidates(agent, opts) do
      attempt_chain(agent, action, candidates, messages, opts, [])
    end
  end

  defp attempt_chain(_agent, _action, [], _messages, _opts, []),
    do: {:error, :no_models_configured}

  defp attempt_chain(_agent, _action, [], _messages, _opts, [failure]),
    do: {:error, failure.reason}

  defp attempt_chain(_agent, _action, [], _messages, _opts, failures),
    do: {:error, {:all_models_failed, Enum.reverse(failures)}}

  defp attempt_chain(agent, action, [candidate | rest], messages, opts, failures) do
    provider_opts = provider_opts(candidate, opts)

    with {:ok, provider_module} <- provider_module(candidate.provider),
         {:ok, credentials} <- resolve_credentials(agent, candidate, opts) do
      case apply(provider_module, action, [credentials, messages, provider_opts]) do
        {:ok, response} ->
          {:ok, decorate_response(response, candidate, failures)}

        {:error, reason} ->
          handle_attempt_failure(agent, action, candidate, rest, messages, opts, failures, reason)
      end
    else
      {:error, reason} ->
        handle_attempt_failure(agent, action, candidate, rest, messages, opts, failures, reason)
    end
  end

  defp handle_attempt_failure(agent, action, candidate, rest, messages, opts, failures, reason) do
    failure = %{
      model: candidate.full_model,
      provider: candidate.provider,
      reason: reason
    }

    case rest do
      [next | _] ->
        emit_fallback(agent, candidate, next, reason, opts)
        attempt_chain(agent, action, rest, messages, opts, [failure | failures])

      [] ->
        attempt_chain(agent, action, [], messages, opts, [failure | failures])
    end
  end

  defp build_candidates(%Agent{} = agent, opts) do
    model_config = normalize_map(agent.model_config || %{})
    models_config = normalize_map(Map.get(model_config, "models", %{}))

    chain =
      opts
      |> configured_chain(model_config)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    case chain do
      [] ->
        {:error, :no_models_configured}

      _ ->
        chain
        |> Enum.map(fn model_key ->
          settings = model_settings_for(models_config, model_key)
          build_candidate(model_key, settings)
        end)
        |> collect_candidates()
    end
  end

  defp configured_chain(opts, model_config) do
    case Keyword.get(opts, :model) do
      nil ->
        [Map.get(model_config, "primary") | List.wrap(Map.get(model_config, "fallbacks", []))]

      override ->
        [override | List.wrap(Keyword.get(opts, :fallbacks, []))]
    end
  end

  defp model_settings_for(models_config, model_key) do
    normalize_map(
      Map.get(models_config, model_key) || Map.get(models_config, model_name(model_key)) || %{}
    )
  end

  defp build_candidate(model_key, settings) when is_binary(model_key) do
    case String.split(model_key, "/", parts: 2) do
      [provider_key, model] when provider_key != "" and model != "" ->
        provider = canonical_provider(provider_key)

        {:ok,
         %{
           full_model: model_key,
           provider_key: provider_key,
           provider: provider,
           model: model,
           settings: settings
         }}

      _ ->
        {:error, {:invalid_model, model_key}}
    end
  end

  defp build_candidate(model_key, _settings), do: {:error, {:invalid_model, model_key}}

  defp collect_candidates(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(results, fn {:ok, candidate} -> candidate end)}
    end
  end

  defp resolve_credentials(%Agent{} = agent, candidate, opts) do
    case Keyword.get(opts, :credentials) do
      credentials when is_binary(credentials) ->
        {:ok, credentials}

      %{} = credentials ->
        {:ok, normalize_map(credentials)}

      nil ->
        candidate
        |> credential_slug(opts)
        |> fetch_vault_credentials(agent)

      _other ->
        {:error, :invalid_credentials}
    end
  end

  defp fetch_vault_credentials(nil, _agent), do: {:error, :missing_credentials}

  defp fetch_vault_credentials(slug, %Agent{} = agent) do
    case Platform.Vault.get(slug, accessor: {:agent, agent.id}) do
      {:ok, raw} -> {:ok, normalize_vault_payload(raw, slug)}
      {:error, reason} -> {:error, {:credential_error, slug, reason}}
    end
  end

  defp normalize_vault_payload(raw, slug) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = decoded} -> Map.put_new(decoded, "credential_slug", slug)
      _ -> %{"token" => raw, "credential_slug" => slug}
    end
  end

  defp credential_slug(candidate, opts) do
    Keyword.get(opts, :credential_slug) ||
      config_value(candidate.settings, "credential_slug") ||
      config_value(candidate.settings, "credentialSlug") ||
      config_value(candidate.settings, "vault_slug") ||
      config_value(candidate.settings, "vaultSlug") ||
      Map.get(@default_credential_slugs, candidate.provider_key) ||
      Map.get(@default_credential_slugs, candidate.provider)
  end

  defp provider_module(provider) do
    case Map.fetch(@provider_modules, provider) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  defp provider_opts(candidate, opts) do
    settings = candidate.settings

    metadata =
      settings
      |> config_value("metadata")
      |> normalize_map()
      |> deep_merge(normalize_metadata(Keyword.get(opts, :metadata)))
      |> maybe_put("router_model", candidate.full_model)

    []
    |> maybe_put_kw(:model, candidate.model)
    |> maybe_put_kw(:system, Keyword.get(opts, :system) || config_value(settings, "system"))
    |> maybe_put_kw(
      :max_tokens,
      Keyword.get(opts, :max_tokens) || config_value(settings, "max_tokens") ||
        config_value(settings, "maxTokens")
    )
    |> maybe_put_kw(
      :temperature,
      Keyword.get(opts, :temperature) || config_value(settings, "temperature")
    )
    |> maybe_put_kw(:metadata, metadata)
  end

  defp decorate_response(response, candidate, failures) when is_map(response) do
    route = %{
      model: candidate.model,
      full_model: candidate.full_model,
      provider: candidate.provider,
      provider_key: candidate.provider_key,
      attempted_models: Enum.reverse([candidate.full_model | Enum.map(failures, & &1.model)]),
      fallback_count: length(failures)
    }

    Map.put(response, :route, route)
  end

  defp decorate_response(response, _candidate, _failures), do: response

  defp emit_fallback(%Agent{} = agent, from_candidate, to_candidate, reason, opts) do
    :telemetry.execute(
      [:platform, :agent, :model_fallback],
      %{
        system_time: System.system_time(),
        retry_after_seconds: retry_after_seconds(reason)
      },
      %{
        agent_id: agent.id,
        session_id: Keyword.get(opts, :session_id),
        from_model: from_candidate.full_model,
        to_model: to_candidate.full_model,
        reason: inspect(reason)
      }
    )
  end

  defp retry_after_seconds({:rate_limited, retry_after, _body}),
    do: parse_retry_after(retry_after)

  defp retry_after_seconds({:credential_error, _slug, {:rate_limited, retry_after, _body}}),
    do: parse_retry_after(retry_after)

  defp retry_after_seconds(_reason), do: nil

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_integer(value) and value >= 0,
    do: value

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end

  defp parse_retry_after(_value), do: nil

  defp fetch_agent(%Agent{} = agent), do: {:ok, agent}

  defp fetch_agent(value) when is_binary(value) do
    cond do
      match?({:ok, _}, Ecto.UUID.cast(value)) ->
        case Repo.get(Agent, value) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :not_found}
        end

      true ->
        case Repo.get_by(Agent, slug: value) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :not_found}
        end
    end
  end

  defp fetch_agent(_other), do: {:error, :not_found}

  defp canonical_provider(provider_key) when is_binary(provider_key) do
    Map.get(@provider_aliases, provider_key, provider_key)
  end

  defp model_name(model_key) when is_binary(model_key) do
    case String.split(model_key, "/", parts: 2) do
      [_provider, model] -> model
      _ -> model_key
    end
  end

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(%{} = metadata), do: normalize_map(metadata)
  defp normalize_metadata(_value), do: %{}

  defp config_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp config_value(_map, _key), do: nil

  defp normalize_map(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_map(_value), do: %{}

  defp normalize_value(%{} = map), do: normalize_map(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value

  defp deep_merge(left, right) when map_size(left) == 0, do: right
  defp deep_merge(left, right) when map_size(right) == 0, do: left

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kw(list, _key, nil), do: list
  defp maybe_put_kw(list, _key, %{} = value) when map_size(value) == 0, do: list
  defp maybe_put_kw(list, key, value), do: Keyword.put(list, key, value)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
