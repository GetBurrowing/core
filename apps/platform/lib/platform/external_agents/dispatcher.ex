defmodule Platform.ExternalAgents.Dispatcher do
  @moduledoc """
  HTTP dispatch path for `:external` assignees (ADR-0041 M6 stage 5).

  Bridges a fired responsibility to an external (HTTP-delegated) agent.
  `Platform.Responsibilities.Router.fire_trigger/3` calls
  `dispatch/3` when the resolved assignee has `kind == "external"`;
  stage 6 wires the actual call site — for now `dispatch/3` is the
  isolated, testable seam.

  ## Pipeline

    1. Resolve `responsibility.default_prompt_template` — a prompt
       template SLUG — against the `prompt_templates` table via
       `Platform.Orchestration.PromptTemplates.render_template/2`, then
       string-substitute any leftover `{key}` placeholders against
       `context` keys. A slug naming no row, a blank body, or a
       nil/blank `default_prompt_template` ABORTS the dispatch before
       any HTTP call — see "Prompt-absence taxonomy" below.
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

  ## Prompt-absence taxonomy (task 019fba51 stage 3)

  When the legacy render cannot produce a prompt, this module ABORTS —
  it returns `{:error, reason}` from `dispatch/4` with no `Req.post/2`
  and no request body built. The three causes are kept apart, and the
  slug rides along, because they need different fixes:

    * `{:error, {:template_missing, slug}}` — `default_prompt_template`
      names a slug with no `prompt_templates` row. Fix: seed the row.
    * `{:error, {:template_blank, slug}}` — the row is there and its
      body renders to whitespace. Fix: put content back in the row;
      there is no migration to write.
    * `{:error, :no_prompt_template}` — `default_prompt_template` is
      nil or blank, so the key was never wired to a prompt at all. Fix:
      wire one, or give the feature provider a `build_prompt/1`.

  The vocabulary is `Router.log_native_prompt_fidelity/3`'s, not a new
  one: `:no_prompt_template` is this path's name for the router's
  `{:absent, :legacy}`, and the other two are its `{:absent, {...}}`
  causes verbatim. Collapsing the three would make the second invisible,
  which is the whole reason the native taxonomy exists.

  ## Why abort, when the native path does the opposite

  `Router.dispatch_external/5` (router.ex:1193) already aborts on
  `{:error, reason}` from `build_prompt_via_provider/2` — no model call,
  `emit_failed_telemetry(..., :external, {:build_prompt_refused, reason})`.
  A named prompt whose row is absent is the same class of outcome and
  gets the same treatment.

  The native path deliberately does NOT abort: it dispatches a bare
  envelope carrying `prompt_status: :render_gap`, because a native
  runtime can still act on a bare signal. An OpenAI-compat endpoint
  cannot, and the call costs money. Emitting the slug would be worse
  still (the model is handed the NAME of its prompt), and emitting an
  empty user turn is a paid round-trip that can only return garbage.

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

  alias Platform.Agents.Agent
  alias Platform.Agents.Kind, as: AgentKind
  alias Platform.ExternalAgents
  alias Platform.ExternalAgents.ContractValidator
  alias Platform.Orchestration.PromptTemplates
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

  # Task 019f2570 bug 2 fix — the OpenAI-compat concierge at test-host:8084
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
    * `{:error, {:template_missing, slug}}` — `default_prompt_template`
      names no `prompt_templates` row (task 019fba51)
    * `{:error, {:template_blank, slug}}` — the row exists but renders
      to whitespace
    * `{:error, :no_prompt_template}` — `default_prompt_template` is
      nil or blank

  The last three abort BEFORE any HTTP call; see the moduledoc's
  "Prompt-absence taxonomy" for why they are three and not one.

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
      raw OpenAI-shaped messages list directly to `request_body/3`.
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

    # ORDERING IS THE ABORT (task 019fba51 stage 3). `resolve_messages/3` is
    # the FIRST clause, so a prompt-absence error returns through the `else`
    # arm below with `post/2` never entered — no `Req.post`, no request body
    # built, no paid round-trip. The `else` arm is also the single telemetry
    # site for it: the abort lands on `[:platform, :external_agent, :error]`
    # with the same `endpoint_kind` / `agent_slug` / `responsibility_key`
    # metadata as an HTTP failure, plus `reason: inspect(reason)` carrying
    # the slug, so it shows up in the stream operators already watch rather
    # than in a new one nobody has a dashboard for.
    with {:ok, messages} <- resolve_messages(responsibility, context, opts),
         {:ok, body} <- post(agent, messages, responsibility),
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
  # Returns `{:ok, [%{role:, content:}]}` ready to hand to `post/3`, or
  # `{:error, reason}` when the legacy render cannot produce a prompt at
  # all (task 019fba51 stage 2 — previously impossible, because the legacy
  # render always "succeeded" by shipping the slug).
  #
  # THE PRECEDENCE IS UNCHANGED BY THE ABORT (task 019fba51 stage 3). An
  # explicit `messages:` or `prompt:` never touches the template at all, so
  # a caller that already has a prompt in hand cannot be aborted by a
  # `default_prompt_template` that names a missing row. Only the third
  # branch can return an error.
  defp resolve_messages(responsibility, context, opts) when is_list(opts) do
    cond do
      is_list(opts[:messages]) and opts[:messages] != [] ->
        {:ok, opts[:messages]}

      is_map(opts[:prompt]) ->
        prompt_to_messages_or_legacy(opts[:prompt], responsibility, context)

      true ->
        legacy_messages(responsibility, context)
    end
  end

  defp prompt_to_messages_or_legacy(%{system: sys, user: user}, _r, _c)
       when is_binary(sys) and is_binary(user) do
    case sys do
      "" -> {:ok, [%{role: "user", content: user}]}
      _ -> {:ok, [%{role: "system", content: sys}, %{role: "user", content: user}]}
    end
  end

  defp prompt_to_messages_or_legacy(%{user: user}, _r, _c) when is_binary(user),
    do: {:ok, [%{role: "user", content: user}]}

  defp prompt_to_messages_or_legacy(_bad, responsibility, context),
    do: legacy_messages(responsibility, context)

  # THE FIX (task 019fba51 stage 2).
  #
  # `responsibility.default_prompt_template` holds a prompt template SLUG
  # — `"tasks.triage.v1"`, `"meetings.intent_classify.v1"` — and the rows
  # those slugs name are real, seeded by migration. This module never
  # looked one up: it handed the slug to `EEx.eval_string/2`, rescued to
  # the literal, `{var}`-substituted it (a slug has no placeholders) and
  # shipped it, so an external agent received `[%{role: "user", content:
  # "tasks.triage.v1"}]` — the NAME of its prompt instead of its prompt.
  # Eleven builder-less responsibility keys took this path; ten of them
  # name a seeded row of 365..4732 characters.
  #
  # `Router.render_default_template/2` (router.ex:2025) fixed the native
  # half of the same defect in task 019fb8ed and explicitly left this half
  # alone, pinned by a characterisation test. This is that test's inverse.
  #
  # THE RENDER IS DELIBERATELY NOT HOISTED INTO THE ROUTER.
  # `render_default_template/2` returns a bare string; handing it to this
  # module as `messages:` would bypass `split_prompt/1` and a seeded body
  # whose head is a `<system>` block would stop becoming a system turn.
  # Rendering here also fixes `dispatch/3` for DIRECT callers, which a
  # Router-only fix would not.
  defp legacy_messages(%Responsibility{default_prompt_template: slug}, context) do
    assigns = template_assigns(context)

    with {:ok, slug} <- resolved_slug(slug),
         {:ok, body} <- render_template_body(slug, assigns) do
      body
      |> substitute_placeholders(assigns)
      |> split_prompt()
      |> to_messages()
    end
  end

  # ── Prompt rendering ──────────────────────────────────────────────────────

  # NO SLUG AT ALL IS NOT A MISSING ROW (task 019fba51 stage 3). Stage 2
  # returned `{:template_missing, slug}` here as a provisional shape; it is
  # the wrong name for this cause and it names a slug that does not exist.
  # `:no_prompt_template` is this path's analogue of the router's
  # `{:absent, :legacy}` (router.ex:2029/2044, which uses exactly this
  # `String.trim/1`-then-catch-all shape): the key was never wired to a
  # prompt, which is a different fix from a slug whose row needs seeding.
  # Both still abort — an external endpoint cannot act on a bare signal the
  # way a native runtime can — but the operator has to be told which of the
  # two happened, or the seeding gap hides inside the wiring gap.
  defp resolved_slug(slug) when is_binary(slug) do
    case String.trim(slug) do
      "" -> {:error, :no_prompt_template}
      trimmed -> {:ok, trimmed}
    end
  end

  defp resolved_slug(_slug), do: {:error, :no_prompt_template}

  # NO EEx PASS. The old render ran `EEx.eval_string/2` over the template
  # before substituting, rescuing to the literal when the string was not
  # valid EEx. It is dropped rather than moved onto the resolved body,
  # for three reasons:
  #
  #   1. Template bodies are OPERATOR-EDITABLE rows (admin prompt-template
  #      UI). EEx-evaluating one is arbitrary code execution inside the
  #      BEAM with whatever anything that can write `prompt_templates`
  #      typed. `PromptTemplates`' own moduledoc says exactly this —
  #      "mustache-style interpolation (NOT EEx — too dangerous for
  #      user-editable content)". Keeping the pass would have turned a
  #      previously-harmless quirk (it only ever saw a slug) into a real
  #      exposure the moment the body started coming from the database.
  #   2. It buys nothing for the actual corpus: zero of the eleven
  #      builder-less rows contains a `<%` sequence (measured against the
  #      live table).
  #   3. The native path does no EEx either. Leaving it here would mean the
  #      two paths render the same row differently — the exact asymmetry
  #      this task exists to close.
  #
  # TWO PLACEHOLDER SYNTAXES, LAYERED IN A FIXED ORDER — this is a
  # decision, not a drift. `PromptTemplates.interpolate/2` replaces
  # `{{var}}` (the syntax the seeded corpus uses) and runs FIRST, inside
  # `render_template/2`. `substitute_placeholders/2` replaces `{var}` (this
  # module's long-standing contract, which `dispatch/3`'s direct callers
  # rely on) and runs SECOND, over whatever the first pass left. The order
  # is what keeps them from interfering: `interpolate/2` resolves an
  # unknown `{{x}}` to `""`, so no `{{x}}` can survive to be re-read as
  # `{x}`. Measured on the live rows: a single-brace scan of all eleven
  # bodies returns exactly the same names as the double-brace scan and
  # nothing else — i.e. every single-brace hit today is the inner half of
  # a `{{...}}` pair the first pass has already consumed.
  #
  # THE BLANK CHECK IS ON THE RENDERED BODY, not on the stored column, and
  # that is the reachable case. `PromptTemplate.changeset/2` runs
  # `validate_required([:content])`, whose default `:trim` makes `"   "`
  # indistinguishable from `nil` — so a whitespace row cannot be created or
  # updated through `PromptTemplates`. What CAN happen through the ordinary
  # editor is a body that is nothing but `{{placeholders}}`: with no
  # matching assigns `interpolate/2` resolves each to `""` and the render
  # comes back empty. Same trim check as the native half
  # (router.ex:2034), same reason.
  defp render_template_body(slug, assigns) do
    case PromptTemplates.render_template(slug, assigns) do
      {:ok, body} ->
        if String.trim(body) == "",
          do: {:error, {:template_blank, slug}},
          else: {:ok, body}

      {:error, :not_found} ->
        {:error, {:template_missing, slug}}
    end
  end

  defp to_messages({nil, user_prompt}), do: {:ok, [%{role: "user", content: user_prompt}]}

  defp to_messages({system_prompt, user_prompt}),
    do: {:ok, [%{role: "system", content: system_prompt}, %{role: "user", content: user_prompt}]}

  # Mirrors `Router.template_assigns/1` + `printable_assign/1`
  # (router.ex:2058-2068), and for the same measured reason.
  # `PromptTemplates.interpolate/2` calls `to_string/1` on each matched
  # assign and `render_template/2` wraps the whole render in
  # `rescue -> {:error, :not_found}` — so a context value that does not
  # implement `String.Chars` would be reported as a MISSING TEMPLATE,
  # which is a lie about a row that is sitting right there. Not
  # hypothetical on this path: `Handlers.Dreaming.gather_context/2`
  # returns `%{org_identity: <nested map>, recent_journal: ...}` and
  # `memory.dreaming.v1` is one of the two seeded bodies that carries
  # `{{...}}` placeholders.
  #
  # The normalised map is used for the `{var}` pass too — that one also
  # calls `to_string/1` on the substituted value, so the same raise was
  # reachable there, unrescued.
  #
  # `:__responsibility__` is dropped rather than inspected: it is a
  # `%Responsibility{}` the Router stamps on for its own use, not
  # something a prompt author asked for.
  defp template_assigns(context) when is_map(context) do
    context
    |> Map.delete(:__responsibility__)
    |> Map.new(fn {key, value} -> {key, printable_assign(value)} end)
  end

  defp template_assigns(_context), do: %{}

  defp printable_assign(value) when is_binary(value), do: value
  defp printable_assign(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp printable_assign(value), do: inspect(value)

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

  defp post(agent, messages_or_legacy, responsibility) do
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
  defp request_body(agent, messages, responsibility) when is_list(messages) do
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
