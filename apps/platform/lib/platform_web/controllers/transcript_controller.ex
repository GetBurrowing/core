defmodule PlatformWeb.TranscriptController do
  @moduledoc """
  Controller for downloading meeting transcripts as plain text files.

  The download endpoint is linked from the meeting summary message posted
  to the space after a meeting ends.

  ## Access

  A transcript is served only to a viewer who could open its meeting
  (`Platform.Meetings.get_transcript_for_user/2`, which reuses the meeting
  viewer rule `get_meeting_for_user/2`; a meeting-less transcript falls back
  to space participation). Everyone else gets the same 404 body as a
  nonexistent id, so transcript ids are not probeable. External users are
  already refused upstream by `PlatformWeb.Plugs.ExternalUserScope`; this
  check is defense in depth behind it.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings

  @doc """
  Download a transcript as a formatted plain text file.

  Returns the transcript segments formatted as:
    [HH:MM:SS] Speaker: text

  Responds with 404 if the transcript doesn't exist OR the current user
  could not open its meeting (the access check runs first, so a non-viewer
  gets 404 even for a recording transcript), or 422 if a viewer asks for a
  transcript that is still recording.
  """
  def show(conn, %{"id" => id}) do
    case Meetings.get_transcript_for_user(conn.assigns.current_user, id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Transcript not found"})

      {:ok, %{status: "recording"}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Transcript is still being recorded"})

      {:ok, transcript} ->
        formatted = format_transcript(transcript)
        filename = transcript_filename(transcript)

        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, formatted)
    end
  end

  # -- Private ---------------------------------------------------------------

  defp format_transcript(%{segments: segments} = _transcript) when is_list(segments) do
    segments
    |> Enum.map(&format_segment/1)
    |> Enum.join("\n")
  end

  defp format_transcript(_), do: ""

  defp format_segment(segment) do
    speaker = segment["speaker_name"] || segment["participant_identity"] || "Unknown"
    text = segment["text"] || ""
    timestamp = format_timestamp(segment["start_time"])

    "[#{timestamp}] #{speaker}: #{text}"
  end

  defp format_timestamp(nil), do: "00:00:00"

  defp format_timestamp(ms) when is_number(ms) do
    total_seconds = div(trunc(ms), 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, seconds])
    |> IO.iodata_to_binary()
  end

  defp format_timestamp(_), do: "00:00:00"

  defp transcript_filename(%{id: id, started_at: started_at}) do
    date =
      case started_at do
        %DateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d")
        _ -> "unknown-date"
      end

    "transcript-#{date}-#{String.slice(id, 0..7)}.txt"
  end
end
