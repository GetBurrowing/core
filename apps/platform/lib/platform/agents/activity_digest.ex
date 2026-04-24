defmodule Platform.Agents.ActivityDigest do
  @moduledoc """
  Builds a markdown digest of organisational activity within a time window.

  Composed by the Historian's `daily_summary` system event so the agent
  receives a pre-aggregated view of chat messages, completed meeting
  transcripts, and task lifecycle changes rather than looping tool calls.

  DMs, archived spaces, deleted messages, and log-only messages are excluded
  by the underlying queries (`Chat.list_messages_since/2`,
  `Meetings.list_transcripts_since/2`, `Tasks.list_tasks_updated_since/2`).
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Meetings
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
  @spec build(DateTime.t(), DateTime.t()) :: String.t()
  def build(%DateTime{} = window_start, %DateTime{} = window_end) do
    messages = Chat.list_messages_since(window_start, window_end: window_end)
    transcripts = Meetings.list_transcripts_since(window_start, window_end: window_end)
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
