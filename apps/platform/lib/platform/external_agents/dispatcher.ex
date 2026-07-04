defmodule Platform.ExternalAgents.Dispatcher do
  @moduledoc """
  HTTP dispatch path for `:external` assignees (ADR-0041 M6 stage 5).

  Bridges a fired responsibility to an external (HTTP-delegated) agent.
  `Platform.Responsibilities.Router.fire_trigger/3` calls
  `dispatch/3` when the resolved assignee has `kind == "external"`;
  stage 6 wires the actual call site — for now `dispatch/3` is the
  isolated, testable seam.

  ## Pipeline

    1. Render `responsibility.default_prompt_template` with the
       supplied `context`. We first run `EEx.eval_string/2` so callers
       can use embedded Elixir if they want, then string-substitute
       any leftover `{key}` placeholders against `context` keys (this
       mirrors the fallback shape `HistorianDispatcher.post_instruction`
       uses when the named prompt template can't be resolved).
    2. POST to either `openai_compat` (`<base_url>/chat/completions`)
       or `ollama_native` (`<base_url>/api/chat`). Bearer auth is
       resolved via `Platform.ExternalAgents.resolve_credential/1`
       for `openai_compat`; `ollama_native` sends no auth header by
       default.
    3. Parse the assistant's response content with the per-endpoint
       shape (`choices[0].message.content` vs `message.content`).
    4. Validate the response against the responsibility's
       `output_contract` via
       `Platform.ExternalAgents.ContractValidator.validate/2`.

  ## HTTP config

    * `receive_timeout: 60_000`
    * `connect_timeout: 10_000`
    * `retry: false`

  Networking errors surface as `{:error, %Req.TransportError{}}` so
  the caller can log + telemetry them. We do **not** retry —
  retries belong in the caller (or a future job runner), not here.

  ## Test seam

  The `Req` client is injectable via the
  `:external_agents_dispatcher_req_client` application env key, mirroring
  the `:external_agents_req_client` seam used by `ExternalAgents.probe/1`.

  ## Telemetry

    * `[:platform, :external_agent, :called]` on success, measurements
      `%{duration_ms: ms}`, metadata
      `%{endpoint_kind:, agent_slug:, responsibility_key:}`.
    * `[:platform, :external_agent, :error]` on failure, same metadata
      plus `:reason`.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Agents.Kind, as: AgentKind
  alias Platform.ExternalAgents
  alias Platform.ExternalAgents.ContractValidator
  alias Platform.Responsibilities.Responsibility

  # Task 019f2566 stage 3 — reserved context key carrying the resolved
  # `Platform.Agents.Kind.classify/1` atom. Providers' `build_prompt/1`
  # and `build_messages/1` implementations key off this to template
  # runtime-specific preambles (e.g. Dalton gets a "fire off to a
  # subagent" note; Hermione gets nothing extra). Values:
  # `:ext_single_responsibility | :fed_conversational | :loc_built_in`.
  @agent_kind_key :agent_kind

  @receive_timeout_ms 60_000
  @connect_timeout_ms 10_000

  # Task 019f2570 bug 2 fix — the OpenAI-compat concierge at dev-host:8084
  # applies its own ~800-token default when `max_tokens` is absent from
  # the request body, which truncates meeting summaries mid-sentence.
  # We now ALWAYS send `max_tokens` on external dispatch. Per-
  # responsibility overrides ride on `metadata["max_tokens"]` (see
  # `Handlers.MeetingSummarize.register/0`); every other responsibility
  # falls through to this constant. Code-side (not `Application.get_env`)
  # so ops can grep it out of the release without an env-var round trip.
  @default_external_max_tokens 2500

  @type dispatch_result :: {:ok, term()} | {:error, term()}

  @type dispatch_opts :: [
          messages: [map()],
          prompt: %{system: String.t(), user: String.t()}
        ]

  @doc """
  Dispatch a fired responsibility to an external agent.

  Returns `{:ok, parsed}` where `parsed` is whatever the configured
  `output_contract` resolves the response body to:

    * `:freeform` (default) — the raw assistant content string
    * `:json` — the decoded JSON map

  Failure modes:

    * `{:error, :missing_credentials}` — the credential resolver returned
      `:not_found` for an `openai_compat` agent
    * `{:error, {:http_error, status, body}}` — non-2xx response
    * `{:error, %Req.TransportError{}}` — connection / timeout
    * `{:error, {:contract_violation, reason}}` — response failed the
      output-contract check

  Delegates to `dispatch/4` with empty opts — backward compatible.
  """
  @spec dispatch(Responsibility.t(), Agent.t() | map(), map()) :: dispatch_result()
  def dispatch(%Responsibility{} = responsibility, agent, context) when is_map(context) do
    dispatch(responsibility, agent, context, [])
  end

  @doc """
  Dispatch with an optional `opts` payload that lets the caller inject
  a pre-built prompt (task 019f2570 bug 1 fix).

  Recognised options:

    * `messages: [%{role: "system"|"user", content: "..."}]` — pass the
      raw OpenAI-shaped messages list directly to `request_body/2`.
      Skips the `default_prompt_template` render entirely.

    * `prompt: %{system: sys, user: user}` — sugar for the same. When
      only `user` is meaningful, `system` may be an empty string; the
      request body then omits the system turn.

  When neither option is supplied the legacy path renders
  `responsibility.default_prompt_template` against `context` (backward
  compatible with every pre-019f2570 caller).
  """
  @spec dispatch(Responsibility.t(), Agent.t() | map(), map(), dispatch_opts()) ::
          dispatch_result()
  def dispatch(%Responsibility{} = responsibility, agent, context, opts)
      when is_map(context) and is_list(opts) do
    started_at = System.monotonic_time()

    context = ensure_agent_kind(context, agent)
    messages = resolve_messages(responsibility, context, opts)

    with {:ok, body} <- post(agent, messages, responsibility),
         {:ok, content} <- parse_response(agent, body),
         {:ok, validated} <- ContractValidator.validate(content, responsibility.output_contract) do
      emit_telemetry(
        [:platform, :external_agent, :called],
        %{duration_ms: elapsed_ms(started_at)},
        %{
          endpoint_kind: endpoint_kind(agent),
          agent_slug: agent_slug(agent),
          responsibility_key: responsibility.key
        }
      )

      {:ok, validated}
    else
      {:error, reason} = err ->
        emit_telemetry(
          [:platform, :external_agent, :error],
          %{duration_ms: elapsed_ms(started_at)},
          %{
            endpoint_kind: endpoint_kind(agent),
            agent_slug: agent_slug(agent),
            responsibility_key: responsibility.key,
            reason: inspect(reason)
          }
        )

        err
    end
  end

  # Prefer explicit messages > explicit prompt map > legacy template render.
  # Always returns a `[%{role:, content:}]` list ready to hand to `post/2`.
  defp resolve_messages(responsibility, context, opts) when is_list(opts) do
    cond do
      is_list(opts[:messages]) and opts[:messages] != [] ->
        opts[:messages]

      is_map(opts[:prompt]) ->
        prompt_to_messages_or_legacy(opts[:prompt], responsibility, context)

      true ->
        legacy_messages(responsibility, context)
    end
  end

  defp prompt_to_messages_or_legacy(%{system: sys, user: user}, _r, _c)
       when is_binary(sys) and is_binary(user) do
    case sys do
      "" -> [%{role: "user", content: user}]
      _ -> [%{role: "system", content: sys}, %{role: "user", content: user}]
    end
  end

  defp prompt_to_messages_or_legacy(%{user: user}, _r, _c) when is_binary(user),
    do: [%{role: "user", content: user}]

  defp prompt_to_messages_or_legacy(_bad, responsibility, context),
    do: legacy_messages(responsibility, context)

  defp legacy_messages(%Responsibility{default_prompt_template: template}, context) do
    prompt = render_prompt(template, context)
    {system_prompt, user_prompt} = split_prompt(prompt)

    case system_prompt do
      nil -> [%{role: "user", content: user_prompt}]
      sys -> [%{role: "system", content: sys}, %{role: "user", content: user_prompt}]
    end
  end

  # ── Prompt rendering ──────────────────────────────────────────────────────

  defp render_prompt(nil, _context), do: ""

  defp render_prompt(template, context) when is_binary(template) and is_map(context) do
    bindings = context_to_bindings(context)

    rendered_eex =
      try do
        EEx.eval_string(template, bindings)
      rescue
        # EEx may fail on user-supplied content that isn't real EEx — fall back
        # to the literal template and let the `{key}` substitution pass do
        # its work.
        _ -> template
      end

    substitute_placeholders(rendered_eex, context)
  end

  defp render_prompt(_template, _context), do: ""

  defp context_to_bindings(context) do
    Enum.flat_map(context, fn
      {k, v} when is_atom(k) -> [{k, v}]
      {k, v} when is_binary(k) -> bindings_from_string_key(k, v)
      _ -> []
    end)
  end

  # Only atomize string keys that are valid identifiers AND already exist as
  # atoms — never `String.to_atom/1` user input (memory leak).
  defp bindings_from_string_key(k, v) do
    try do
      atom = String.to_existing_atom(k)
      [{atom, v}]
    rescue
      ArgumentError -> []
    end
  end

  defp substitute_placeholders(content, context) do
    Regex.replace(~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/, content, fn whole, key ->
      case fetch_context(context, key) do
        :not_found -> whole
        {:ok, value} -> to_string(value)
      end
    end)
  end

  defp fetch_context(context, key) do
    cond do
      Map.has_key?(context, key) ->
        {:ok, Map.get(context, key)}

      match?({:ok, _}, atom_lookup(context, key)) ->
        atom_lookup(context, key)

      true ->
        :not_found
    end
  end

  defp atom_lookup(context, key) do
    try do
      atom = String.to_existing_atom(key)

      if Map.has_key?(context, atom) do
        {:ok, Map.get(context, atom)}
      else
        :not_found
      end
    rescue
      ArgumentError -> :not_found
    end
  end

  # ── HTTP ──────────────────────────────────────────────────────────────────

  defp post(agent, messages_or_legacy, responsibility \\ nil) do
    url = request_url(agent)
    headers = request_headers(agent)
    body = request_body(agent, messages_or_legacy, responsibility)

    case Req.post(req_client(),
           url: url,
           json: body,
           headers: headers,
           receive_timeout: @receive_timeout_ms,
           connect_options: [timeout: @connect_timeout_ms],
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_url(agent) do
    base = base_url(agent) |> String.trim_trailing("/")

    case endpoint_kind(agent) do
      "openai_compat" -> base <> "/chat/completions"
      "ollama_native" -> base <> "/api/chat"
    end
  end

  defp request_headers(agent) do
    base = [{"content-type", "application/json"}]

    case endpoint_kind(agent) do
      "openai_compat" ->
        case resolve_token(agent) do
          {:ok, token} when is_binary(token) and token != "" ->
            [{"authorization", "Bearer #{token}"} | base]

          _ ->
            base
        end

      "ollama_native" ->
        # Ollama uses no auth by default; if a deployment fronts it with an
        # auth proxy, that's still a future-config concern, not this path.
        base
    end
  end

  # Symmetric with `ExternalAgents.probe/1`'s lazy lookup — `resolve_credential/1`
  # has landed via M3 but the function_exported? guard keeps us robust against
  # stripped builds the way the planner's contract requires.
  defp resolve_token(agent) do
    if Code.ensure_loaded?(ExternalAgents) and
         function_exported?(ExternalAgents, :resolve_credential, 1) do
      case ExternalAgents.resolve_credential(agent) do
        {:ok, secret} when is_binary(secret) -> {:ok, secret}
        _ -> :not_found
      end
    else
      :not_found
    end
  end

  # `messages` is already a pre-shaped list of `%{role:, content:}` maps
  # (assembled by `resolve_messages/3` — either from opts, or by
  # rendering the legacy `default_prompt_template`).
  #
  # `max_tokens` is ALWAYS included (task 019f2570 bug 2 fix). Per-
  # responsibility hint takes precedence; otherwise falls back to
  # `@default_external_max_tokens`. Keeps the OpenAI-compat concierge
  # from applying its own ~800-token default and truncating outputs.
  defp request_body(agent, messages, responsibility \\ nil) when is_list(messages) do
    %{
      model: model(agent),
      messages: messages,
      stream: false,
      max_tokens: max_tokens_for(responsibility)
    }
  end

  defp max_tokens_for(%Responsibility{metadata: metadata}) when is_map(metadata),
    do: metadata_max_tokens(metadata) || @default_external_max_tokens

  defp max_tokens_for(%{metadata: metadata}) when is_map(metadata),
    do: metadata_max_tokens(metadata) || @default_external_max_tokens

  defp max_tokens_for(metadata) when is_map(metadata),
    do: metadata_max_tokens(metadata) || @default_external_max_tokens

  defp max_tokens_for(_), do: @default_external_max_tokens

  defp metadata_max_tokens(metadata) when is_map(metadata) do
    raw = Map.get(metadata, "max_tokens") || Map.get(metadata, :max_tokens)

    case raw do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp metadata_max_tokens(_), do: nil

  # Convention: if the rendered prompt has a `<system>...</system>` block at the
  # head, that block becomes the system message and the rest is the user turn.
  # This keeps the dispatcher honest about the OpenAI chat shape without forcing
  # callers to split their template into two fields. Absent the marker, the
  # whole prompt is one user message.
  defp split_prompt(prompt) when is_binary(prompt) do
    case Regex.run(~r/\A\s*<system>(.*?)<\/system>\s*(.*)\z/s, prompt, capture: :all_but_first) do
      [system, rest] -> {String.trim(system), String.trim(rest)}
      _ -> {nil, prompt}
    end
  end

  defp split_prompt(_), do: {nil, ""}

  # ── Response parsing ──────────────────────────────────────────────────────

  defp parse_response(agent, body) do
    case endpoint_kind(agent) do
      "openai_compat" -> parse_openai_compat(body)
      "ollama_native" -> parse_ollama_native(body)
    end
  end

  defp parse_openai_compat(%{"choices" => choices}) when is_list(choices) do
    case List.first(choices) do
      nil -> {:error, :empty_choices}
      choice -> {:ok, get_in(choice, ["message", "content"]) || ""}
    end
  end

  defp parse_openai_compat(_), do: {:error, :unparseable_response}

  defp parse_ollama_native(%{"message" => %{"content" => content}}) when is_binary(content),
    do: {:ok, content}

  defp parse_ollama_native(_), do: {:error, :unparseable_response}

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Task 019f2566 stage 3 — reserved-key merge. If the router-provided
  # context already carries `:agent_kind` (populated by
  # `Handlers.MeetingSummarize.gather_context/2` and friends), we
  # respect it. Otherwise we classify from the agent the dispatcher was
  # handed. Belt+braces — every downstream template render sees a
  # non-nil kind.
  defp ensure_agent_kind(context, agent) when is_map(context) do
    case Map.get(context, @agent_kind_key) do
      nil -> Map.put(context, @agent_kind_key, AgentKind.classify(agent))
      _ -> context
    end
  end

  defp endpoint_kind(%Agent{endpoint_kind: kind}), do: kind
  defp endpoint_kind(%{endpoint_kind: kind}), do: kind
  defp endpoint_kind(%{"endpoint_kind" => kind}), do: kind

  defp base_url(%Agent{base_url: url}), do: url
  defp base_url(%{base_url: url}), do: url
  defp base_url(%{"base_url" => url}), do: url

  defp model(%Agent{model: model}), do: model
  defp model(%{model: model}), do: model
  defp model(%{"model" => model}), do: model

  defp agent_slug(%Agent{slug: slug}), do: slug
  defp agent_slug(%{slug: slug}), do: slug
  defp agent_slug(%{"slug" => slug}), do: slug
  defp agent_slug(_), do: nil

  defp req_client do
    Application.get_env(:platform, :external_agents_dispatcher_req_client) || Req.new()
  end

  defp elapsed_ms(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  rescue
    _ -> :ok
  end
end
