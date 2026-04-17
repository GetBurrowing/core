defmodule PlatformWeb.LivekitWebhookController do
  @moduledoc """
  Receives LiveKit webhook events and processes transcription data.

  Handles:
  - `room_started` → auto-creates a transcript record for the meeting room
  - `room_finished` → finalizes the transcript and triggers the summary pipeline
  - `transcription` → appends transcription segments to the active transcript

  LiveKit sends webhooks as JSON with an `event` field indicating the event type.
  Signature verification uses the LiveKit API secret via HMAC-SHA256 on the
  `Authorization` header token (JWT-based), but is optional for initial integration.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings

  require Logger

  # ── Handlers ─────────────────────────────────────────────────────────────

  @doc """
  Handle `room_started` events — auto-create a transcript record.
  """
  def handle(conn, %{"event" => "room_started", "room" => room} = _params) do
    room_id = room["sid"] || room["name"]
    space_id = space_id_from_room_name(room["name"])

    if room_id do
      case Meetings.ensure_transcript(%{room_id: room_id, space_id: space_id}) do
        {:ok, transcript} ->
          Logger.info("[LiveKit] Created transcript #{transcript.id} for room #{room_id}")

          conn
          |> put_status(:created)
          |> json(%{status: "created", transcript_id: transcript.id})

        {:error, reason} ->
          Logger.warning(
            "[LiveKit] Failed to create transcript for room #{room_id}: #{inspect(reason)}"
          )

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{status: "error", reason: inspect(reason)})
      end
    else
      conn |> put_status(:ok) |> json(%{status: "ignored", reason: "no room identifier"})
    end
  end

  @doc """
  Handle `room_finished` events — finalize transcript and trigger summary.
  """
  def handle(conn, %{"event" => "room_finished", "room" => room} = _params) do
    room_id = room["sid"] || room["name"]

    if room_id do
      case Meetings.get_transcript_for_room(room_id) do
        nil ->
          Logger.debug("[LiveKit] No active transcript for room #{room_id} on room_finished")

          conn
          |> put_status(:ok)
          |> json(%{status: "ignored", reason: "no active transcript"})

        transcript ->
          case Meetings.finalize_transcript(transcript.id) do
            {:ok, finalized} ->
              Logger.info("[LiveKit] Finalized transcript #{finalized.id} for room #{room_id}")

              # Trigger async LLM summary generation
              maybe_trigger_summary(finalized)

              conn
              |> put_status(:ok)
              |> json(%{
                status: "finalized",
                transcript_id: finalized.id,
                segment_count: length(finalized.segments)
              })

            {:error, reason} ->
              Logger.warning(
                "[LiveKit] Failed to finalize transcript #{transcript.id}: #{inspect(reason)}"
              )

              conn
              |> put_status(:unprocessable_entity)
              |> json(%{status: "error", reason: inspect(reason)})
          end
      end
    else
      conn |> put_status(:ok) |> json(%{status: "ignored", reason: "no room identifier"})
    end
  end

  @doc """
  Handle `transcription` events — append segments to the active transcript.

  LiveKit sends transcription segments with participant identity, text,
  start/end times, and language. Each segment is appended to the transcript's
  JSONB segments array.
  """
  def handle(conn, %{"event" => "transcription", "room" => room} = params) do
    room_id = room["sid"] || room["name"]
    space_id = space_id_from_room_name(room["name"])
    raw_segments = params["segments"] || []

    if room_id && raw_segments != [] do
      case Meetings.get_transcript_for_room(room_id) do
        nil ->
          # Auto-create transcript if one doesn't exist yet (race condition safety)
          case Meetings.ensure_transcript(%{room_id: room_id, space_id: space_id}) do
            {:ok, transcript} ->
              append_segments(conn, transcript.id, raw_segments, room_id)

            {:error, reason} ->
              Logger.warning(
                "[LiveKit] Failed to ensure transcript for room #{room_id}: #{inspect(reason)}"
              )

              conn
              |> put_status(:unprocessable_entity)
              |> json(%{status: "error", reason: inspect(reason)})
          end

        transcript ->
          append_segments(conn, transcript.id, raw_segments, room_id)
      end
    else
      conn
      |> put_status(:ok)
      |> json(%{status: "ignored", reason: "no room identifier or empty segments"})
    end
  end

  @doc """
  Catch-all for unhandled event types.
  """
  def handle(conn, %{"event" => event} = _params) do
    Logger.debug("[LiveKit] Ignoring event: #{event}")
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unhandled event: #{event}"})
  end

  def handle(conn, _params) do
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: "no event field"})
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp append_segments(conn, transcript_id, raw_segments, room_id) do
    results =
      Enum.map(raw_segments, fn seg ->
        segment = normalize_segment(seg)
        Meetings.append_segment(transcript_id, segment)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      Logger.debug(
        "[LiveKit] Appended #{length(raw_segments)} segments to transcript for room #{room_id}"
      )

      conn
      |> put_status(:ok)
      |> json(%{
        status: "appended",
        transcript_id: transcript_id,
        segments_appended: length(raw_segments)
      })
    else
      Logger.warning(
        "[LiveKit] #{length(errors)} segment(s) failed for room #{room_id}: #{inspect(errors)}"
      )

      conn
      |> put_status(:ok)
      |> json(%{
        status: "partial",
        transcript_id: transcript_id,
        segments_appended: length(raw_segments) - length(errors),
        segments_failed: length(errors)
      })
    end
  end

  defp normalize_segment(seg) do
    %{
      "participant_identity" => seg["participant_identity"] || seg["identity"],
      "speaker_name" => seg["speaker_name"] || seg["name"],
      "text" => seg["text"] || "",
      "start_time" => seg["start_time"] || 0,
      "end_time" => seg["end_time"] || 0,
      "language" => seg["language"],
      "final" => seg["final"] != false
    }
  end

  defp maybe_trigger_summary(transcript) do
    Platform.Meetings.Summarizer.summarize_async(transcript)
  end

  # LiveKit room names in Suite follow `space-<uuid>` — recover the space
  # UUID from the name so transcripts can be linked back to their space.
  defp space_id_from_room_name("space-" <> uuid) do
    if String.length(uuid) == 36, do: uuid, else: nil
  end

  defp space_id_from_room_name(_), do: nil
end
