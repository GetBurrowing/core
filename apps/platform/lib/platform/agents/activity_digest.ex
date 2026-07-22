defmodule Platform.Agents.ActivityDigest do
  @moduledoc """
  Builds a markdown digest of organisational activity within a time window.

  Composed by the Historian's `historian` system event (post-T6 — was the
  legacy `daily_summary` event) so the agent receives a pre-aggregated view
  of chat messages, completed meeting transcripts, and task lifecycle
  changes rather than looping tool calls.

  DMs, archived spaces, deleted messages, and log-only messages are excluded
  by the underlying queries (`Chat.list_messages_since/2`,
  `Meetings.list_transcripts_since/2`, `Tasks.list_tasks_updated_since/2`).

  ## External-user scope partition (stack member 12, rbac-external-users)

  The message + transcript corpora partition on the M1 `external` marker in
  BOTH directions, threaded via the `:scope` opt on the underlying queries:

    * `:internal` (the default for `build/2`, `build/3` and `build_windowed/1`)
      — OMITS any external-user space/DM (and mixed Fabrikam+external spaces) from
      the Fabrikam-internal digest. With zero external users this is a no-op, so
      an all-internal org's output is byte-for-byte unchanged.
    * `build_external/3` — the mirror direction: builds a summary restricted to
      one external user's allowlisted spaces (`{:external_spaces, ids}`), which
      intrinsically OMITS Fabrikam-internal content.

  Pages, journal, and task corpora have no space dimension, so scope does not
  apply to them; `build_external/3` therefore covers only chat + meetings.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks

  @per_space_message_cap 40
  @message_content_preview 280
  @task_event_cap 50

  @doc """
  Returns a markdown string summarising activity in the half-open
  window `[window_start, window_end)`.

  Empty windows yield an italicised `_No activity in this window._` line
  under the header so the agent can detect and handle the quiet case.
  """
  @spec build(DateTime.t(), DateTime.t(), keyword()) :: String.t()
  def build(%DateTime{} = window_start, %DateTime{} = window_end, opts \\ []) do
    scope = Keyword.get(opts, :scope, :internal)

    messages = Chat.list_messages_since(window_start, window_end: window_end, scope: scope)

    transcripts =
      Meetings.list_transcripts_since(window_start, window_end: window_end, scope: scope)

    tasks = Tasks.list_tasks_updated_since(window_start, window_end: window_end)

    space_names = fetch_space_names(messages, transcripts)

    sections =
      [
        digest_messages(messages, space_names),
        digest_transcripts(transcripts, space_names),
        digest_task_events(tasks)
      ]
      |> Enum.reject(&(&1 == nil))

    body =
      case sections do
        [] -> "_No activity in this window._"
        sections -> Enum.join(sections, "\n\n")
      end

    header = "## Activity since #{format_datetime(window_start)} (UTC)"
    header <> "\n\n" <> body
  end

  @doc """
  Builds an external-user-facing digest for `user_id` over the half-open
  window `[window_start, window_end)`.

  Resolves the external user's allowlisted spaces via
  `Chat.participant_space_ids_for_user/1` and scopes the chat + meeting
  corpora to exactly those spaces (`scope: {:external_spaces, ids}`). Because
  an external user only ever participates in their allowlisted spaces, this
  intrinsically OMITS all Fabrikam-internal content. Pages, journal and task
  events are org-scoped (not space-scoped) and are therefore left out of the
  external summary entirely.

  Ships inert on the external side — no dispatcher wires this yet (M13
  notifications is the likely first consumer); the scoped builder is exposed
  now so that caller inherits a correct-by-construction exclusion.
  """
  @spec build_external(binary(), DateTime.t(), DateTime.t()) :: String.t()
  def build_external(user_id, %DateTime{} = window_start, %DateTime{} = window_end)
      when is_binary(user_id) do
    space_ids = Chat.participant_space_ids_for_user(user_id)
    scope = {:external_spaces, space_ids}

    messages = Chat.list_messages_since(window_start, window_end: window_end, scope: scope)

    transcripts =
      Meetings.list_transcripts_since(window_start, window_end: window_end, scope: scope)

    space_names = fetch_space_names(messages, transcripts)

    sections =
      [
        digest_messages(messages, space_names),
        digest_transcripts(transcripts, space_names)
      ]
      |> Enum.reject(&(&1 == nil))

    body =
      case sections do
        [] -> "_No activity in this window._"
        sections -> Enum.join(sections, "\n\n")
      end

    header = "## Activity since #{format_datetime(window_start)} (UTC)"
    header <> "\n\n" <> body
  end

  @doc """
  Corpus-scoped windowed digest, sized to a single window emitted by
  `Platform.Agents.HistorianDispatcher.slice_windows/2` (task 019f4f55).

  Unlike `build/2` — which fans out to every corpus over a 24-hour anchor
  window — `build_windowed/1` scopes queries to a single corpus in the
  half-open range `[window_start, window_end)`. Callers dispatch one
  message per window; the slicer keeps each range's estimated tokens
  under `historian_window_token_budget` so the resulting body fits the
  small-model context Higgins runs against.

  Recognised corpus keys mirror the atoms `slice_windows/2` returns and
  the atoms `Historian.pending_windows_input/1` uses: `:messages`,
  `:transcripts`, `:pages`, `:journal`. Unknown corpus keys fall back to
  a `_(unknown corpus)_` marker rather than raising — the plan-caller is
  the sole producer so garbage keys can only come from a code bug we'd
  rather surface as a visible digest artefact than a scheduler crash.

  Empty corpus queries render the same italicised `_No activity in this
  window._` fallback `build/2` uses so the agent's downstream handling
  stays uniform across the two paths.
  """
  @spec build_windowed(map()) :: String.t()
  def build_windowed(
        %{
          corpus: corpus,
          window_start: %DateTime{} = ws,
          window_end: %DateTime{} = we
        } = input
      ) do
    # Default `:internal` when the dispatcher omits `:scope`, so the existing
    # `HistorianDispatcher.dispatch_one_window/12` path needs no change.
    scope = Map.get(input, :scope, :internal)

    body = corpus_body(corpus, ws, we, scope)

    header =
      "## #{corpus_heading(corpus)} since #{format_datetime(ws)} (UTC)" <>
        " — window ends #{format_datetime(we)}"

    header <> "\n\n" <> body
  end

  defp corpus_body(:messages, ws, we, scope) do
    messages = Chat.list_messages_since(ws, window_end: we, scope: scope)
    space_names = fetch_space_names(messages, [])

    case digest_messages(messages, space_names) do
      nil -> "_No activity in this window._"
      section -> section
    end
  end

  defp corpus_body(:transcripts, ws, we, scope) do
    transcripts = Meetings.list_transcripts_since(ws, window_end: we, scope: scope)
    space_names = fetch_space_names([], transcripts)

    case digest_transcripts(transcripts, space_names) do
      nil -> "_No activity in this window._"
      section -> section
    end
  end

  defp corpus_body(:pages, ws, we, _scope) do
    # V1 org-scope only for the Historian sweep (workspace_id is nil in
    # the caller). The Wiki accessor filters by workspace as an option;
    # matching Historian's byte-sum which walks `is_nil(workspace_id)`.
    # Pages are org-wiki, not space-scoped — `scope` does not apply.
    pages = Wiki.list_pages_updated_since(ws, window_end: we, workspace_id: nil)

    case digest_pages(pages) do
      nil -> "_No activity in this window._"
      section -> section
    end
  end

  defp corpus_body(:journal, ws, we, _scope) do
    # Journal is org-wiki, not space-scoped — `scope` does not apply.
    entries =
      Wiki.list_journal_entries_since(ws, window_end: we, workspace_id: nil)

    case digest_journal(entries) do
      nil -> "_No activity in this window._"
      section -> section
    end
  end

  defp corpus_body(_other, _ws, _we, _scope), do: "_(unknown corpus)_"

  defp corpus_heading(:messages), do: "Chat"
  defp corpus_heading(:transcripts), do: "Meetings"
  defp corpus_heading(:pages), do: "Wiki pages"
  defp corpus_heading(:journal), do: "Journal"
  defp corpus_heading(other), do: "#{other}"

  # ── Messages ─────────────────────────────────────────────────────────────

  defp digest_messages([], _space_names), do: nil

  defp digest_messages(messages, space_names) do
    grouped =
      messages
      |> Enum.group_by(& &1.space_id)
      |> Enum.sort_by(fn {space_id, _} -> Map.get(space_names, space_id, "") end)

    body =
      grouped
      |> Enum.map(fn {space_id, msgs} ->
        space_label = Map.get(space_names, space_id, "(unknown space)")
        format_space_messages(space_label, msgs)
      end)
      |> Enum.join("\n\n")

    "### Chat\n\n" <> body
  end

  defp format_space_messages(space_label, msgs) do
    total = length(msgs)
    {shown, overflow} = Enum.split(msgs, @per_space_message_cap)

    lines =
      shown
      |> Enum.map(fn m ->
        time = format_time(m.inserted_at)
        author = m.author_display_name || "(unknown)"
        content = preview(m.content)
        "- #{time} @#{author}: #{content}"
      end)
      |> Enum.join("\n")

    overflow_note =
      if overflow == [] do
        ""
      else
        "\n- _(#{total - @per_space_message_cap} more messages — truncated)_"
      end

    "#### ##{space_label}\n" <> lines <> overflow_note
  end

  # ── Transcripts ──────────────────────────────────────────────────────────

  defp digest_transcripts([], _space_names), do: nil

  defp digest_transcripts(transcripts, space_names) do
    body =
      transcripts
      |> Enum.map(fn t ->
        time = format_time(t.completed_at)
        space_label = Map.get(space_names, t.space_id, "(meeting)")
        duration = format_duration(t.started_at, t.completed_at)
        summary = blank_fallback(t.summary, "_no summary available_")
        "- #{time} [meeting] \"#{space_label}\"#{duration}. Summary: #{summary}"
      end)
      |> Enum.join("\n")

    "### Meetings\n\n" <> body
  end

  # ── Task events ──────────────────────────────────────────────────────────

  defp digest_task_events([]), do: nil

  defp digest_task_events(tasks) do
    total = length(tasks)
    {shown, overflow} = Enum.split(tasks, @task_event_cap)

    lines =
      shown
      |> Enum.map(fn t ->
        time = format_time(t.updated_at)
        title = blank_fallback(t.title, "(untitled)")
        "- #{time} [task] \"#{title}\" → #{t.status}"
      end)
      |> Enum.join("\n")

    overflow_note =
      if overflow == [] do
        ""
      else
        "\n- _(#{total - @task_event_cap} more tasks — truncated)_"
      end

    "### Tasks\n\n" <> lines <> overflow_note
  end

  # ── Wiki pages (windowed only) ───────────────────────────────────────────

  defp digest_pages([]), do: nil

  defp digest_pages(pages) do
    body =
      pages
      |> Enum.map(fn p ->
        time = format_datetime(p.updated_at)
        preview = page_preview(p.content)
        "- #{time} [page] `#{p.file_key}` (v#{p.version}): #{preview}"
      end)
      |> Enum.join("\n")

    "### Wiki\n\n" <> body
  end

  defp page_preview(nil), do: ""

  defp page_preview(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@message_content_preview)
  end

  # ── Journal (windowed only) ──────────────────────────────────────────────

  defp digest_journal([]), do: nil

  defp digest_journal(entries) do
    body =
      entries
      |> Enum.map(fn e ->
        time = format_datetime(e.inserted_at)
        preview = page_preview(e.content)
        "- #{time} [journal] #{Date.to_iso8601(e.date)}: #{preview}"
      end)
      |> Enum.join("\n")

    "### Journal\n\n" <> body
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp fetch_space_names(messages, transcripts) do
    ids =
      (Enum.map(messages, & &1.space_id) ++ Enum.map(transcripts, & &1.space_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        from(s in Space, where: s.id in ^ids, select: {s.id, s.name})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp preview(nil), do: ""

  defp preview(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(@message_content_preview)
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp format_time(%DateTime{} = dt) do
    dt
    |> Calendar.strftime("%H:%M")
  end

  defp format_time(_), do: "--:--"

  defp format_duration(%DateTime{} = started, %DateTime{} = completed) do
    minutes = DateTime.diff(completed, started, :second) |> div(60)

    cond do
      minutes < 1 -> ""
      minutes < 60 -> " — #{minutes} min"
      true -> " — #{div(minutes, 60)}h #{rem(minutes, 60)}m"
    end
  end

  defp format_duration(_, _), do: ""

  defp blank_fallback(nil, fallback), do: fallback
  defp blank_fallback("", fallback), do: fallback
  defp blank_fallback(value, _fallback), do: value
end
