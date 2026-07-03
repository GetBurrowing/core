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

  Guards on `Meetings.app_registered_room?/1` against `room["name"]` so
  phantom LiveKit rooms (auto-generated `RM_<random>` names produced
  without a prior `CreateRoom`) never spawn transcripts. The persisted
  `room_id` still keys off `sid || name` so `room_finished` lookup
  symmetry holds for legitimate rooms.
  """
  def handle(conn, %{"event" => "room_started", "room" => room} = _params) do
    room_id = room["sid"] || room["name"]
    room_name = room["name"]
    space_id = space_id_from_room_name(room_name)

    cond do
      not Meetings.app_registered_room?(room_name) ->
        # `:warning` (not `:info`) because a phantom-room delivery is a
        # signal worth noticing in prod — either LiveKit materialised
        # a room without our `CreateRoom` (mis-scoped token, webhook
        # replay after GC) or a client bypassed the app-controlled
        # naming contract.
        Logger.warning(
          "[LiveKit] Ignoring room_started for unregistered room #{inspect(room_name)} (sid=#{inspect(room["sid"])})"
        )

        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unregistered room"})

      room_id ->
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

      true ->
        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "no room identifier"})
    end
  end

  @doc """
  Handle `room_finished` events — finalize transcript and trigger summary.

  Includes a defensive post-hoc sweep for phantom transcripts: if the room
  is not app-registered AND the transcript has zero segments, delete the
  row outright instead of finalizing. Stage 2's `room_started` +
  `transcription` guards should prevent phantom transcripts from being
  created in the first place, but this belt-and-suspenders sweep catches
  historical rows (created before this task shipped) or any case where a
  phantom room slipped past the source filter. A phantom room that
  somehow accumulated segments still gets finalized — that's not the
  common case, but it's the safer default than silently dropping data.
  """
  def handle(conn, %{"event" => "room_finished", "room" => room} = params) do
    room_id = room["sid"] || room["name"]
    room_name = room["name"]

    # Deactivation symmetry for task 019e4b3e v4 stage 1: a real join flips
    # the room "active" (MeetingHooks.do_join → Meetings.activate_room).
    # LiveKit's `room_finished` is the canonical empty-room signal, so flip
    # the room back to "idle" + mark stragglers left here, otherwise rooms
    # would leak as "active" forever once the join-path activation lands.
    case lookup_room(params) do
      %Meetings.Room{status: "active"} = active_room -> Meetings.finish_room(active_room)
      _ -> :ok
    end

    # End-meeting symmetry: `Meetings.start_meeting/1` drives a meeting
    # scheduled → live on auto-join, but nothing transitions it live → ended.
    # `room_finished` is LiveKit's canonical empty-room signal (fires ~20-30s
    # after the last participant leaves), so end the space's live meeting here
    # — otherwise it stays "Live now" forever. The status_changeset rejects
    # illegal transitions, but we still guard on the live lookup so a space
    # with only scheduled/ended meetings is a clean no-op.
    case Meetings.get_live_meeting_for_space(space_id_from_room_name(room["name"])) do
      %Meetings.Meeting{} = live_meeting -> Meetings.end_meeting(live_meeting)
      _ -> :ok
    end

    if room_id do
      case Meetings.get_transcript_for_room(room_id) do
        nil ->
          Logger.debug("[LiveKit] No active transcript for room #{room_id} on room_finished")

          conn
          |> put_status(:ok)
          |> json(%{status: "ignored", reason: "no active transcript"})

        transcript ->
          cond do
            not Meetings.app_registered_room?(room_name) and Enum.empty?(transcript.segments) ->
              # Phantom room with no accumulated audio: drop the row entirely
              # rather than finalize + dispatch a summary. This is the
              # sweep half of stage 2's source-filter — anything that got
              # in before stage 2's guards existed, or that races past
              # them, gets cleaned up here.
              Logger.info(
                "[LiveKit] Deleting phantom transcript #{transcript.id} for unregistered room " <>
                  "#{inspect(room_name)} (sid=#{inspect(room["sid"])}) with 0 segments"
              )

              case Meetings.delete_transcript(transcript) do
                {:ok, deleted} ->
                  conn
                  |> put_status(:ok)
                  |> json(%{
                    status: "deleted",
                    reason: "phantom_empty_transcript",
                    transcript_id: deleted.id
                  })

                {:error, reason} ->
                  Logger.warning(
                    "[LiveKit] Failed to delete phantom transcript #{transcript.id}: #{inspect(reason)}"
                  )

                  conn
                  |> put_status(:unprocessable_entity)
                  |> json(%{status: "error", reason: inspect(reason)})
              end

            true ->
              case Meetings.finalize_transcript(transcript.id) do
                {:ok, finalized} ->
                  Logger.info(
                    "[LiveKit] Finalized transcript #{finalized.id} for room #{room_id}"
                  )

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
    room_name = room["name"]
    space_id = space_id_from_room_name(room_name)
    raw_segments = params["segments"] || []

    cond do
      not Meetings.app_registered_room?(room_name) ->
        # See `room_started` handler for the `:warning` (not `:info`)
        # rationale — same phantom-room signal, same operational value.
        Logger.warning(
          "[LiveKit] Ignoring transcription for unregistered room #{inspect(room_name)} (sid=#{inspect(room["sid"])})"
        )

        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unregistered room"})

      room_id && raw_segments != [] ->
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

      true ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ignored", reason: "no room identifier or empty segments"})
    end
  end

  @doc """
  Handle `participant_joined` events — upsert a resolvable
  `meeting_participants` row so the rail/gallery render the joiner's real
  name (not the literal "User"). The webhook is the only server-side
  signal that a participant actually connected to the LiveKit room.
  """
  def handle(conn, %{"event" => "participant_joined"} = params) do
    participant = normalize_participant(params)

    case lookup_room(params) do
      nil ->
        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unknown room"})

      room ->
        case Meetings.upsert_live_participant(room, %{
               identity: participant["identity"],
               name: participant["name"]
             }) do
          {:ok, p} ->
            Logger.info(
              "[LiveKit] participant_joined room=#{room.livekit_room_name} " <>
                "identity=#{participant["identity"]} participant_id=#{p.id}"
            )

            conn |> put_status(:ok) |> json(%{status: "ok", participant_id: p.id})

          {:error, reason} ->
            Logger.warning(
              "[LiveKit] participant_joined upsert failed for room #{room.livekit_room_name}: " <>
                inspect(reason)
            )

            conn |> put_status(:unprocessable_entity) |> json(%{status: "error"})
        end
    end
  end

  @doc """
  Handle `participant_left` events — set `left_at` on the matching active
  row. Tolerates a leave for a participant we never recorded.
  """
  def handle(conn, %{"event" => "participant_left"} = params) do
    participant = normalize_participant(params)

    case lookup_room(params) do
      nil ->
        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unknown room"})

      room ->
        case Meetings.mark_live_participant_left(room, %{
               identity: participant["identity"],
               name: participant["name"]
             }) do
          {:ok, p} ->
            conn |> put_status(:ok) |> json(%{status: "ok", participant_id: p.id})

          {:error, :not_found} ->
            conn |> put_status(:ok) |> json(%{status: "ignored", reason: "participant not found"})
        end
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

  # Resolve the meeting room from a webhook payload. Room name lives at
  # `room["name"]` (e.g. `"space-<uuid>"`); returns nil when absent or
  # when no room row exists yet.
  defp lookup_room(%{"room" => %{"name" => name}}) when is_binary(name) do
    Meetings.get_room_by_name(name)
  end

  defp lookup_room(_params), do: nil

  # LiveKit nests the participant under `participant`; older/flattened
  # payloads put `identity`/`name` at the top level. Mirror the
  # `seg["participant_identity"] || seg["identity"]` fallback in
  # normalize_segment/1.
  defp normalize_participant(%{"participant" => participant}) when is_map(participant),
    do: participant

  defp normalize_participant(params), do: params

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
    _ = Platform.Meetings.Summarizer.summarize_async(transcript)

    # M8 stage 3: broadcast the canonical `:meeting_finished` event so
    # the responsibility router can fire `meetings.summarize`. The
    # broadcast is UNCONDITIONAL — it's a notification, not a request,
    # and downstream subscribers (router, LiveViews) decide whether to
    # act. The legacy `Summarizer.summarize_async/1` call above stays
    # as the fallback path until the cutover monitor proves the
    # router-fired path is stable.
    Platform.Meetings.PubSub.broadcast_meeting_finished(transcript.room_id, %{
      transcript_id: transcript.id,
      room_id: transcript.room_id,
      space_id: Map.get(transcript, :space_id)
    })

    :ok
  end

  # LiveKit room names in Suite follow `space-<uuid>` — recover the space
  # UUID from the name so transcripts can be linked back to their space.
  defp space_id_from_room_name("space-" <> uuid) do
    if String.length(uuid) == 36, do: uuid, else: nil
  end

  defp space_id_from_room_name(_), do: nil
end
