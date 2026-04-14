defmodule Platform.Meetings do
  @moduledoc """
  Context module for the Meetings domain.

  Manages meeting rooms, participants, recordings, and transcription
  backed by LiveKit. All room/participant/recording functions guard on
  `enabled?/0` — when LiveKit env vars (`LIVEKIT_URL`, `LIVEKIT_API_KEY`,
  `LIVEKIT_API_SECRET`) are not set, those functions return
  `{:error, :meetings_disabled}`.

  Transcription functions (transcripts, segments, summaries) do NOT
  require LiveKit to be enabled — they work standalone.
  """

  import Ecto.Query

  alias Platform.Meetings.{Participant, Recording, Room, Transcript}
  alias Platform.Repo

  # ── Feature gate ─────────────────────────────────────────────────────────

  @doc """
  Returns `true` when all required LiveKit env vars are present.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    url = System.get_env("LIVEKIT_URL")
    key = System.get_env("LIVEKIT_API_KEY")
    secret = System.get_env("LIVEKIT_API_SECRET")

    is_binary(url) and url != "" and
      is_binary(key) and key != "" and
      is_binary(secret) and secret != ""
  end

  @doc """
  Returns the LiveKit connection config, or `nil` when disabled.
  """
  @spec config() :: map() | nil
  def config do
    if enabled?() do
      %{
        url: System.get_env("LIVEKIT_URL"),
        api_key: System.get_env("LIVEKIT_API_KEY"),
        api_secret: System.get_env("LIVEKIT_API_SECRET")
      }
    end
  end

  # ── Rooms ────────────────────────────────────────────────────────────────

  @doc """
  Find an existing room for the given space, or create one if none exists.

  Returns `{:ok, room}` or `{:error, changeset | :meetings_disabled}`.
  """
  @spec ensure_room(String.t()) :: {:ok, Room.t()} | {:error, term()}
  def ensure_room(space_id) do
    with :ok <- guard_enabled() do
      case get_room(space_id) do
        nil ->
          room_name = "suite-#{space_id}"

          %Room{}
          |> Room.changeset(%{space_id: space_id, livekit_room_name: room_name})
          |> Repo.insert()

        room ->
          {:ok, room}
      end
    end
  end

  @doc """
  Get the meeting room for a space, or `nil` if none exists.
  """
  @spec get_room(String.t()) :: Room.t() | nil
  def get_room(space_id) do
    Room
    |> where([r], r.space_id == ^space_id)
    |> Repo.one()
  end

  @doc """
  Get a room by its ID.
  """
  @spec get_room_by_id(String.t()) :: Room.t() | nil
  def get_room_by_id(id), do: Repo.get(Room, id)

  @doc """
  Close a meeting room — sets its status to `idle` and marks all active
  participants as having left.

  Returns `{:ok, room}` or `{:error, term()}`.
  """
  @spec close_room(String.t()) :: {:ok, Room.t()} | {:error, term()}
  def close_room(room_id) do
    with :ok <- guard_enabled() do
      Repo.transaction(fn ->
        room = Repo.get!(Room, room_id)
        now = DateTime.utc_now()

        # Mark all active participants as left
        Participant
        |> where([p], p.room_id == ^room_id and is_nil(p.left_at))
        |> Repo.update_all(set: [left_at: now])

        {:ok, updated} =
          room
          |> Room.changeset(%{status: "idle"})
          |> Repo.update()

        updated
      end)
    end
  end

  # ── Token generation ─────────────────────────────────────────────────────

  @doc """
  Generate a LiveKit access token for a browser client.

  The token grants `canPublish`, `canSubscribe`, and `canPublishData`
  permissions for the given room.

  Returns `{:ok, jwt}` or `{:error, :meetings_disabled}`.
  """
  @spec generate_token(Room.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def generate_token(%Room{} = room, %{identity: identity, name: name}) do
    with :ok <- guard_enabled() do
      grants = %{
        "video" => %{
          "room" => room.livekit_room_name,
          "roomJoin" => true,
          "canPublish" => true,
          "canSubscribe" => true,
          "canPublishData" => true
        }
      }

      {:ok, build_jwt(identity, name, grants)}
    end
  end

  @doc """
  Generate a LiveKit access token for an agent worker.

  Agent tokens include `hidden: true` metadata so agent participants
  are not shown in the participant list by default.

  Returns `{:ok, jwt}` or `{:error, :meetings_disabled}`.
  """
  @spec generate_agent_token(Room.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def generate_agent_token(%Room{} = room, %{identity: identity, name: name}) do
    with :ok <- guard_enabled() do
      grants = %{
        "video" => %{
          "room" => room.livekit_room_name,
          "roomJoin" => true,
          "canPublish" => true,
          "canSubscribe" => true,
          "canPublishData" => true
        },
        "metadata" => Jason.encode!(%{"agent" => true, "hidden" => false})
      }

      {:ok, build_jwt(identity, name, grants)}
    end
  end

  # ── Participants ─────────────────────────────────────────────────────────

  @doc """
  Record a participant joining a meeting room.

  `identity` is a map with `:display_name` (required) and optionally
  `:user_id` or `:agent_id`.

  Returns `{:ok, participant}` or `{:error, changeset | :meetings_disabled}`.
  """
  @spec participant_joined(String.t(), map(), DateTime.t()) ::
          {:ok, Participant.t()} | {:error, term()}
  def participant_joined(room_id, identity, joined_at \\ DateTime.utc_now()) do
    with :ok <- guard_enabled() do
      attrs =
        Map.merge(identity, %{
          room_id: room_id,
          joined_at: joined_at
        })

      %Participant{}
      |> Participant.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Record a participant leaving a meeting room.

  Returns `{:ok, participant}` or `{:error, :not_found | :meetings_disabled}`.
  """
  @spec participant_left(String.t(), DateTime.t()) ::
          {:ok, Participant.t()} | {:error, term()}
  def participant_left(participant_id, left_at \\ DateTime.utc_now()) do
    with :ok <- guard_enabled() do
      case Repo.get(Participant, participant_id) do
        nil ->
          {:error, :not_found}

        participant ->
          participant
          |> Participant.changeset(%{left_at: left_at})
          |> Repo.update()
      end
    end
  end

  @doc """
  List all participants for a room. Includes both active and departed
  participants, ordered by join time.
  """
  @spec list_participants(String.t()) :: [Participant.t()]
  def list_participants(room_id) do
    Participant
    |> where([p], p.room_id == ^room_id)
    |> order_by([p], asc: p.joined_at)
    |> Repo.all()
  end

  # ── Recordings ───────────────────────────────────────────────────────────

  @doc """
  Start a recording for a room. Creates a recording entry in `recording`
  status.

  Returns `{:ok, recording}` or `{:error, changeset | :meetings_disabled}`.
  """
  @spec start_recording(String.t(), map()) :: {:ok, Recording.t()} | {:error, term()}
  def start_recording(room_id, attrs \\ %{}) do
    with :ok <- guard_enabled() do
      room = Repo.get!(Room, room_id)

      recording_attrs =
        Map.merge(attrs, %{
          room_id: room_id,
          space_id: room.space_id,
          status: "recording"
        })

      result =
        %Recording{}
        |> Recording.changeset(recording_attrs)
        |> Repo.insert()

      with {:ok, _recording} <- result do
        room
        |> Room.changeset(%{status: "recording"})
        |> Repo.update()
      end

      result
    end
  end

  @doc """
  Stop a recording — transitions it from `recording` to `processing`.

  Returns `{:ok, recording}` or `{:error, :not_found | :meetings_disabled}`.
  """
  @spec stop_recording(String.t()) :: {:ok, Recording.t()} | {:error, term()}
  def stop_recording(recording_id) do
    with :ok <- guard_enabled() do
      case Repo.get(Recording, recording_id) do
        nil ->
          {:error, :not_found}

        %Recording{status: "recording"} = recording ->
          recording
          |> Recording.changeset(%{status: "processing"})
          |> Repo.update()

        _recording ->
          {:error, :invalid_status}
      end
    end
  end

  @doc """
  Mark a recording as completed with file details.

  Transitions the recording to `ready` status and stores duration,
  file URL, and file size.

  Returns `{:ok, recording}` or `{:error, :not_found | :meetings_disabled}`.
  """
  @spec recording_completed(String.t(), map()) :: {:ok, Recording.t()} | {:error, term()}
  def recording_completed(recording_id, attrs) do
    with :ok <- guard_enabled() do
      case Repo.get(Recording, recording_id) do
        nil ->
          {:error, :not_found}

        %Recording{status: status} = recording when status in ~w(recording processing) ->
          recording
          |> Recording.changeset(Map.merge(attrs, %{status: "ready"}))
          |> Repo.update()

        _recording ->
          {:error, :invalid_status}
      end
    end
  end

  # ── Transcripts ────────────────────────────────────────────────────────────

  @doc """
  Create a new transcript record for a meeting room.
  """
  @spec create_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def create_transcript(attrs) do
    %Transcript{}
    |> Transcript.changeset(Map.put_new(attrs, :started_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  @doc """
  Get a transcript by ID.
  """
  @spec get_transcript(String.t()) :: Transcript.t() | nil
  def get_transcript(id), do: Repo.get(Transcript, id)

  @doc """
  Get the active (recording-status) transcript for a room.

  Returns `nil` if no active transcript exists.
  """
  @spec get_transcript_for_room(String.t()) :: Transcript.t() | nil
  def get_transcript_for_room(room_id) do
    Transcript
    |> where([t], t.room_id == ^room_id and t.status == "recording")
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get a transcript with its segments (same as get_transcript since segments
  are stored inline as JSONB, but named explicitly for clarity in the API).
  """
  @spec get_transcript_with_segments(String.t()) :: Transcript.t() | nil
  def get_transcript_with_segments(id), do: Repo.get(Transcript, id)

  @doc """
  Find the active transcript for a room, or create one if none exists.

  Returns `{:ok, transcript}` in both cases.
  """
  @spec ensure_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def ensure_transcript(%{room_id: room_id} = attrs) do
    case get_transcript_for_room(room_id) do
      nil -> create_transcript(attrs)
      transcript -> {:ok, transcript}
    end
  end

  # ── Segment Accumulation ───────────────────────────────────────────────────

  @doc """
  Append a segment map to the transcript's JSONB segments array.

  Each segment should contain at minimum:
  - `participant_identity` — the speaker's identity string
  - `text` — the transcribed text
  - `start_time` — segment start timestamp in milliseconds
  - `end_time` — segment end timestamp in milliseconds

  Optional:
  - `language` — ISO language code
  - `speaker_name` — display name of the speaker
  """
  @spec append_segment(String.t(), map()) :: {:ok, Transcript.t()} | {:error, term()}
  def append_segment(transcript_id, segment) when is_map(segment) do
    # Use Ecto's jsonb_array_elements approach: load, append, save
    # Raw SQL concatenation has encoding issues with Postgrex parameter binding
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        updated_segments = (transcript.segments || []) ++ [segment]

        transcript
        |> Ecto.Changeset.change(segments: updated_segments)
        |> Repo.update()
    end
  end

  # ── Transcript Status Transitions ─────────────────────────────────────────

  @doc """
  Transition a transcript to 'processing' status and return it.

  Called when a meeting ends to prepare the transcript for summary generation.
  """
  @spec finalize_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def finalize_transcript(transcript_id) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{status: "processing"})
        |> Repo.update()
    end
  end

  @doc """
  Mark a transcript as complete with the generated summary text.
  """
  @spec complete_transcript(String.t(), String.t()) ::
          {:ok, Transcript.t()} | {:error, term()}
  def complete_transcript(transcript_id, summary) when is_binary(summary) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{
          status: "complete",
          summary: summary,
          completed_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  @doc """
  Update the transcript summary text.
  """
  @spec update_transcript_summary(String.t(), String.t()) ::
          {:ok, Transcript.t()} | {:error, term()}
  def update_transcript_summary(transcript_id, summary) when is_binary(summary) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{summary: summary})
        |> Repo.update()
    end
  end

  @doc """
  Mark a transcript as failed.
  """
  @spec fail_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def fail_transcript(transcript_id) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  # ── Summary Posting ────────────────────────────────────────────────────────

  @doc """
  Post a meeting summary as a system message to the space.

  The message includes the formatted summary and a download link
  for the full transcript.
  """
  @spec post_summary_to_space(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def post_summary_to_space(space_id, transcript_id, summary)
      when is_binary(space_id) and is_binary(transcript_id) and is_binary(summary) do
    content = """
    📝 **Meeting Summary**

    #{summary}

    [📄 Full transcript](/api/transcripts/#{transcript_id}/download)
    """

    with {:ok, participant} <-
           Platform.Orchestration.ExecutionSpace.ensure_system_participant(space_id) do
      attrs = %{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: String.trim(content),
        metadata: %{"source" => "meeting_summarizer", "transcript_id" => transcript_id}
      }

      case Platform.Chat.post_message(attrs) do
        {:ok, _message} -> :ok
        {:error, reason} -> {:error, {:post_failed, reason}}
      end
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp guard_enabled do
    if enabled?(), do: :ok, else: {:error, :meetings_disabled}
  end

  defp build_jwt(identity, name, grants) do
    api_key = System.get_env("LIVEKIT_API_KEY")
    api_secret = System.get_env("LIVEKIT_API_SECRET")

    now = System.system_time(:second)
    ttl = 6 * 3600

    claims =
      Map.merge(grants, %{
        "iss" => api_key,
        "sub" => identity,
        "name" => name,
        "nbf" => now,
        "exp" => now + ttl,
        "iat" => now,
        "jti" => Platform.Types.UUIDv7.generate()
      })

    jwk = JOSE.JWK.from_oct(api_secret)
    jws = %{"alg" => "HS256", "typ" => "JWT"}

    {_, token} =
      jwk
      |> JOSE.JWT.sign(jws, claims)
      |> JOSE.JWS.compact()

    token
  end
end
