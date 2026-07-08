defmodule Platform.Security.LlmEnrichment do
  @moduledoc """
  LLM-facing enrichment layer for Security Guard findings (task
  `019f3e8e-4406` v2 stage 3, ADR-0043).

  Sits between each scanner's deterministic finding output and the
  `FindingFiler` insert path. Each scanner emits a raw finding with
  a static title + description; this module optionally rewrites the
  finding with an LLM-refined summary, priority, and remediation
  checklist before the finding lands as a Suite task.

  ## Progressive-enhancement contract

  `enrich_finding/2` walks a short chain — bail early to `{:noop,
  finding}` at each step so the scanner's v1 shape stays intact
  whenever the LLM path isn't wired up:

    1. `Platform.Roles.assignee_for(responsibility_key)` returns `nil` —
       no agent pinned to `security_guard`; return the finding as-is.
    2. The assigned agent's `runtime_type` is not `"external"` — the
       built-in / native runtime doesn't participate in security
       enrichment (there's no chat surface to call). Return as-is.
    3. Prompt template `security.<key>.v1` is missing — the migration
       hasn't landed, or has since been deleted. Return as-is.
    4. LLM provider errors — timeout, HTTP 500, connection refused,
       bad JSON. Log at `:warning`, return as-is.
    5. Response parses cleanly against the closed-shape contract
       (`summary` + `priority` in `{critical, high, medium, low}` +
       `remediation_steps` list) — merge into the finding and return
       `{:enriched, finding}`.

  Because scanners always call `enrich_finding/2` uniformly, adding
  enrichment is a matter of assigning an agent — no scanner code
  changes required at cut-over.

  ## Response contract

  The four `security.*.v1` templates instruct the model to emit exactly:

  ```json
  {
    "summary": "<one-sentence what + who + risk>",
    "priority": "critical|high|medium|low",
    "remediation_steps": ["<step 1>", "<step 2>", ...]
  }
  ```

  Any other shape → drop to `:noop`. Priority values outside the
  closed enum → drop to `:noop`. This is the "closed-enum JSON"
  guarantee the ADR calls out.

  ## Test seams

    * `:security_llm_enrichment_provider` — provider module override.
      Defaults to `Platform.Agents.Providers.Ollama`; tests inject a
      stub that reads canned responses from the process dictionary.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Roles

  @valid_priorities ~w(critical high medium low)

  @priority_to_severity %{
    "critical" => :critical,
    "high" => :high,
    "medium" => :medium,
    "low" => :low
  }

  @default_temperature 0.0
  @default_max_tokens 512

  @doc """
  Enrich a raw scanner finding via the assigned agent's LLM. Returns
  `{:enriched, finding}` when the enrichment pipeline succeeded end
  to end, or `{:noop, finding}` when any guard along the chain fires
  (see the module-doc contract). Never raises — every failure path
  falls to `{:noop, finding}`.
  """
  @spec enrich_finding(map(), String.t()) ::
          {:enriched, map()} | {:noop, map()}
  def enrich_finding(finding, responsibility_key)
      when is_map(finding) and is_binary(responsibility_key) do
    with %Agent{runtime_type: "external"} = agent <-
           safe_assignee_for(responsibility_key),
         template_slug = template_slug_for(responsibility_key),
         assigns = build_assigns(responsibility_key, finding),
         {:ok, prompt} <- PromptTemplates.render_template(template_slug, assigns),
         {:ok, content} <- call_provider(agent, prompt, finding, responsibility_key),
         {:ok, parsed} <- parse_content(content, responsibility_key) do
      {:enriched, merge_enrichment(finding, parsed, responsibility_key)}
    else
      _ -> {:noop, finding}
    end
  rescue
    error ->
      Logger.warning(
        "[Security.LlmEnrichment] enrichment crashed key=#{responsibility_key} — #{Exception.message(error)}"
      )

      {:noop, finding}
  end

  # ── assignee lookup ───────────────────────────────────────────────────

  # Wrap Roles.assignee_for/1 so a DB blip (Repo not started, sandbox
  # ownership hiccup) drops to :noop instead of surfacing a raise the
  # caller would treat as a scanner crash.
  defp safe_assignee_for(responsibility_key) do
    Roles.assignee_for(responsibility_key)
  rescue
    _ -> nil
  end

  # ── template lookup ───────────────────────────────────────────────────

  defp template_slug_for(responsibility_key), do: "#{responsibility_key}.v1"

  # ── prompt assigns ────────────────────────────────────────────────────

  defp build_assigns(responsibility_key, finding) do
    base = %{
      finding: safe_encode(finding),
      severity: finding |> Map.get(:severity) |> stringify()
    }

    Map.merge(base, extract_assigns(responsibility_key, finding))
  end

  defp extract_assigns("security.cve_scan", finding) do
    meta = Map.get(finding, :metadata, %{}) || %{}

    %{
      cve_id: get_meta(meta, "cve_id"),
      package: get_meta(meta, "package"),
      version: get_meta(meta, "installed_version"),
      ecosystem: get_meta(meta, "ecosystem"),
      fixed_version: get_meta(meta, "fixed_version")
    }
  end

  defp extract_assigns("security.code_audit", finding) do
    meta = Map.get(finding, :metadata, %{}) || %{}

    %{
      pattern_id: get_meta(meta, "pattern_id"),
      file_path: get_meta(meta, "file"),
      line: get_meta(meta, "line"),
      snippet: get_meta(meta, "snippet"),
      rubric_note: get_meta(meta, "rubric_note")
    }
  end

  defp extract_assigns("security.deploy_audit", finding) do
    meta = Map.get(finding, :metadata, %{}) || %{}

    %{
      gap_kind: extract_deploy_gap_kind(Map.get(finding, :fingerprint, "")),
      resource_path:
        get_meta(meta, "file", get_meta(meta, "cert_path", get_meta(meta, "env_file"))),
      expected: get_meta(meta, "expected"),
      observed: get_meta(meta, "observed")
    }
  end

  defp extract_assigns("security.secret_leak", finding) do
    meta = Map.get(finding, :metadata, %{}) || %{}

    in_history? = Map.has_key?(meta, "commit_sha")

    %{
      credential_class: get_meta(meta, "pattern_id"),
      file_path: get_meta(meta, "file"),
      line: get_meta(meta, "line"),
      in_git_history: to_string(in_history?)
    }
  end

  defp extract_assigns(_key, _finding), do: %{}

  defp extract_deploy_gap_kind("deploy_audit:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [kind, _] -> kind
      _ -> ""
    end
  end

  defp extract_deploy_gap_kind(_), do: ""

  defp get_meta(meta, key, default \\ "") do
    case Map.get(meta, key) do
      nil -> default
      value -> stringify(value)
    end
  end

  defp stringify(nil), do: ""
  defp stringify(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify(bin) when is_binary(bin), do: bin
  defp stringify(other), do: to_string(other)

  # The finding is passed as a JSON string to the model so it can
  # cross-reference metadata the closed-enum extractors don't lift.
  # Empty string on encode failure — the prompt still has the
  # per-key assigns to work from.
  defp safe_encode(finding) do
    case Jason.encode(finding) do
      {:ok, encoded} -> encoded
      _ -> ""
    end
  end

  # ── provider call ─────────────────────────────────────────────────────

  # Mirrors `Platform.Meetings.IntentClassifier.call_provider/5` in
  # shape — pass a system prompt + user message with the raw finding
  # JSON, take the first choice content. Errors return `:error` so
  # the `with` chain drops to `{:noop, finding}`.
  defp call_provider(agent, prompt, finding, responsibility_key) do
    provider = provider_module()

    messages = [
      %{role: "system", content: prompt},
      %{role: "user", content: safe_encode(finding)}
    ]

    opts =
      [
        base_url: Map.get(agent, :base_url),
        model: Map.get(agent, :model),
        temperature: @default_temperature,
        max_tokens: @default_max_tokens
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    credentials = agent_credentials(agent)

    try do
      case provider.chat(credentials, messages, opts) do
        {:ok, %{content: content}} when is_binary(content) ->
          {:ok, content}

        {:ok, %{"content" => content}} when is_binary(content) ->
          {:ok, content}

        {:ok, other} ->
          Logger.warning(
            "[Security.LlmEnrichment] provider returned unexpected shape key=#{responsibility_key} shape=#{inspect(other)}"
          )

          :error

        {:error, reason} ->
          Logger.warning(
            "[Security.LlmEnrichment] provider call failed key=#{responsibility_key} reason=#{inspect(reason)}"
          )

          :error
      end
    rescue
      exception ->
        Logger.warning(
          "[Security.LlmEnrichment] provider raised key=#{responsibility_key} — #{Exception.message(exception)}"
        )

        :error
    catch
      kind, reason ->
        Logger.warning(
          "[Security.LlmEnrichment] provider caught key=#{responsibility_key} kind=#{inspect(kind)} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  defp provider_module do
    Application.get_env(
      :platform,
      :security_llm_enrichment_provider,
      Platform.Agents.Providers.Ollama
    )
  end

  # Same "no auth by default" shape IntentClassifier uses — the Ollama
  # provider inspects `:api_key` on the credentials map only.
  defp agent_credentials(agent) do
    case Map.get(agent, :vault_key) do
      key when is_binary(key) and key != "" -> %{api_key: key}
      _ -> %{}
    end
  end

  # ── response parsing ─────────────────────────────────────────────────

  defp parse_content(content, responsibility_key) do
    case Jason.decode(content) do
      {:ok, %{"summary" => summary, "priority" => priority, "remediation_steps" => steps}}
      when is_binary(summary) and is_binary(priority) and is_list(steps) ->
        cond do
          priority not in @valid_priorities ->
            Logger.warning(
              "[Security.LlmEnrichment] invalid priority=#{inspect(priority)} key=#{responsibility_key}"
            )

            :error

          not Enum.all?(steps, &is_binary/1) ->
            Logger.warning(
              "[Security.LlmEnrichment] remediation_steps must be list of strings key=#{responsibility_key}"
            )

            :error

          true ->
            {:ok, %{summary: summary, priority: priority, remediation_steps: steps}}
        end

      {:ok, decoded} ->
        Logger.warning(
          "[Security.LlmEnrichment] response missing required keys key=#{responsibility_key} decoded=#{inspect(decoded)}"
        )

        :error

      {:error, reason} ->
        Logger.warning(
          "[Security.LlmEnrichment] response not JSON key=#{responsibility_key} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  # ── merge back into finding ─────────────────────────────────────────

  defp merge_enrichment(
         finding,
         %{
           summary: summary,
           priority: priority,
           remediation_steps: steps
         },
         responsibility_key
       ) do
    new_severity = Map.get(@priority_to_severity, priority, Map.get(finding, :severity))
    enriched_description = build_enriched_description(finding, summary, steps)
    enriched_title = build_enriched_title(responsibility_key, summary)
    original_metadata = Map.get(finding, :metadata, %{}) || %{}

    enriched_metadata =
      Map.merge(original_metadata, %{
        "security_enriched" => true,
        "security_enrichment_summary" => summary,
        "security_enrichment_priority" => priority,
        "security_enrichment_remediation_steps" => steps
      })

    # NOTE (case-3 review fix, 2026-07): title now carries the LLM's
    # `summary` verbatim so the FindingFiler-emitted Suite task lands
    # with a human-legible headline instead of the scanner's static
    # "CVE X in Y (severity: Z)" boilerplate. `fingerprint`,
    # `project_id`, and `metadata` (beyond the additive
    # `security_enrichment_*` keys) are left untouched — the dedup
    # gate keys off `fingerprint` and MUST stay stable across
    # enriched vs. un-enriched runs.
    finding
    |> Map.put(:title, enriched_title)
    |> Map.put(:severity, new_severity)
    |> Map.put(:description, enriched_description)
    |> Map.put(:metadata, enriched_metadata)
  end

  defp build_enriched_title(responsibility_key, summary) do
    "[security:#{scanner_key_short(responsibility_key)}] #{summary}"
  end

  # "security.cve_scan" → "cve_scan"; anything without the "security."
  # prefix passes through unchanged (defensive — the four wired
  # scanners all conform, but we don't want a stray key producing an
  # empty tag).
  defp scanner_key_short("security." <> rest), do: rest
  defp scanner_key_short(other) when is_binary(other), do: other

  defp build_enriched_description(finding, summary, steps) do
    original = Map.get(finding, :description, "") || ""

    remediation_block =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, idx} -> "#{idx}. #{step}" end)

    """
    ## Security Guard summary

    #{summary}

    ## Suggested remediation

    #{remediation_block}

    ---

    #{original}
    """
  end
end
