defmodule Platform.Meetings do
  @moduledoc """
  Context for the Meetings domain.

  Manages meeting rooms, participant presence, recordings, and transcription
  backed by LiveKit. Broadcasts presence and recording changes via
  `Platform.Meetings.PubSub`.

  All room/participant/recording functions guard on `enabled?/0` — when
  LiveKit env vars are not set, those functions return
  `{:error, :meetings_disabled}`.

  Transcription functions (transcripts, segments, summaries) do NOT
  require LiveKit to be enabled — they work standalone.
  """

  import Ecto.Query

  alias Platform.Meetings.{Participant, Recording, Room, Transcript}
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  require Logger

  # ── Configuration ─────────────────────────────────────────────────────────

  @doc """
  Returns true when all required LiveKit env vars are set:
  LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.

  Used to gate the "Join Meeting" button in the UI.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = livekit_config()

    is_binary(config[:url]) and config[:url] != "" and
      is_binary(config[:api_key]) and config[:api_key] != "" and
      is_binary(config[:api_secret]) and config[:api_secret] != ""
  end

  @doc """
  Returns the LiveKit connection config, or `nil` when disabled.
  """
  @spec config() :: map() | nil
  def config do
    if enabled?() do
      config = livekit_config()

      %{
        url: config[:url],
        api_key: config[:api_key],
        api_secret: config[:api_secret]
      }
    end
  end

  @doc "Returns the configured LiveKit server URL."
  @spec livekit_url() :: String.t() | nil
  def livekit_url, do: livekit_config()[:url]

  # ── PubSub Topic Helpers ─────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a meeting room: `\"meetings:room:{room_id}\"`."
  @spec meeting_presence_topic(binary()) :: String.t()
  defdelegate meeting_presence_topic(room_id), to: MeetingsPubSub, as: :room_topic

  @doc "Returns the global presence summary topic: `\"meetings:presence_summary\"`."
  @spec meeting_presence_summary_topic() :: String.t()
  defdelegate meeting_presence_summary_topic(), to: MeetingsPubSub, as: :presence_summary_topic

  @doc "Subscribe to presence events for a specific meeting room."
  @spec subscribe_to_room_presence(binary()) :: :ok | {:error, term()}
  defdelegate subscribe_to_room_presence(room_id), to: MeetingsPubSub, as: :subscribe_room

  @doc "Subscribe to the global presence summary topic for sidebar indicators."
  @spec subscribe_to_presence_summary() :: :ok | {:error, term()}
  defdelegate subscribe_to_presence_summary(), to: MeetingsPubSub, as: :subscribe_presence_summary

  # ── Rooms ────────────────────────────────────────────────────────────────

  @doc "Find or create a room by its LiveKit room name."
  @spec find_or_create_room(String.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_room(livekit_room_name) do
    case Repo.get_by(Room, livekit_room_name: livekit_room_name) do
      nil ->
        %Room{}
        |> Room.changeset(%{livekit_room_name: livekit_room_name})
        |> Repo.insert()

      room ->
        {:ok, room}
    end
  end

  @doc "Get a room by ID."
  @spec get_room(binary()) :: Room.t() | nil
  def get_room(id), do: Repo.get(Room, id)

  @doc "Get a room by LiveKit room name."
  @spec get_room_by_name(String.t()) :: Room.t() | nil
  def get_room_by_name(name), do: Repo.get_by(Room, livekit_room_name: name)

  @doc """
  Ensure a meeting room exists for a space.

  Uses `"space:{space_id}"` as the LiveKit room name. If a room already
  exists for this space, returns it; otherwise creates one. Also attempts
  to create the room on the LiveKit server via Twirp API (gracefully
  handles failure).
  """
  @spec ensure_room(binary()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def ensure_room(space_id) do
    room_name = room_name_for_space(space_id)

    case Repo.get_by(Room, space_id: space_id) do
      nil ->
        # Create room in LiveKit via Twirp API
        case ensure_livekit_room(room_name) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Meetings] LiveKit CreateRoom failed: #{inspect(reason)}, proceeding with DB only"
            )
        end

        %Room{}
        |> Room.changeset(%{livekit_room_name: room_name, space_id: space_id})
        |> Repo.insert()

      room ->
        {:ok, room}
    end
  end

  @doc "Get the active (non-idle) room for a space, if any."
  @spec get_active_room(binary()) :: Room.t() | nil
  def get_active_room(space_id) do
    Room
    |> where([r], r.space_id == ^space_id and r.status == "active")
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Update room status to active."
  @spec activate_room(Room.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def activate_room(%Room{} = room) do
    result =
      room
      |> Room.changeset(%{status: "active"})
      |> Repo.update()

    case result do
      {:ok, updated_room} ->
        MeetingsPubSub.broadcast_room(room.id, {:room_activated, updated_room})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated_room}

      error ->
        error
    end
  end

  @doc "Set room to idle and mark all active participants as left."
  @spec finish_room(Room.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def finish_room(%Room{} = room) do
    now = DateTime.utc_now()

    # Mark all active participants as left
    from(p in Participant,
      where: p.room_id == ^room.id and is_nil(p.left_at)
    )
    |> Repo.update_all(set: [left_at: now])

    result =
      room
      |> Room.changeset(%{status: "idle"})
      |> Repo.update()

    case result do
      {:ok, updated_room} ->
        MeetingsPubSub.broadcast_room(room.id, {:room_finished, updated_room})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated_room}

      error ->
        error
    end
  end

  # ── Participants ─────────────────────────────────────────────────────────

  @doc """
  Record a participant joining a room.

  Broadcasts `{:participant_joined, participant}` on the room topic and
  updates the presence summary for the sidebar.
  """
  @spec participant_joined(Room.t(), map()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def participant_joined(%Room{} = room, attrs) do
    result =
      %Participant{}
      |> Participant.changeset(
        Map.merge(attrs, %{
          room_id: room.id,
          joined_at: Map.get(attrs, :joined_at, DateTime.utc_now())
        })
      )
      |> Repo.insert()

    case result do
      {:ok, participant} ->
        MeetingsPubSub.broadcast_room(room.id, {:participant_joined, participant})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, participant}

      error ->
        error
    end
  end

  @doc """
  Record a participant leaving a room.

  Finds the most recent active participant record matching the identity,
  sets `left_at`, and broadcasts the change.
  """
  @spec participant_left(Room.t(), String.t()) ::
          {:ok, Participant.t()} | {:error, :not_found}
  def participant_left(%Room{} = room, display_name) do
    query =
      from(p in Participant,
        where: p.room_id == ^room.id and p.display_name == ^display_name and is_nil(p.left_at),
        order_by: [desc: p.joined_at],
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      participant ->
        {:ok, updated} =
          participant
          |> Participant.changeset(%{left_at: DateTime.utc_now()})
          |> Repo.update()

        MeetingsPubSub.broadcast_room(room.id, {:participant_left, updated})
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated}
    end
  end

  @doc """
  List active (not yet left) participants in a room, preloading user and
  agent associations for display name and avatar resolution.
  """
  @spec active_participants(binary()) :: [Participant.t()]
  def active_participants(room_id) do
    from(p in Participant,
      where: p.room_id == ^room_id and is_nil(p.left_at),
      order_by: [asc: p.joined_at],
      preload: [:user, :agent]
    )
    |> Repo.all()
  end

  # ── Space-level presence queries ─────────────────────────────────────────

  @doc """
  List all active (connected) participants for a space's current meeting.
  Returns an empty list if no active meeting exists. Preloads user/agent.
  """
  @spec active_participants_for_space(binary()) :: [Participant.t()]
  def active_participants_for_space(space_id) do
    case get_active_room(space_id) do
      nil -> []
      room -> active_participants(room.id)
    end
  end

  @doc "Count active participants for a space's current meeting."
  @spec active_participant_count(binary()) :: non_neg_integer()
  def active_participant_count(space_id) do
    case get_active_room(space_id) do
      nil ->
        0

      room ->
        from(p in Participant,
          where: p.room_id == ^room.id and is_nil(p.left_at)
        )
        |> Repo.aggregate(:count)
    end
  end

  @doc """
  For a list of space IDs, return a map of `%{space_id => participant_count}`
  for spaces that have an active meeting with at least one participant.

  Used by the sidebar to show meeting indicators efficiently in a single query.
  """
  @spec active_meeting_counts([binary()]) :: %{binary() => non_neg_integer()}
  def active_meeting_counts([]), do: %{}

  def active_meeting_counts(space_ids) when is_list(space_ids) do
    Room
    |> join(:inner, [r], p in Participant, on: p.room_id == r.id and is_nil(p.left_at))
    |> where([r, _p], r.space_id in ^space_ids and r.status == "active")
    |> group_by([r, _p], r.space_id)
    |> select([r, p], {r.space_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ── Token Generation ─────────────────────────────────────────────────────

  @doc """
  Generate a LiveKit access token (JWT) for a user to join a room.

  The token is an HS256 JWT signed with `LIVEKIT_API_SECRET`, containing:
  - `iss` — the API key
  - `sub` — the user identity
  - `exp` — expiry (default 6 hours)
  - `video` — grant with room name and permissions

  Returns `{:ok, token_string}` or `{:error, reason}`.
  """
  @spec generate_token(Room.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def generate_token(%Room{} = room, %{identity: identity, name: name}) do
    config = livekit_config()
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      now = System.system_time(:second)
      ttl = 6 * 60 * 60

      claims = %{
        "iss" => api_key,
        "sub" => identity,
        "nbf" => now,
        "exp" => now + ttl,
        "jti" => Ecto.UUID.generate(),
        "name" => name,
        "video" => %{
          "room" => room.livekit_room_name,
          "roomJoin" => true,
          "canPublish" => true,
          "canSubscribe" => true,
          "canPublishData" => true
        }
      }

      {:ok, encode_jwt(claims, api_secret)}
    end
  end

  @doc """
  Generate a LiveKit access token from a room name string.

  Simpler API for cases where you have the room name directly
  (e.g. from `ensure_room/1` or `room_name_for_space/1`).

  Options:
    - `:name` — display name (defaults to identity)
    - `:ttl` — token TTL in seconds (default: 6 hours)

  Returns the signed JWT string.
  """
  def generate_token(room_name, identity, opts)
      when is_binary(room_name) and is_binary(identity) do
    config = livekit_config()
    name = Keyword.get(opts, :name, identity)
    ttl = Keyword.get(opts, :ttl, 21_600)

    now = System.system_time(:second)

    claims = %{
      "iss" => config[:api_key],
      "sub" => identity,
      "nbf" => now,
      "exp" => now + ttl,
      "jti" => :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false),
      "name" => name,
      "video" => %{
        "room" => room_name,
        "roomJoin" => true,
        "canPublish" => true,
        "canSubscribe" => true,
        "canPublishData" => true
      }
    }

    sign_jwt(claims, config[:api_secret])
  end

  @doc """
  Generate a LiveKit access token from a room name string with default options.
  """
  def generate_token(room_name, identity) when is_binary(room_name) and is_binary(identity) do
    generate_token(room_name, identity, [])
  end

  @doc """
  Generate a LiveKit access token for an agent worker.

  Agent tokens include `hidden: true` metadata so agent participants
  are not shown in the participant list by default.

  Returns `{:ok, jwt}` or `{:error, :livekit_not_configured}`.
  """
  @spec generate_agent_token(Room.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def generate_agent_token(%Room{} = room, %{identity: identity, name: name}) do
    config = livekit_config()
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
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

  # ── Presence Broadcasting (private) ──────────────────────────────────────

  @doc """
  Broadcast a presence change for a room.

  Sends `{:meeting_presence, %{room_id, event}}` on the room topic AND
  `{:meeting_presence_summary, %{space_id}}` on the summary topic.
  Also sends a `{:meeting_presence_update, %{space_id, active, count}}`
  on the per-space presence topic.
  """
  @spec broadcast_presence_change(binary(), binary() | nil) :: :ok
  def broadcast_presence_change(_room_id, nil), do: :ok

  def broadcast_presence_change(room_id, space_id) when is_binary(space_id) do
    count = active_participant_count_for_room(room_id)
    active = count > 0

    # Per-space presence topic (ChatLive header)
    MeetingsPubSub.broadcast_presence(
      space_id,
      {:meeting_presence_update, %{space_id: space_id, active: active, count: count}}
    )

    # Global summary topic (sidebar)
    MeetingsPubSub.broadcast_presence_summary(space_id)

    :ok
  end

  def broadcast_presence_change(_room_id, _space_id), do: :ok

  # ── Private helpers ──────────────────────────────────────────────────────

  defp guard_enabled do
    if enabled?(), do: :ok, else: {:error, :meetings_disabled}
  end

  @doc false
  def room_name_for_space(space_id) do
    "space-#{space_id}"
  end

  defp livekit_config do
    app_config = Application.get_env(:platform, :livekit)

    if is_list(app_config) and app_config != [] do
      app_config
    else
      # Fall back to System env vars for backward compatibility
      url = System.get_env("LIVEKIT_URL")
      key = System.get_env("LIVEKIT_API_KEY")
      secret = System.get_env("LIVEKIT_API_SECRET")

      if url || key || secret do
        [url: url, api_key: key, api_secret: secret]
      else
        []
      end
    end
  end

  defp encode_jwt(claims, secret) do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload_b64 = claims |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = "#{header_b64}.#{payload_b64}"
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)
    sig_b64 = Base.url_encode64(signature, padding: false)

    "#{signing_input}.#{sig_b64}"
  end

  defp sign_jwt(claims, secret) do
    encode_jwt(claims, secret)
  end

  defp build_jwt(identity, name, grants) do
    config = livekit_config()
    now = System.system_time(:second)
    ttl = 6 * 60 * 60

    claims =
      Map.merge(grants, %{
        "iss" => config[:api_key],
        "sub" => identity,
        "nbf" => now,
        "exp" => now + ttl,
        "jti" => Ecto.UUID.generate(),
        "name" => name
      })

    encode_jwt(claims, config[:api_secret])
  end

  defp ensure_livekit_room(room_name) do
    config = livekit_config()
    url = config[:url]
    api_key = config[:api_key]
    api_secret = config[:api_secret]

    if is_nil(url) or is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      token =
        service_token(api_key, api_secret)

      body = Jason.encode!(%{"name" => room_name, "empty_timeout" => 300})

      twirp_url =
        url
        |> String.replace_prefix("wss://", "https://")
        |> String.replace_prefix("ws://", "http://")

      case Req.post("#{twirp_url}/twirp/livekit.RoomService/CreateRoom",
             body: body,
             headers: [
               {"content-type", "application/json"},
               {"authorization", "Bearer #{token}"}
             ],
             receive_timeout: 10_000
           ) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp service_token(api_key, api_secret) do
    now = System.system_time(:second)

    claims = %{
      "iss" => api_key,
      "nbf" => now,
      "exp" => now + 600,
      "video" => %{"roomCreate" => true}
    }

    encode_jwt(claims, api_secret)
  end

  defp active_participant_count_for_room(room_id) do
    from(p in Participant,
      where: p.room_id == ^room_id and is_nil(p.left_at)
    )
    |> Repo.aggregate(:count)
  end
end
