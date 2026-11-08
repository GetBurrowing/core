defmodule Platform.Meetings.PastEvents do
  @moduledoc """
  Calendar's Past events (task 01a1b8a5 stage 4; prototype 01a178d2 v7
  `[data-past-events]`): the calls the viewer can look back on, newest first,
  one page at a time, each with the records it left behind.

  Built on the archive read model, not beside it. `Platform.Meetings.Archive`
  decides WHICH meetings (ended or cancelled, not soft-deleted, narrowed to
  the viewer by its three-branch rule) and pages them; this module only asks
  it for the un-queried page and adds the three records the overlay names.

  ## Every record is checked on its own

  A row the viewer may see does not make every record on it readable. Each
  record is admitted by its own rule, and a record that fails is reported
  absent, never linked:

    * **Summary** — the newest non-blank `summary` on a transcript of the
      meeting, and only from a transcript `Meetings.get_transcript_for_user/2`
      admits for this viewer.
    * **Transcript** — that same per-transcript check, plus a finished
      transcript (`status != "recording"`) with segments. The link is the
      existing download route, which runs the check again.
    * **Recording** — a `ready` `meeting_recordings` row with a `file_url`
      for the meeting's chat space, offered only when
      `Meetings.get_meeting_for_user/2` admits the meeting for this viewer.

  Nothing here is invented: a call that left no records says so, and a
  cancelled meeting (which never ran) has none by construction.

  ## Unavailable is not empty

  `page/2` answers `{:error, :unavailable}` when calls are off for the
  install (`Meetings.Config.enabled?/0`) or the viewer cannot use them
  (`meetings.join`), the same two facts `Calendar.Authoring.call_available?/1`
  reads; that is a different sentence in the UI from an empty page. Callers
  render both.
  """

  import Ecto.Query

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Meetings
  alias Platform.Meetings.{Archive, Recording, Transcript}
  alias Platform.Repo

  @per_page 20

  @type row :: %{
          id: binary(),
          name: String.t(),
          status: String.t(),
          at: DateTime.t() | nil,
          summary: String.t() | nil,
          transcript_id: binary() | nil,
          recording_url: String.t() | nil,
          project_path: String.t() | nil
        }

  @type page :: %{
          rows: [row()],
          page: pos_integer(),
          per_page: pos_integer(),
          total: non_neg_integer(),
          more?: boolean()
        }

  @doc "Rows per page."
  @spec per_page() :: pos_integer()
  def per_page, do: @per_page

  @doc """
  Page `page` (1-based; anything else is page 1) of the viewer's past
  events. See the moduledoc.
  """
  @spec page(Scope.t() | nil, term()) :: {:ok, page()} | {:error, :unavailable}
  def page(%Scope{actor: %{id: _} = viewer} = scope, page) do
    if Meetings.Config.enabled?() and Access.can?(scope, "meetings.join") do
      {:ok, load(viewer, normalize_page(page))}
    else
      {:error, :unavailable}
    end
  end

  def page(_scope, _page), do: {:error, :unavailable}

  @doc false
  def normalize_page(page) when is_integer(page) and page > 0, do: page

  def normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 and n < 100_000 -> n
      _ -> 1
    end
  end

  def normalize_page(_page), do: 1

  @doc """
  The records one past call left, for the event details' "After the call"
  panel: `%{summary, transcript_id, recording_url}`, each checked for
  `viewer` exactly as on a `page/2` row. A meeting that is not over yet has
  none.
  """
  @spec records(map() | nil, map()) :: %{
          summary: String.t() | nil,
          transcript_id: binary() | nil,
          recording_url: String.t() | nil
        }
  def records(viewer, %{id: id, status: "ended"} = meeting) do
    own = viewer |> readable_transcripts([meeting]) |> Map.get(id, [])

    %{
      summary: summary(own),
      transcript_id: transcript_id(own),
      recording_url: viewer |> readable_recordings([meeting]) |> Map.get(id)
    }
  end

  def records(_viewer, _meeting), do: %{summary: nil, transcript_id: nil, recording_url: nil}

  defp summary(transcripts),
    do: transcripts |> Enum.map(& &1.summary) |> Enum.reject(&blank?/1) |> List.first() |> trim()

  defp transcript_id(transcripts) do
    Enum.find_value(transcripts, fn t ->
      t.status != "recording" and t.segments not in [nil, []] and t.id
    end)
  end

  defp load(viewer, page) do
    result = Archive.search(viewer, limit: @per_page, offset: (page - 1) * @per_page)
    meetings = result.matches ++ result.others
    context = Archive.artifacts_for(viewer, meetings)
    transcripts = readable_transcripts(viewer, meetings)
    recordings = readable_recordings(viewer, meetings)

    rows =
      Enum.map(meetings, fn m ->
        own = Map.get(transcripts, m.id, [])

        %{
          id: m.id,
          name: m.name,
          status: m.status,
          at: m.ended_at || m.cancelled_at || m.scheduled_start_at,
          summary: summary(own),
          transcript_id: transcript_id(own),
          recording_url: Map.get(recordings, m.id),
          project_path: get_in(context, [m.id, :project_path])
        }
      end)

    %{
      rows: rows,
      page: page,
      per_page: @per_page,
      total: result.total,
      more?: (page - 1) * @per_page + length(meetings) < result.total
    }
  end

  # Newest first. Joined by meeting id OR by the meeting's chat space, the
  # two keys a transcript carries (Archive's moduledoc: never `room_id`).
  # Each candidate then passes the download route's own viewer rule.
  defp readable_transcripts(_viewer, []), do: %{}

  defp readable_transcripts(viewer, meetings) do
    by_space = Map.new(meetings, &{&1.chat_space_id, &1.id})
    ids = Enum.map(meetings, & &1.id)
    spaces = meetings |> Enum.map(& &1.chat_space_id) |> Enum.reject(&is_nil/1)

    from(t in Transcript,
      where: t.meeting_id in ^ids or t.space_id in ^spaces,
      order_by: [desc: t.inserted_at],
      select: %{
        id: t.id,
        meeting_id: t.meeting_id,
        space_id: t.space_id,
        status: t.status,
        summary: t.summary,
        segments: t.segments
      }
    )
    |> Repo.all()
    |> Enum.filter(&match?({:ok, _}, Meetings.get_transcript_for_user(viewer, &1.id)))
    |> Enum.group_by(&(&1.meeting_id || Map.get(by_space, &1.space_id)))
  end

  defp readable_recordings(_viewer, []), do: %{}

  defp readable_recordings(viewer, meetings) do
    spaces = meetings |> Enum.map(& &1.chat_space_id) |> Enum.reject(&is_nil/1)

    latest =
      from(r in Recording,
        where: r.space_id in ^spaces and r.status == "ready" and not is_nil(r.file_url),
        order_by: [desc: r.inserted_at],
        select: {r.space_id, r.file_url}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {space, url}, acc -> Map.put_new(acc, space, url) end)

    for m <- meetings,
        url = Map.get(latest, m.chat_space_id),
        is_binary(url),
        match?({:ok, _}, Meetings.get_meeting_for_user(viewer, m.id)),
        into: %{},
        do: {m.id, url}
  end

  defp blank?(value), do: value in [nil, ""] or String.trim(value) == ""

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
