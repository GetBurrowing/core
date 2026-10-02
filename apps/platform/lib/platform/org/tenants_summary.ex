defmodule Platform.Org.TenantsSummary do
  @moduledoc """
  Curator for `org/<root-slug>/TENANTS_SUMMARY.md` — a single org-wiki page
  that holds one short paragraph per descendant tenant org.

  The page is rebuilt on a weekly heartbeat (see
  `Platform.Agents.SystemEventScheduler`) so the root org's preamble always
  carries a fresh at-a-glance roster of its tenants without paying the
  cost of loading every tenant's full memory at root scope.

  ## Design notes

    * The page lives at file_key `"org/<root-slug>/TENANTS_SUMMARY.md"` and
      is org-scoped (`workspace_id: nil`) so it surfaces in every
      org-level preamble.
    * Per-tenant scoping of journal/memory data lands with ADR 0042 Stage 1
      (the `org_id` column on `org_wiki_pages` / `org_wiki_journal_entries`).
      Until then, the per-tenant input is the tenant's `org/<slug>/IDENTITY.md`
      page if present; tenants with no IDENTITY page get a stable
      placeholder paragraph so the section order on the page is
      diff-friendly across runs.
    * LLM calls go through an injectable `:llm_fun` option so tests can
      stub deterministically; the default uses the same provider adapters
      `Platform.Meetings.Summarizer` does (configured via
      `Platform.Meetings.Config.summary/0`).
    * On LLM failure we leave the existing summary file untouched and emit
      a `:tenants_summary_failed` telemetry event — partial-write avoidance
      matches the planner's risk surface note.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Providers.{Anthropic, Ollama, OpenAI}
  alias Platform.Meetings.Config
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @file_key_template "org/<root-slug>/TENANTS_SUMMARY.md"

  @max_paragraph_words 80

  @system_prompt """
  You are a concise organizational historian. Given a tenant organization's \
  recent identity notes, produce ONE short paragraph (max #{@max_paragraph_words} words) \
  summarizing the tenant's focus, recent activity, current projects, and any \
  open commitments. Do NOT use lists, headings, or markdown — return plain \
  prose only. If the input is sparse, say so honestly in one sentence.
  """

  @typedoc """
  Stubbed-or-real LLM callable. Receives the tenant's name + raw input \
  context and returns `{:ok, paragraph_text}` or `{:error, reason}`.
  """
  @type llm_fun :: (binary(), binary() -> {:ok, binary()} | {:error, term()})

  @doc """
  Recompute `TENANTS_SUMMARY.md` for the root org.

  Walks every tenant org returned by `Tenancy.list_tenants/0`, summarizes
  each into a one-paragraph blurb, concatenates them in slug-alphabetical
  order under `## <Tenant Name>` headers, and upserts the page.

  ## Options

    * `:llm_fun` — `t:llm_fun/0` callable used to produce per-tenant
      paragraphs. Defaults to a real provider call via
      `Platform.Meetings.Config.summary/0`. Tests should pass a
      deterministic stub.

  Returns `{:ok, %WikiPage{}}` on success, `{:error, reason}` if the
  upsert ultimately fails, or `{:ok, :no_root}` when no root org is
  configured (defensive — production always has one).
  """
  @spec recompute(keyword()) ::
          {:ok, WikiPage.t()} | {:ok, :no_root} | {:error, term()}
  def recompute(opts \\ []) do
    llm_fun = Keyword.get(opts, :llm_fun, &default_llm/2)

    case root_org() do
      nil ->
        Logger.info("[TenantsSummary] no root org configured — skipping recompute")
        {:ok, :no_root}

      %Org{} = root ->
        tenants = Tenancy.list_tenants()
        do_recompute(root, tenants, llm_fun)
    end
  end

  @doc """
  Canonical file_key for the summary page, derived from a root-org slug.

  Exposed so tests + the preamble builder can name the same key without
  hand-rolling the path template.
  """
  @spec file_key_for(binary()) :: binary()
  def file_key_for(root_slug) when is_binary(root_slug) do
    String.replace(@file_key_template, "<root-slug>", root_slug)
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp do_recompute(%Org{slug: root_slug} = _root, tenants, llm_fun) do
    file_key = file_key_for(root_slug)

    sections =
      tenants
      |> Enum.sort_by(& &1.slug)
      |> Enum.map(fn tenant -> section_for(tenant, llm_fun) end)

    case Enum.find(sections, fn {status, _} -> status == :error end) do
      {:error, reason} ->
        emit_failed(reason, length(tenants))
        {:error, reason}

      nil ->
        body = render_body(sections)

        case Wiki.upsert_page(file_key, %{content: body, updated_by: nil}, workspace_id: nil) do
          {:ok, %WikiPage{} = page} ->
            emit_recomputed(byte_size(body), length(tenants))
            {:ok, page}

          {:error, reason} ->
            emit_failed(reason, length(tenants))
            {:error, reason}
        end
    end
  end

  defp section_for(%Org{slug: slug, name: name}, llm_fun) do
    identity = identity_page_for(slug)

    cond do
      is_nil(identity) or empty_content?(identity.content) ->
        {:ok, {name, placeholder_paragraph(name)}}

      true ->
        case llm_fun.(name, identity.content) do
          {:ok, paragraph} when is_binary(paragraph) and paragraph != "" ->
            {:ok, {name, String.trim(paragraph)}}

          {:ok, _} ->
            # Empty LLM reply on real content — fall back to placeholder
            # rather than fail the whole batch.
            {:ok, {name, placeholder_paragraph(name)}}

          {:error, reason} ->
            {:error, {:llm_failed, slug, reason}}
        end
    end
  end

  defp render_body(sections) do
    header = "# Tenants Summary\n\n_Auto-generated by Platform.Org.TenantsSummary._\n\n"

    body =
      sections
      |> Enum.map(fn {:ok, {name, paragraph}} ->
        "## #{name}\n\n#{paragraph}\n"
      end)
      |> Enum.join("\n")

    header <> body
  end

  defp placeholder_paragraph(name) do
    "_#{name}: no recent activity recorded._"
  end

  defp empty_content?(nil), do: true
  defp empty_content?(""), do: true
  defp empty_content?(content) when is_binary(content), do: String.trim(content) == ""
  defp empty_content?(_), do: true

  defp identity_page_for(slug) do
    file_key = "org/#{slug}/IDENTITY.md"

    from(p in WikiPage,
      where: p.file_key == ^file_key and is_nil(p.workspace_id),
      limit: 1
    )
    |> Repo.one()
  end

  defp root_org do
    from(o in Org, where: is_nil(o.parent_org_id), limit: 1)
    |> Repo.one()
  end

  # ── Telemetry ──────────────────────────────────────────────────────────

  defp emit_recomputed(byte_size, tenant_count) do
    :telemetry.execute(
      [:platform, :org, :tenants_summary_recomputed],
      %{byte_size: byte_size, tenant_count: tenant_count, system_time: System.system_time()},
      %{}
    )
  end

  defp emit_failed(reason, tenant_count) do
    :telemetry.execute(
      [:platform, :org, :tenants_summary_failed],
      %{tenant_count: tenant_count, system_time: System.system_time()},
      %{reason: reason}
    )
  end

  # ── Default LLM bridge ─────────────────────────────────────────────────

  defp default_llm(tenant_name, raw_context) do
    cfg = Config.summary()

    cond do
      cfg.provider == :none ->
        {:error, :no_summary_provider_configured}

      true ->
        messages = [
          %{
            role: "user",
            content:
              "Summarize this tenant in one paragraph.\n\n" <>
                "Tenant: #{tenant_name}\n\n" <>
                "Identity notes:\n\n" <>
                raw_context
          }
        ]

        opts =
          [
            system: @system_prompt,
            model: cfg.model,
            max_tokens: cfg.max_tokens,
            temperature: cfg.temperature
          ]
          |> maybe_put(:base_url, cfg.base_url)

        call_provider(cfg, messages, opts)
    end
  end

  defp call_provider(%{provider: provider} = cfg, messages, opts) do
    credentials = llm_credentials(cfg)
    adapter = provider_adapter(provider)

    case adapter.chat(credentials, messages, opts) do
      {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
      {:ok, %{content: [%{"text" => text} | _]}} -> {:ok, text}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_adapter(:anthropic), do: Anthropic
  defp provider_adapter(:openai), do: OpenAI
  defp provider_adapter(:ollama), do: Ollama
  defp provider_adapter(other), do: raise(ArgumentError, "Unknown provider: #{inspect(other)}")

  defp llm_credentials(%{provider: :anthropic, api_key_env: env}) do
    case env && System.get_env(env) do
      nil -> %{credential_slug: "anthropic"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :openai, api_key_env: env}) do
    case env && System.get_env(env) do
      nil -> %{credential_slug: "openai"}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: :ollama, api_key_env: env}) do
    case env && System.get_env(env) do
      nil -> %{}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(_), do: %{}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
