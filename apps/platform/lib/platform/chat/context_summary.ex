defmodule Platform.Chat.ContextSummary do
  @moduledoc """
  On-demand summary of what led to an agent's chat message, for a viewer
  arriving later. Task 01a0d8de stage 1 (the fallback behind the "Context"
  affordance when the agent supplied no context of its own).

  ## What the summariser may read

  Exactly what `Chat.list_messages/2` returns for:

    * the agent message's SPACE;
    * the agent message's THREAD, by the same rule as
      `Platform.Chat.AgentResponder.build_history/3`: `thread_id:` when the
      message is in a thread, else `top_level_only: true`. A top-level agent
      message never reads thread replies; a threaded one never reads the top
      level;
    * `before_id:` the agent message, so nothing at or after it is read;
    * `as_participant:` the VIEWER's participant row, so a viewer whose
      `history_visible_from` is set never gets a summary of messages from
      before their grant;
    * `scope:` the viewer's external scope;
    * `limit:` the arm's `max_messages`.

  Deleted messages are excluded by `list_messages/2` itself. A viewer
  participant from a different space is refused (`:not_a_participant`),
  since its grant would say nothing about this space.

  ## Provider call

  A DIRECT provider call, copied from `Platform.Meetings.Summarizer`
  (`call_llm/3`, `provider_adapter/1`, `llm_credentials/1` and its
  response-shape handling), not a responsibility dispatch: a dispatch hands
  the prompt to an agent runtime (minutes on a click) and that agent would
  receive messages scoped to the viewer's grant, which it may not hold.
  `Meetings.Summarizer` is not modified. Provider opts are built from a
  fixed allowlist (`system`, `model`, `max_tokens`, `temperature`,
  `base_url`), so no tool definitions can reach the provider.

  The provider is `Platform.Chat.ContextSummary.Config.summary/0`, varied by
  the `chat.context_summary` experiment surface. When the configured
  provider is `:none` the call is refused with `:not_configured` BEFORE any
  experiment is resolved: an experiment arm can change which configured
  provider is used, never turn on sending chat text to one.

  Test seam: app env `:chat_context_summary_provider` (a module with
  `chat/3`), the same shape as `:experiments_labeler_provider`. No config
  file sets it.

  ## Output

  Two or three lines, at most 400 characters, passed through
  `Platform.Security.ExternalContent.escape_mentions/1`: model output is
  untrusted text and must not carry a live mention token wherever it is
  later copied.

  ## Cache and telemetry

  Results are cached in `Platform.Chat.ContextSummaryCache` under
  `{message_id, scope_key}` (see `scope_key/3`). Every call emits
  `[:platform, :chat, :context_summary]` with measurements
  `%{latency_ms, input_messages}` and metadata
  `%{message_id, experiment_id, variant, cache, outcome}`.
  """

  require Logger

  alias Platform.Agents.Providers.Anthropic
  alias Platform.Agents.Providers.Ollama
  alias Platform.Agents.Providers.OpenAI
  alias Platform.Chat
  alias Platform.Chat.ContextSummary.Config
  alias Platform.Chat.ContextSummaryCache
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.ChatContextSummary, as: Surface
  alias Platform.Security.ExternalContent

  @surface_key "chat.context_summary"
  @max_chars 400
  @max_lines 3
  @max_line_chars 1_000
  @telemetry_event [:platform, :chat, :context_summary]

  @type result :: %{
          text: String.t(),
          source_message_ids: [Ecto.UUID.t()],
          experiment_id: Ecto.UUID.t() | nil,
          variant: String.t() | nil,
          generated_at: DateTime.t()
        }

  @doc """
  Summarise what led to `agent_msg` for `viewer_participant`.

  `opts`: `:scope` — the viewer's `%ExternalScope{}` or
  `%Platform.Access.Scope{}` (the LiveView's `external_scope`); nil means
  internal.

  Returns `{:ok, result}` or `{:error, :not_configured | :no_history |
  :not_a_participant | :deleted | term}`.
  """
  @spec summarize(Message.t(), Participant.t() | nil, keyword()) ::
          {:ok, result()} | {:error, term()}
  def summarize(%Message{} = agent_msg, viewer_participant, opts \\ []) do
    started = System.monotonic_time()
    scope = Keyword.get(opts, :scope)

    {outcome, cache, meta} =
      with :ok <- check_message(agent_msg),
           :ok <- check_viewer(agent_msg, viewer_participant),
           :ok <- check_configured() do
        key = {agent_msg.id, scope_key(agent_msg, viewer_participant, scope)}

        case ContextSummaryCache.fetch(key, fn ->
               generate(agent_msg, viewer_participant, scope)
             end) do
          {:hit, result} -> {result, :hit, result}
          {:miss, result} -> {result, :miss, result}
        end
      else
        error -> {error, :miss, error}
      end

    emit(agent_msg, started, cache, meta)
    outcome
  end

  @doc """
  The cache scope key: `{thread_key, grant_bound, external_scope_user}`.
  Everything that changes which messages the viewer may read, and nothing
  else.
  """
  @spec scope_key(
          Message.t(),
          Participant.t() | nil,
          ExternalScope.t() | Platform.Access.Scope.t() | nil
        ) :: tuple()
  def scope_key(%Message{} = agent_msg, viewer_participant, scope) do
    {thread_key(agent_msg), grant_bound(viewer_participant), external_key(scope)}
  end

  defp thread_key(%Message{thread_id: thread_id}) when is_binary(thread_id),
    do: {:thread, thread_id}

  defp thread_key(_msg), do: :top_level

  defp grant_bound(%Participant{history_visible_from: %DateTime{} = from}),
    do: DateTime.to_unix(from, :microsecond)

  defp grant_bound(_), do: :unbounded

  defp external_key(%ExternalScope{external?: true, user_id: user_id}), do: user_id

  # ChatLive's `@external_scope` is a `%Platform.Access.Scope{}` since task
  # 01a1386d-e528 stage 3. Matching only the struct above would key a guest's
  # summary as internal and share it with internal viewers, so the guest
  # predicate is asked explicitly.
  defp external_key(%Platform.Access.Scope{actor: %{id: user_id}} = scope)
       when is_binary(user_id) do
    if Platform.Access.Scope.guest?(scope), do: user_id
  end

  defp external_key(_), do: nil

  defp check_message(%Message{deleted_at: nil}), do: :ok
  defp check_message(_), do: {:error, :deleted}

  defp check_viewer(_msg, nil), do: :ok

  defp check_viewer(%Message{space_id: space_id}, %Participant{space_id: space_id}), do: :ok

  defp check_viewer(_msg, _participant), do: {:error, :not_a_participant}

  defp check_configured do
    if Config.enabled?(), do: :ok, else: {:error, :not_configured}
  end

  # ── Generation ─────────────────────────────────────────────────────

  defp generate(agent_msg, viewer, scope) do
    {experiment_id, variant, payload} = resolve_arm(agent_msg)
    cfg = effective_config(payload)

    history = history(agent_msg, viewer, scope, cfg.max_messages)

    if history == [] do
      {:error, :no_history}
    else
      messages = [%{role: "user", content: prompt(history, agent_msg)}]

      provider_opts =
        [
          system: cfg.system_prompt,
          model: cfg.model,
          max_tokens: cfg.max_tokens,
          temperature: cfg.temperature,
          base_url: cfg.base_url
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case call_llm(cfg, messages, provider_opts) do
        {:ok, text} ->
          case shape_output(text) do
            "" ->
              {:error, :empty_response}

            shaped ->
              {:ok,
               %{
                 text: shaped,
                 source_message_ids: Enum.map(history, & &1.id),
                 experiment_id: experiment_id,
                 variant: variant,
                 generated_at: DateTime.utc_now()
               }}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # The messages the summariser reads, oldest first. Public for the
  # thread/grant tests' positive controls only.
  def history(%Message{} = agent_msg, viewer, scope, limit) do
    thread_opts =
      if is_binary(agent_msg.thread_id),
        do: [thread_id: agent_msg.thread_id],
        else: [top_level_only: true]

    opts =
      thread_opts ++
        [
          before_id: agent_msg.id,
          limit: limit,
          as_participant: viewer,
          scope: scope
        ]

    agent_msg.space_id
    |> Chat.list_messages(opts)
    |> Enum.filter(&(is_binary(&1.content) and String.trim(&1.content) != ""))
    |> Enum.reverse()
  end

  defp resolve_arm(%Message{id: id}) do
    subject = Subject.new("message", id, %{})

    case Surfaces.resolve(@surface_key, @surface_key, subject) do
      {:variant, experiment, slug, payload} -> {experiment.id, slug, payload}
      {:default, payload} -> {nil, "default", payload}
      :none -> {nil, nil, control_payload()}
    end
  end

  defp control_payload do
    case Surface.control_payload(@surface_key, []) do
      {:ok, payload} -> payload
      _ -> %{}
    end
  end

  # The arm's payload over the configured defaults. `base_url` and
  # `api_key_env` belong to the configured provider only; an arm that names
  # a different provider uses that provider's default credentials.
  defp effective_config(payload) do
    cfg = Config.summary()
    provider = payload_provider(payload, cfg.provider)

    cfg =
      if provider == cfg.provider,
        do: cfg,
        else: %{cfg | base_url: nil, api_key_env: nil}

    %{
      cfg
      | provider: provider,
        model: Map.get(payload, "model", cfg.model),
        system_prompt: Map.get(payload, "system_prompt", cfg.system_prompt),
        max_messages: clamp_messages(Map.get(payload, "max_messages", cfg.max_messages)),
        max_tokens: Map.get(payload, "max_tokens", cfg.max_tokens)
    }
  end

  defp payload_provider(%{"provider" => p}, _default) when is_binary(p),
    do: Config.parse_provider(p)

  defp payload_provider(_payload, default), do: default

  defp clamp_messages(n) when is_integer(n), do: n |> max(1) |> min(30)
  defp clamp_messages(_), do: 20

  defp prompt(history, agent_msg) do
    lines = Enum.map_join(history, "\n", &line/1)

    "Messages before the agent's message, oldest first:\n\n" <>
      lines <> "\n\nThe agent's message:\n\n" <> line(agent_msg)
  end

  defp line(%Message{} = m) do
    author = m.author_display_name || "Unknown"
    content = m.content || ""

    content =
      if String.length(content) > @max_line_chars,
        do: String.slice(content, 0, @max_line_chars) <> "…",
        else: content

    "#{author}: #{content}"
  end

  @doc false
  # 2-3 lines, capped, mention tokens made inert. Public so the escape can
  # be asserted without a provider.
  def shape_output(text) when is_binary(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(@max_lines)
    |> Enum.join("\n")
    |> cap()
    |> ExternalContent.escape_mentions()
  end

  defp cap(text) do
    if String.length(text) > @max_chars,
      do: String.slice(text, 0, @max_chars - 1) <> "…",
      else: text
  end

  # ── Provider call: copied from Meetings.Summarizer (not modified) ───

  defp call_llm(%{provider: :none}, _messages, _opts), do: {:error, :not_configured}

  defp call_llm(%{provider: provider} = cfg, messages, opts) do
    credentials = llm_credentials(cfg)
    adapter = provider_adapter(provider)

    case adapter.chat(credentials, messages, opts) do
      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, %{content: [%{"text" => text} | _]}} ->
        {:ok, text}

      {:ok, %{"content" => [%{"text" => text} | _]}} ->
        {:ok, text}

      {:ok, other} ->
        Logger.warning("[ContextSummary] Unexpected LLM response shape: #{inspect(other)}")
        extract_text_from_response(other)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      Logger.warning("[ContextSummary] provider raised: #{Exception.message(exception)}")
      {:error, :provider_failed}
  end

  defp provider_adapter(provider) do
    case Application.get_env(:platform, :chat_context_summary_provider) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> builtin_adapter(provider)
    end
  end

  defp builtin_adapter(:anthropic), do: Anthropic
  defp builtin_adapter(:openai), do: OpenAI
  defp builtin_adapter(:ollama), do: Ollama

  defp builtin_adapter(other),
    do: raise(ArgumentError, "Unknown context summary provider: #{inspect(other)}")

  defp extract_text_from_response(%{content: content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.map(&(Map.get(&1, "text") || Map.get(&1, :text, "")))
      |> Enum.join("\n")

    if text == "", do: {:error, :empty_response}, else: {:ok, text}
  end

  defp extract_text_from_response(_), do: {:error, :unrecognized_response}

  defp llm_credentials(%{provider: :anthropic, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "anthropic"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :openai, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: "openai"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :ollama, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(_), do: %{}

  defp api_key_from_env(nil), do: nil
  defp api_key_from_env(name) when is_binary(name), do: System.get_env(name)

  # ── Telemetry ──────────────────────────────────────────────────────

  defp emit(%Message{id: id}, started, cache, result) do
    latency_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    {outcome, input_messages, experiment_id, variant} =
      case result do
        {:ok, %{source_message_ids: ids} = r} -> {:ok, length(ids), r.experiment_id, r.variant}
        {:error, reason} -> {outcome_reason(reason), 0, nil, nil}
        _ -> {:error, 0, nil, nil}
      end

    :telemetry.execute(
      @telemetry_event,
      %{latency_ms: latency_ms, input_messages: input_messages},
      %{
        message_id: id,
        experiment_id: experiment_id,
        variant: variant,
        cache: cache,
        outcome: outcome
      }
    )
  end

  defp outcome_reason(reason) when is_atom(reason), do: reason
  defp outcome_reason(_reason), do: :error
end
