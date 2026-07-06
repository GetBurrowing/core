defmodule PlatformWeb.MeetingAgentController do
  @moduledoc """
  Receives transcription segments from the `meeting-transcriber` agent.

  Separate from the LiveKit webhook because LiveKit doesn't emit a
  `transcription` webhook event — segments come directly from the agent
  as it produces them. Auth is a shared bearer token (`MEETING_AGENT_TOKEN`)
  baked into both sides; when unset, the endpoint returns 401.

  Keyed by LiveKit `room_sid` (per-instance unique), so two meetings in the
  same space get separate transcripts automatically.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings

  require Logger

  @doc """
  POST /api/meetings/segments

  Body shape:
      {
        "room_sid": "RM_...",
        "room_name": "space-<uuid>",
        "segments": [
          {
            "participant_identity": "user:...",
            "speaker_name": "Rowan",
            "text": "hello",
            "start_time": 0,
            "end_time": 0,
            "language": "en",
            "final": true
          }
        ]
      }
  """
  def segments(conn, %{"room_sid" => room_sid, "segments" => raw} = params)
      when is_binary(room_sid) and is_list(raw) do
    with :ok <- verify_token(conn),
         :ok <- verify_room(params) do
      space_id = space_id_from_room_name(params["room_name"])
      room_id = params["room_name"] || room_sid

      case Meetings.ensure_transcript(%{room_id: room_id, space_id: space_id}) do
        {:ok, transcript} ->
          results =
            Enum.map(raw, fn seg ->
              Meetings.append_segment(transcript.id, normalize_segment(seg))
            end)

          errors = Enum.filter(results, &match?({:error, _}, &1))

          if errors == [] do
            conn
            |> put_status(:ok)
            |> json(%{status: "appended", transcript_id: transcript.id, count: length(raw)})
          else
            Logger.warning("[MeetingAgent] #{length(errors)} of #{length(raw)} segments failed")

            conn
            |> put_status(:ok)
            |> json(%{
              status: "partial",
              transcript_id: transcript.id,
              appended: length(raw) - length(errors),
              failed: length(errors)
            })
          end

        {:error, reason} ->
          Logger.warning("[MeetingAgent] ensure_transcript failed: #{inspect(reason)}")
          conn |> put_status(:unprocessable_entity) |> json(%{status: "error"})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{status: "unauthorized"})

      {:error, :unregistered_room} ->
        Logger.warning(
          "[MeetingAgent] Ignoring segments for unregistered room " <>
            "name=#{inspect(params["room_name"])} sid=#{inspect(room_sid)}"
        )

        conn
        |> put_status(:ok)
        |> json(%{status: "ignored", reason: "unregistered room"})
    end
  end

  def segments(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{status: "bad_request"})
  end

  # ── Private ──────────────────────────────────────────────────────────────

  # Payload-level guard: reject segments for room names that don't
  # resolve to a real Suite chat space (task 019f3312 stage 1). The
  # bearer-token check upstream is necessary but not sufficient — an
  # attacker with the shared token could still POST fabricated
  # `space-<random-uuid>` names, so gate on `Meetings.legit_room?/1`
  # before touching the DB.
  defp verify_room(params) do
    room_payload = %{"name" => params["room_name"], "sid" => params["room_sid"]}

    if Meetings.legit_room?(room_payload) do
      :ok
    else
      {:error, :unregistered_room}
    end
  end

  defp verify_token(conn) do
    expected = System.get_env("MEETING_AGENT_TOKEN")

    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    cond do
      is_nil(expected) or expected == "" -> {:error, :unauthorized}
      presented == expected -> :ok
      true -> {:error, :unauthorized}
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

  defp space_id_from_room_name("space-" <> uuid) do
    if String.length(uuid) == 36, do: uuid, else: nil
  end

  defp space_id_from_room_name(_), do: nil
end
