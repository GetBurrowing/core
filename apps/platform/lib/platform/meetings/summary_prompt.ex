defmodule Platform.Meetings.SummaryPrompt do
  @moduledoc """
  System prompt template for meeting transcript summarization.

  Separated from the Summarizer module for easy iteration on prompt quality.
  """

  @doc """
  Returns the system prompt for meeting summarization.
  """
  def system_prompt do
    """
    You are a meeting summarizer. Given a transcript of a meeting with speaker-attributed segments, produce a concise, structured summary.

    ## Output Format

    Use the following markdown sections. Omit any section that has no relevant content.

    ### Overview
    1-2 sentences describing what the meeting was about and who participated.

    ### Key Topics
    - Bullet points of the main topics discussed
    - Keep each point to 1-2 sentences

    ### Decisions Made
    - Any decisions that were agreed upon, with brief context
    - Include who proposed or agreed if identifiable from speaker names

    ### Action Items
    - Specific next steps or tasks mentioned
    - Include the assignee if identifiable from speaker names (e.g., "Sam will...")
    - Format: "**[Person]**: [action item]" when assignee is known

    ## Guidelines
    - Be concise — aim for a summary that takes under 60 seconds to read
    - Use the speakers' names as they appear in the transcript
    - Do not fabricate information not present in the transcript
    - If the meeting was very short or had minimal content, keep the summary proportionally brief
    - If the transcript appears to be mostly silence or unintelligible, say so honestly
    """
  end

  @doc """
  Formats transcript segments into a speaker-attributed text block for the LLM.

  Each segment becomes a line: `[HH:MM:SS] Speaker: text`
  """
  def format_segments(segments) when is_list(segments) do
    segments
    |> Enum.map(&format_segment/1)
    |> Enum.join("\n")
  end

  defp format_segment(segment) do
    speaker = segment["speaker_name"] || segment["participant_identity"] || "Unknown"
    text = segment["text"] || ""
    timestamp = format_timestamp(segment["start_time"])

    "[#{timestamp}] #{speaker}: #{text}"
  end

  @doc """
  `HH:MM:SS` for a segment's `start_time` in milliseconds; `"00:00:00"` for
  nil or a non-number. Shared with `Platform.Meetings.CompletionPrompt`.
  """
  def format_timestamp(nil), do: "00:00:00"

  def format_timestamp(ms) when is_number(ms) do
    total_seconds = div(trunc(ms), 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, seconds])
    |> IO.iodata_to_binary()
  end

  def format_timestamp(_), do: "00:00:00"
end
