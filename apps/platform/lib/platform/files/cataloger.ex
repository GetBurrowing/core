defmodule Platform.Files.Cataloger do
  @moduledoc """
  Turns one eligible file into one catalog card (task 01a0008c stage 2).

  A card is a wiki page at `project/<project_id>/page/files/<slug>.md`
  holding ~200 tokens of prose about the document: what it is, who
  wrote it and when, what questions it answers, and whether it reads
  as authoritative or historical. The card exists so the Historian can
  know what a project's documents *are* without any of them entering
  its context. `platform_files.card_file_key` / `card_generated_at`
  point back at the card from the row.

  ## Tenancy — the thing that had to be fixed before any card existed

  `Platform.Org.Wiki.upsert_page/3` used to read only `:content` and
  `:updated_by`. A card written at an SXI project path therefore landed
  as a root-Fabrikam row with a nil `project_id` — `WikiPage.changeset/2`
  fills a nil `org_id` with the Fabrikam org by design, and
  `update_changeset/2` cast neither column, so nothing could repair it
  afterwards. The path said SXI, the row said Fabrikam, permanently.

  Stage 2 widened both changesets to accept the pair, and this module
  always passes it: the `org_id` comes from the card's own project, not
  from a default. `resolve_org_id/1` refuses to write at all when the
  project cannot be loaded or has no org, because falling through to
  the Fabrikam default is the exact bug this paragraph exists to describe.

  ## Self-gating — there is no enforcement to lean on

  Page paths are Historian-only writes at the **MCP tool surface**:
  `Platform.Org.Wiki.Routing.gate_write/3` returns
  `{:error, %{code: :historian_required}}` for a non-Historian agent.
  That check never runs here. `upsert_page/3` performs no
  authorization whatsoever and never touches `Routing` — its own docs
  say "Routing/ACL checks … belong to the caller" — and five
  server-side callers already write page paths with no agent at all.

  So this module has no privilege problem and also no enforcement.
  `write_card/4` therefore gates itself: it refuses any file_key that
  is not `project/<project_id>/page/files/<slug>.md` for the very
  project it was handed. A background emitter that can write anywhere
  in the wiki is one prompt-injected filename away from writing
  `org/page/identity.md`.

  ## The dedup path is structural, not an optimisation

  `Ingester.do_run/3`'s dedup clause copies chunk rows and flips
  status to `"ingested"` but never calls `upsert_extracted_text/3`.
  A deduped file has **no `platform_file_texts` row** — its `:stop`
  event reports `extracted_chars: 0` — so there is nothing to
  summarize even if the tokens were free. Its card is copied from the
  origin's card body, written at the deduped file's own slug, with
  zero LLM calls.

  The self-dedup clause (`prior_id == file.id`, e.g. re-running ingest
  after a successful run) carries the same `dedup: true` metadata and
  must be a no-op. `catalog_dedup/3` short-circuits on
  `card_file_key` being set, which covers both that case and any other
  route by which a dedup event reaches a file that is already
  catalogued.

  ## Configuration

      config :platform, :file_cards, %{
        provider: :anthropic,
        model: "claude-…",
        api_key_env: "ANTHROPIC_API_KEY",
        max_tokens: 700,
        temperature: 0.2
      }

  `provider: :none` (the default, and what `config/test.exs` pins) makes
  the LLM pass return `{:error, :no_card_provider_configured}`. That
  leaves `card_file_key` nil, which is indistinguishable from
  never-attempted — deliberately, because the retry strategy for this
  whole subsystem is the backfill.
  """

  require Logger

  alias Platform.Agents.Providers.Anthropic
  alias Platform.Agents.Providers.Ollama
  alias Platform.Agents.Providers.OpenAI
  alias Platform.Files
  alias Platform.Files.CardPrompt
  alias Platform.Files.File, as: PlatformFile
  alias Platform.Files.Supersession
  alias Platform.Org.Wiki
  alias Platform.Tasks

  @default_llm %{
    provider: :none,
    model: nil,
    base_url: nil,
    api_key_env: nil,
    max_tokens: 700,
    temperature: 0.2
  }

  # Bounds one pass. The corpus this was sized against is image-heavy
  # PDF whose extracted text runs far below its byte size, so this cap
  # is a ceiling on the pathological case rather than a routine trim.
  @max_text_chars 40_000

  @typedoc """
  `{:ok, page}` wrote a card. `{:ok, :noop, reason}` deliberately did
  nothing and nothing is wrong. `{:error, reason}` failed; the row
  keeps a nil `card_file_key` and the backfill will retry it.
  """
  @type result ::
          {:ok, Platform.Org.WikiPage.t()}
          | {:ok, :noop, atom()}
          | {:error, term()}

  @doc """
  Catalogs one file.

  Pass `dedup: true` when the ingest that produced this file resolved
  through the ingester's dedup branch (the `:stop` event's metadata
  says so). That path copies an existing card and never calls the LLM.

  Eligibility is re-checked here through
  `Platform.Files.list_catalogable_files/2` rather than trusted from
  the caller. The seam is a disclosure boundary — a `human_only` file's
  bytes must never reach an LLM — and a boundary that trusts its input
  is not one. The same call supplies the sibling roster, so the
  re-check costs nothing extra.
  """
  @spec catalog_file(PlatformFile.t(), keyword()) :: result()
  def catalog_file(%PlatformFile{} = file, opts \\ []) do
    dedup? = Keyword.get(opts, :dedup, false)

    with {:ok, org_id} <- resolve_org_id(file),
         {:ok, catalogable} <- ensure_catalogable(file) do
      if dedup? do
        catalog_dedup(file, org_id, catalogable)
      else
        catalog_fresh(file, org_id, catalogable)
      end
    end
  end

  @doc """
  The card path for `file`.

  The slug is a readable slug of the filename plus the first eight
  characters of the file's id. The id suffix is not decoration: two
  files in one project can share a filename, and the dedup path
  *requires* the copy to land at the deduped file's own slug rather
  than on top of the origin's card.
  """
  @spec card_file_key(PlatformFile.t()) :: String.t()
  def card_file_key(%PlatformFile{} = file) do
    "project/#{file.project_id}/page/files/#{slug_for(file)}.md"
  end

  @doc """
  Writes a card, refusing any path outside this project's card prefix.

  Returns `{:error, {:refused_path, file_key}}` for anything that is
  not `project/<project_id>/page/files/<slug>.md` — including a
  well-formed card path belonging to a *different* project, which is
  why `project_id` is a parameter and not something parsed back out of
  the key.

  Nothing upstream enforces this. See the module docs.
  """
  @spec write_card(String.t(), String.t(), binary(), binary()) ::
          {:ok, Platform.Org.WikiPage.t()} | {:error, term()}
  def write_card(file_key, content, org_id, project_id)
      when is_binary(file_key) and is_binary(content) and is_binary(org_id) and
             is_binary(project_id) do
    if card_path?(file_key, project_id) do
      Wiki.upsert_page(file_key, %{
        content: content,
        org_id: org_id,
        project_id: project_id
      })
    else
      Logger.warning(
        "[Files.Cataloger] refused a write outside the card prefix: #{inspect(file_key)} " <>
          "(project #{project_id})"
      )

      {:error, {:refused_path, file_key}}
    end
  end

  @doc """
  True when `file_key` is a card path belonging to `project_id`.

  Exposed so callers and tests can ask the gate directly instead of
  inferring it from a write's side effects.
  """
  @spec card_path?(String.t(), binary()) :: boolean()
  def card_path?(file_key, project_id) when is_binary(file_key) and is_binary(project_id) do
    # The project_id is interpolated into the pattern, so it has to be a
    # UUID and not, say, a traversal fragment that would make the regex
    # match a path it has no business matching.
    Platform.UUID.valid?(project_id) and
      Regex.match?(card_path_regex(project_id), file_key)
  end

  # ── Cataloging paths ───────────────────────────────────────────────────

  defp catalog_fresh(file, org_id, catalogable) do
    siblings = siblings_of(file, catalogable)

    with {:ok, text} <- fetch_text(file),
         {:ok, raw} <- run_llm(file, text, siblings) do
      {prose, claim} = CardPrompt.split_response(raw)
      supersedes = resolve_claim(file, claim, siblings)

      content = render_card(file, prose, supersedes)

      commit(file, content, org_id)
    end
  end

  defp catalog_dedup(file, org_id, catalogable) do
    cond do
      # Covers the ingester's self-dedup clause (`prior_id == file.id`),
      # which carries `dedup: true` exactly like a real dedup, and any
      # other route that re-fires a dedup event at a catalogued file.
      # A dedup NEVER regenerates: there is no new text and no new
      # information, so a rewrite could only churn the version counter
      # and the Historian's byte accounting.
      not is_nil(file.card_file_key) ->
        {:ok, :noop, :already_catalogued}

      true ->
        case dedup_origin(file, catalogable) do
          nil ->
            # Either a self-dedup on a file that never got a card, or an
            # origin that has no card yet. The backfill picks both up;
            # inventing a card here would mean an LLM call on a file with
            # no extracted text.
            {:ok, :noop, :no_origin_card}

          origin ->
            copy_card_from(origin, file, org_id)
        end
    end
  end

  defp copy_card_from(origin, file, org_id) do
    case Wiki.get_page(origin.card_file_key) do
      nil ->
        Logger.warning(
          "[Files.Cataloger] file #{origin.id} points at a card that does not exist " <>
            "(#{origin.card_file_key}); leaving #{file.id} uncatalogued for the backfill"
        )

        {:ok, :noop, :origin_card_missing}

      page ->
        # Take the prose, leave the frontmatter. The origin's
        # frontmatter names the origin's file_id; copying it verbatim
        # would give two cards the same backlink.
        {_fm, body} = Wiki.parse_frontmatter(page.content)

        content = render_card(file, String.trim(body), nil, copied_from: origin)

        commit(file, content, org_id)
    end
  end

  defp commit(file, content, org_id) do
    file_key = card_file_key(file)

    with {:ok, page} <- write_card(file_key, content, org_id, file.project_id),
         {:ok, _file} <- Files.mark_card_generated(file, file_key) do
      {:ok, page}
    end
  end

  # ── Eligibility, siblings, supersession ────────────────────────────────

  defp ensure_catalogable(file) do
    catalogable = Files.list_catalogable_files(file.project_id)

    if Enum.any?(catalogable, &(&1.id == file.id)) do
      {:ok, catalogable}
    else
      {:error, :not_catalogable}
    end
  end

  defp resolve_org_id(%PlatformFile{project_id: nil}), do: {:error, :no_project}

  defp resolve_org_id(%PlatformFile{project_id: project_id}) do
    case Tasks.get_project(project_id) do
      nil -> {:error, :no_project}
      %{org_id: nil} -> {:error, :project_has_no_org}
      %{org_id: org_id} -> {:ok, org_id}
    end
  end

  defp siblings_of(file, catalogable) do
    catalogable
    |> Enum.reject(&(&1.id == file.id))
    |> Enum.map(fn sibling ->
      %{
        id: sibling.id,
        filename: display_name(sibling),
        date: sibling.inserted_at |> DateTime.to_date() |> Date.to_iso8601()
      }
    end)
  end

  # The origin of a dedup: the earliest catalogable file in this project
  # sharing the content hash, which already has a card to copy.
  #
  # Resolved from the catalogable set rather than by a fresh query so
  # the disclosure boundary holds on this path too — a card must not be
  # copied out of a document that the seam excludes.
  defp dedup_origin(file, catalogable) do
    catalogable
    |> Enum.reject(&(&1.id == file.id))
    |> Enum.filter(&(&1.content_hash == file.content_hash and not is_nil(&1.card_file_key)))
    |> Enum.min_by(& &1.inserted_at, DateTime, fn -> nil end)
  end

  defp resolve_claim(file, claim, siblings) do
    case CardPrompt.resolve_supersession(claim, siblings) do
      {:ok, sibling} ->
        sibling

      {:error, :no_claim} ->
        nil

      {:error, reason} ->
        # The confabulation case. A claim we cannot pin to a real
        # `platform_files.id` in this project is dropped, and the drop
        # is logged rather than silent so a prompt that starts inventing
        # targets is visible without reading cards.
        Logger.info(
          "[Files.Cataloger] dropped an #{reason} supersession claim on file #{file.id}: " <>
            inspect(claim)
        )

        nil
    end
  end

  # ── Rendering ──────────────────────────────────────────────────────────

  defp render_card(file, prose, supersedes, opts \\ []) do
    copied_from = Keyword.get(opts, :copied_from)

    frontmatter =
      [
        {"file_id", file.id},
        {"filename", display_name(file)},
        {"content_type", file.content_type},
        {"uploaded_at", DateTime.to_iso8601(file.inserted_at)},
        {"card_generated_at", DateTime.to_iso8601(DateTime.utc_now())}
      ]
      |> maybe_append(supersedes, fn sib ->
        [
          {"supersedes_file_id", sib.id},
          {"supersedes_filename", sib.filename},
          # Unruled until a human says otherwise. The claim is recorded
          # and visible immediately; it never blocks the card from
          # publishing. Stage 5 renders this as the "ghost" state and
          # flips this key through `Files.Supersession.rule/3`.
          {"supersession_ruling", Supersession.unruled()}
        ]
      end)
      |> maybe_append(copied_from, fn origin ->
        [{"copied_from_file_id", origin.id}]
      end)

    body =
      case supersedes do
        nil ->
          prose

        sib ->
          # The sentence is owned by `Files.Supersession` because a
          # ruling has to REPLACE it — see `Supersession.claim_note/2`.
          prose <> "\n\n" <> Supersession.claim_note(sib.filename, Supersession.unruled())
      end

    yaml =
      Enum.map_join(frontmatter, "\n", fn {key, value} -> "#{key}: #{yaml_scalar(value)}" end)

    "---\n" <> yaml <> "\n---\n\n" <> body <> "\n"
  end

  defp maybe_append(list, nil, _fun), do: list
  defp maybe_append(list, value, fun), do: list ++ fun.(value)

  defp yaml_scalar(nil), do: "null"

  defp yaml_scalar(value) when is_binary(value) do
    "\"" <> String.replace(value, ~s("), ~s(\\")) <> "\""
  end

  defp yaml_scalar(value), do: to_string(value)

  defp display_name(%PlatformFile{} = file) do
    file.name || file.original_filename || file.id
  end

  defp slug_for(file) do
    base =
      file
      |> display_name()
      |> Path.basename()
      |> Path.rootname()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    base = if base == "", do: "document", else: base

    base <> "-" <> String.slice(file.id, 0, 8)
  end

  defp card_path_regex(project_id) do
    ~r/^project\/#{Regex.escape(project_id)}\/page\/files\/[a-z0-9][a-z0-9\-]*\.md$/
  end

  # ── The LLM pass ───────────────────────────────────────────────────────
  #
  # Shaped after `Platform.Meetings.Summarizer.run_summary_legacy/3` —
  # same config map, same adapter dispatch, same response unwrapping —
  # so there is one way this codebase talks to a chat provider rather
  # than two.

  defp fetch_text(file) do
    case Files.fetch_extracted_text(file.id) do
      nil ->
        {:error, :no_extracted_text}

      %{text: text} when is_binary(text) ->
        case String.trim(text) do
          "" -> {:error, :no_extracted_text}
          trimmed -> {:ok, String.slice(trimmed, 0, @max_text_chars)}
        end

      _ ->
        {:error, :no_extracted_text}
    end
  end

  defp run_llm(file, text, siblings) do
    cfg = llm_config()

    messages = [
      %{role: "user", content: CardPrompt.user_message(display_name(file), text, siblings)}
    ]

    opts =
      [
        system: CardPrompt.system_prompt(),
        model: cfg.model,
        max_tokens: cfg.max_tokens,
        temperature: cfg.temperature
      ]
      |> maybe_put(:base_url, cfg.base_url)

    call_llm(cfg, messages, opts)
  end

  defp llm_config do
    case Application.fetch_env(:platform, :file_cards) do
      {:ok, injected} when is_map(injected) -> Map.merge(@default_llm, injected)
      _ -> @default_llm
    end
  end

  defp call_llm(%{provider: :none}, _messages, _opts) do
    {:error, :no_card_provider_configured}
  end

  defp call_llm(%{provider: provider} = cfg, messages, opts) do
    credentials = llm_credentials(cfg)
    adapter = provider_adapter(provider)

    case adapter.chat(credentials, messages, opts) do
      {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
      {:ok, %{content: [%{"text" => text} | _]}} -> {:ok, text}
      {:ok, %{"content" => [%{"text" => text} | _]}} -> {:ok, text}
      {:ok, other} -> {:error, {:unrecognized_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_adapter(:anthropic), do: Anthropic
  defp provider_adapter(:openai), do: OpenAI
  defp provider_adapter(:ollama), do: Ollama

  defp provider_adapter(other),
    do: raise(ArgumentError, "Unknown file-card provider: #{inspect(other)}")

  defp llm_credentials(%{provider: :ollama, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(%{provider: provider, api_key_env: env}) do
    case api_key_from_env(env) do
      nil -> %{credential_slug: Atom.to_string(provider)}
      key -> %{api_key: key}
    end
  end

  defp llm_credentials(_), do: %{}

  defp api_key_from_env(nil), do: nil
  defp api_key_from_env(name) when is_binary(name), do: System.get_env(name)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
