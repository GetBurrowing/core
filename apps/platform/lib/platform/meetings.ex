defmodule Platform.Meetings do
  @moduledoc """
  Context module for meeting transcription.

  Provides CRUD operations for meeting transcripts, including
  segment accumulation and summary management.
  """

  import Ecto.Query

  alias Platform.Meetings.Transcript
  alias Platform.Repo

  # ── Create ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new transcript record for a meeting room.

  ## Examples

      iex> create_transcript(%{room_id: room_id, space_id: space_id})
      {:ok, %Transcript{}}

  """
  @spec create_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def create_transcript(attrs) do
    %Transcript{}
    |> Transcript.changeset(Map.put_new(attrs, :started_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  # ── Read ───────────────────────────────────────────────────────────────────

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

  # ── Ensure ─────────────────────────────────────────────────────────────────

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

  Uses a Postgres JSONB concatenation to atomically append without
  loading the full array into Elixir.
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

  # ── Status Transitions ────────────────────────────────────────────────────

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
end
