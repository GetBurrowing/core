defmodule Platform.Agents.ToollessChat do
  @moduledoc """
  One tool-less chat completion against an agent's provider. Task 01a0d415
  stage 3, the experimentation-layer ADR-0052.

  EXTRACTED from `Platform.Security.LlmEnrichment.call_provider/4`, not
  copied: that function now builds its two messages and calls this one, so
  there is a single body for "ask the agent's model for text, with no tools".
  `test/platform/security/llm_enrichment_test.exs` passing unmodified is the
  regression proof that the extraction moved behaviour and did not change it.

  ## Tool-less by construction

  Provider opts are built from an ALLOWLIST (`base_url`, `model`,
  `temperature`, `max_tokens`). Nothing else a caller passes reaches the
  provider — in particular a `:tools` key is dropped even when supplied. A
  caller cannot opt back into tool use through this module; that is the
  property the blind labeler (`Platform.Experiments.Labeler`) relies on,
  because its input carries untrusted mail text and a model with no tools
  has nothing to be talked into calling.

  ## Options

    * `:temperature`, `:max_tokens` — forwarded when non-nil.
    * `:log_tag` — prefix for every warning (default `"[Agents.ToollessChat]"`),
      so each caller keeps its own log prefix.
    * `:log_context` — appended after the event name in each warning
      (e.g. `"key=security.cve_scan"`), default `""`.

  `base_url` and `model` come from the agent, never from opts.

  ## Candidates, not migrated here

  Similar private helpers exist in `Platform.Meetings.IntentClassifier`
  (`call_provider/5`, intent_classifier.ex:1712), `Platform.Agents.QuickAgent`
  (quick_agent.ex:102) and `Platform.Org.TenantsSummary`
  (tenants_summary.ex:248). They are left alone (out of scope for task
  01a0d415) and are candidates for moving onto this module.
  """

  require Logger

  @allowed_opts [:temperature, :max_tokens]
  @default_log_tag "[Agents.ToollessChat]"

  @doc """
  Call `provider_module.chat/3` with `messages` and the agent's credentials.
  Returns `{:ok, content}` for a binary content reply and `:error` for every
  other outcome (error tuple, unexpected shape, raise or throw). Never raises.
  """
  @spec call(module(), map(), [map()], keyword()) :: {:ok, binary()} | :error
  def call(provider_module, agent, messages, opts \\ [])
      when is_atom(provider_module) and is_list(messages) and is_list(opts) do
    tag = Keyword.get(opts, :log_tag, @default_log_tag)
    context = Keyword.get(opts, :log_context, "")

    provider_opts = provider_opts(agent, opts)
    credentials = agent_credentials(agent)

    try do
      case provider_module.chat(credentials, messages, provider_opts) do
        {:ok, %{content: content}} when is_binary(content) ->
          {:ok, content}

        {:ok, %{"content" => content}} when is_binary(content) ->
          {:ok, content}

        {:ok, other} ->
          Logger.warning(
            "#{tag} provider returned unexpected shape #{context} shape=#{inspect(other)}"
          )

          :error

        {:error, reason} ->
          Logger.warning("#{tag} provider call failed #{context} reason=#{inspect(reason)}")

          :error
      end
    rescue
      exception ->
        Logger.warning("#{tag} provider raised #{context} — #{Exception.message(exception)}")

        :error
    catch
      kind, reason ->
        Logger.warning(
          "#{tag} provider caught #{context} kind=#{inspect(kind)} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  @doc """
  The provider opts `call/4` would pass. Public so a test can assert the
  allowlist directly; `call/4` uses exactly this.
  """
  @spec provider_opts(map(), keyword()) :: keyword()
  def provider_opts(agent, opts) do
    [
      base_url: Map.get(agent, :base_url),
      model: Map.get(agent, :model)
    ]
    |> Kernel.++(Enum.map(@allowed_opts, &{&1, Keyword.get(opts, &1)}))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Same "no auth by default" shape IntentClassifier uses — the Ollama
  # provider inspects `:api_key` on the credentials map only.
  defp agent_credentials(agent) do
    case Map.get(agent, :vault_key) do
      key when is_binary(key) and key != "" -> %{api_key: key}
      _ -> %{}
    end
  end
end
