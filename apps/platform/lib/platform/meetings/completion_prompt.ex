defmodule Platform.Meetings.CompletionPrompt do
  @moduledoc """
  Renders the agent-facing body of a meeting completion attention frame.

  Every channel plugin reads a frame's body from `message.content`, falling back
  to `signal.prompt`. The scribe and triage dispatches built by
  `Platform.Meetings.Completion` carried neither, so the plugins dropped every
  one of them and no meeting ever filed a task (task 01a18ab4). This module
  renders the DB-backed `dispatch.scribe_completion` / `dispatch.triage_dispatch`
  template into the binary the callers put in the frame's `:prompt`.

  The template stays data: `PromptTemplates.render_template/2` reads the row,
  and `render_default/2` is only the fallback for an install without one. If
  neither resolves, the body is `""`, and `Platform.Federation`'s blank-prompt
  guard refuses the dispatch with `{:error, :empty_prompt}`, which the
  completion run records and retries. A missing template is loud there, not
  silently dropped by a plugin.

  Every assign is a string. No `task_id` is passed: a completion run is not a
  task, so no experiment subject is fabricated.
  """

  alias Platform.Meetings.{Meeting, SummaryPrompt}
  alias Platform.Orchestration.PromptTemplates

  @slugs %{scribe: "dispatch.scribe_completion", triage: "dispatch.triage_dispatch"}

  @spec render(:scribe | :triage, map(), Meeting.t() | nil) :: {:ok, String.t()}
  def render(kind, payload, meeting) when is_map_key(@slugs, kind) and is_map(payload) do
    slug = Map.fetch!(@slugs, kind)
    assigns = assigns(payload, meeting)

    case PromptTemplates.render_template(slug, assigns) do
      {:ok, prompt} ->
        {:ok, prompt}

      {:error, :not_found} ->
        case PromptTemplates.render_default(slug, assigns) do
          {:ok, prompt} -> {:ok, prompt}
          {:error, _} -> {:ok, ""}
        end
    end
  end

  @doc "The string assigns both completion templates interpolate."
  @spec assigns(map(), Meeting.t() | nil) :: map()
  def assigns(payload, meeting) do
    %{
      meeting_id: str(Map.get(payload, :meeting_id)),
      run_id: str(Map.get(payload, :run_id)),
      transcript_id: str(Map.get(payload, :transcript_id)),
      snapshot_hash: str(Map.get(payload, :snapshot_hash)),
      canvas_id: str(Map.get(payload, :canvas_id)),
      space_id: str(Map.get(payload, :space_id)),
      room_id: str(Map.get(payload, :room_id)),
      meeting_name: str(meeting && meeting.name),
      execution_space_id: str((meeting && meeting.chat_space_id) || Map.get(payload, :space_id)),
      source_transcript_ids:
        payload |> Map.get(:source_transcript_ids) |> List.wrap() |> Enum.join(", "),
      accepted_action_candidates:
        Jason.encode!(List.wrap(Map.get(payload, :accepted_action_candidates)), pretty: true),
      candidate_provenance_instructions:
        str(Map.get(payload, :candidate_provenance_instructions)),
      completion_transcript: format_transcript(Map.get(payload, :completion_transcript)),
      federation_preamble: PromptTemplates.federation_preamble(%{})
    }
  end

  @doc """
  One segment per line: `<segment id> | <HH:MM:SS> | <speaker>: <text>`.

  The segment id leads each line because `meeting_triage_file` requires
  `source_segment_ids` from this snapshot. The timestamp and speaker are
  formatted exactly as `SummaryPrompt.format_segments/1` formats them.
  """
  @spec format_transcript([map()] | nil) :: String.t()
  def format_transcript(segments) do
    segments
    |> List.wrap()
    |> Enum.map_join("\n", fn segment ->
      speaker = segment["speaker_name"] || segment["participant_identity"] || "Unknown"
      timestamp = SummaryPrompt.format_timestamp(segment["start_time"])
      "#{str(segment["id"])} | #{timestamp} | #{speaker}: #{segment["text"] || ""}"
    end)
  end

  defp str(nil), do: ""
  defp str(value) when is_binary(value), do: value
  defp str(value), do: to_string(value)
end
