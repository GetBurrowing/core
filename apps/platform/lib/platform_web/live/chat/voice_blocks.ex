defmodule PlatformWeb.ChatLive.VoiceBlocks do
  @moduledoc """
  The Voice chat session bracket in a DM (task 01a1b6c3 stage 3, design
  canvas 01a1b6c4 node `layout`).

  A Voice tab session lands in the DM as ordinary rows tagged
  `metadata["source"] == "voice"` with one `"voice_session_id"`
  (`Platform.Meetings.VoiceSession`). The message list is a LiveView stream,
  so a row cannot look at its neighbours when it renders. This module reads
  every DM row of the sessions in hand (one query) and stamps each voice row
  with the `:voice_block` it draws:

    * `:head`: on the session's FIRST DM row, the header band ("Voice chat"
      · date · length · count). Length and count come from the summary row;
      while there is none (in progress) the header carries the date only;
    * `:hidden?`: true for the middle turns of a FINISHED session with more
      than 10 turns, which starts collapsed to the first two and last two;
    * `:show_all`: on the second turn of such a session, the number the
      "Show all {N} turns" band names;
    * `:kind`: `:turn`, `:pointer` (the context pointer line) or `:summary`
      (the summary card and footer).

  The toggles are `Phoenix.LiveView.JS` class changes over
  `[data-voice-session=<id>]`; nothing round-trips. A session's rows are
  re-stamped when its summary arrives (`restamp_ids/2`), which is when it
  becomes collapsible and its header learns its length.
  """

  alias Platform.Chat
  alias Platform.Chat.Message

  @collapse_over 10
  @keep_each_end 2

  @doc "The turn count above which a finished session starts collapsed."
  def collapse_over, do: @collapse_over

  @doc "True for a top-level Voice tab record (a turn, pointer or summary)."
  @spec voice_row?(term()) :: boolean()
  def voice_row?(%{metadata: %{"source" => "voice", "voice_session_id" => id}} = msg)
      when is_binary(id) and id != "",
      do: is_nil(Map.get(msg, :thread_id))

  def voice_row?(_), do: false

  @doc "True for a session's summary row."
  def summary?(%{metadata: %{"voice_kind" => "summary"}} = msg), do: voice_row?(msg)
  def summary?(_), do: false

  @doc """
  Stamp `:voice_block` on every voice row in `messages` (order kept; every
  other row is returned untouched, and a list with no voice row costs no
  query). Option `:time_zone` (an IANA name) sets the header's clock;
  UTC without it.
  """
  @spec annotate([Message.t() | map()], keyword()) :: [Message.t() | map()]
  def annotate(messages, opts \\ []) when is_list(messages) do
    voice = Enum.filter(messages, &voice_row?/1)

    case voice do
      [] ->
        messages

      _ ->
        index = index_sessions(voice, opts)

        Enum.map(messages, fn msg ->
          if voice_row?(msg), do: %{msg | voice_block: block_for(msg, index)}, else: msg
        end)
    end
  end

  @doc """
  The ids of `summary`'s session's other DM rows: the rows a newly arrived
  summary must re-render (header length and count, collapse).
  """
  @spec restamp_ids(Message.t()) :: [binary()]
  def restamp_ids(%{space_id: space_id, metadata: %{"voice_session_id" => sid}} = summary) do
    [space_id]
    |> Chat.list_voice_records(voice_session_id: sid)
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 == summary.id))
  end

  # ── index ────────────────────────────────────────────────────────────

  defp index_sessions(voice, opts) do
    space_ids = voice |> Enum.map(& &1.space_id) |> Enum.uniq()
    session_ids = voice |> Enum.map(& &1.metadata["voice_session_id"]) |> Enum.uniq()
    tz = Keyword.get(opts, :time_zone)

    # The rows in hand join the read, so a row the caller just built (or
    # that the read races) still finds its session.
    space_ids
    |> Chat.list_voice_records(voice_session_ids: session_ids)
    |> Kernel.++(voice)
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(& &1.metadata["voice_session_id"])
    |> Map.new(fn {sid, rows} -> {sid, session_info(sid, Enum.sort_by(rows, & &1.id), tz)} end)
  end

  defp session_info(sid, rows, tz) do
    {summaries, body} = Enum.split_with(rows, &summary?/1)
    summary = List.first(summaries)
    turns = Enum.filter(body, &turn?/1)
    n = length(turns)
    collapsed? = summary != nil and n > @collapse_over

    hidden =
      if collapsed?,
        do: turns |> Enum.slice(@keep_each_end, n - 2 * @keep_each_end) |> MapSet.new(& &1.id),
        else: MapSet.new()

    first = List.first(body) || summary

    %{
      id: sid,
      first_id: first && first.id,
      hidden: hidden,
      show_all_on: if(collapsed?, do: Enum.at(turns, @keep_each_end - 1).id),
      shown_turns: n,
      head: head(sid, summary, first, collapsed?, n, tz)
    }
  end

  defp head(sid, summary, first, collapsed?, n, tz) do
    meta = (summary && summary.metadata) || %{}
    started_at = parse_time(meta["started_at"]) || (first && first.inserted_at)

    %{
      session_id: sid,
      date: format_date(started_at, tz),
      started_at: started_at,
      length: if(is_integer(meta["duration_ms"]), do: minutes_label(meta["duration_ms"])),
      count: if(is_integer(meta["turns"]), do: turns_label(meta["turns"])),
      collapsible?: collapsed?,
      shown_turns: n
    }
  end

  defp block_for(msg, index) do
    sid = msg.metadata["voice_session_id"]
    info = Map.fetch!(index, sid)

    %{
      session_id: sid,
      kind: kind(msg),
      head: if(msg.id == info.first_id, do: info.head),
      hidden?: MapSet.member?(info.hidden, msg.id),
      show_all: if(msg.id == info.show_all_on, do: info.shown_turns),
      context_path: context_path(msg)
    }
  end

  # The pointer line links to the context it names; a context that is gone
  # leaves the line as plain text.
  defp context_path(%{metadata: %{"voice_kind" => "context_pointer", "context_space_id" => id}})
       when is_binary(id) do
    case Chat.get_space(id) do
      %{} = space -> "/chat/" <> Chat.space_path_segment(space)
      nil -> nil
    end
  end

  defp context_path(_msg), do: nil

  defp kind(%{metadata: %{"voice_kind" => "summary"}}), do: :summary
  defp kind(%{metadata: %{"voice_kind" => "context_pointer"}}), do: :pointer
  defp kind(_), do: :turn

  defp turn?(%{metadata: %{"voice_turn" => n}}) when is_integer(n), do: true
  defp turn?(_), do: false

  defp turns_label(n), do: Platform.Meetings.VoiceSession.turns_label(n)
  defp minutes_label(ms), do: Platform.Meetings.VoiceSession.minutes_label(ms)

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  # "7 Nov 14:20" in the viewer's zone when the browser sent one.
  @doc false
  def format_date(nil, _tz), do: nil

  def format_date(%DateTime{} = dt, tz) do
    local =
      case is_binary(tz) && DateTime.shift_zone(dt, tz) do
        {:ok, shifted} -> shifted
        _ -> dt
      end

    Calendar.strftime(local, "%-d %b %H:%M")
  end
end
