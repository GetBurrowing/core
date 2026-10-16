defmodule Platform.Social.TaskBridge.SegmentGuard do
  @moduledoc """
  Refuses a social ask that cites a meeting segment the live pipeline
  classed off-topic, or that a human retracted or vetoed (task 01a140a9-831e,
  Social 6/7). It reads core's public API only:
  `Platform.Meetings.Candidates.list_for_meeting/1`, read ONCE per check, and
  `Platform.Meetings.IntentRouting.unroutable_intent?/1`.

  ## What matches a segment

  A segment id is a candidate's key: the classifier sets the chunk id to the
  transcript segment's id and `record_heard/1` writes it to
  `transcript_chunk_id`. A segment threaded onto an EXISTING card gets no row
  of its own; its id is appended to that card's `transcript_chunk_ids`. So a
  candidate matches a segment when `transcript_chunk_id == id` OR
  `transcript_chunk_ids` contains it. Without the second clause, a segment
  threaded onto a retracted card would match nothing and fall through to
  `:segment_unclassified` today, and to "allowed" the day someone relaxes
  that rule. Ids are compared as strings; a non-UUID id matches nothing.

  ## The verdict (fail closed, any match wins)

  The whole request is refused if ANY cited segment:

    * has a matching row whose `classified_intent` is unroutable
      (`off_topic`), or whose `demoted_from` is set (the evidence gate
      downgraded it to off-topic) -> `:segment_off_topic`;
    * has a matching row closed `:retracted` or `:vetoed` ->
      `:segment_retracted`;
    * matches nothing, or matches only rows not yet classified
      (`classified_intent` nil) -> `:segment_unclassified` (recoverable:
      retry once the classifier has run, or cite the episode by URL and
      time).

  When several segments fail differently, the first kind in that order is
  returned, naming every segment of that kind.

  ## When to replace this module

  This interprets Meetings' candidate states from outside the context (the
  architecture review's note on plan 01a1410a). Replace it with a core read
  such as `Meetings.segment_disposition/2` when typed Scribe outputs land
  or the first time `MeetingCandidate`'s closed reasons or states change.
  """

  alias Platform.Meetings.{Candidates, IntentRouting}

  @retracted [:retracted, :vetoed]

  @type refusal :: :segment_off_topic | :segment_retracted | :segment_unclassified

  @doc """
  Checks every segment of `meeting_id`. Returns `{:ok, matched}` (the
  distinct candidates that matched any segment, oldest first) or
  `{:error, refusal, segment_ids}`.
  """
  @spec check(Ecto.UUID.t(), [String.t()]) ::
          {:ok, [Platform.Meetings.MeetingCandidate.t()]} | {:error, refusal(), [String.t()]}
  def check(meeting_id, segment_ids) when is_list(segment_ids) do
    candidates = Candidates.list_for_meeting(meeting_id)

    verdicts =
      Enum.map(segment_ids, fn id ->
        matching = Enum.filter(candidates, &matches?(&1, id))
        {id, verdict(matching), matching}
      end)

    case first_refusal(verdicts) do
      nil ->
        matched = verdicts |> Enum.flat_map(fn {_, _, m} -> m end) |> Enum.uniq_by(& &1.id)
        {:ok, Enum.filter(candidates, fn c -> Enum.any?(matched, &(&1.id == c.id)) end)}

      {kind, ids} ->
        {:error, kind, ids}
    end
  end

  @doc "Whether `candidate` carries segment `id` (its own key, or threaded onto it)."
  @spec matches?(Platform.Meetings.MeetingCandidate.t(), term()) :: boolean()
  def matches?(candidate, id) when is_binary(id) do
    to_string(candidate.transcript_chunk_id) == id or
      Enum.any?(candidate.transcript_chunk_ids || [], &(to_string(&1) == id))
  end

  def matches?(_candidate, _id), do: false

  defp verdict([]), do: :segment_unclassified

  defp verdict(matching) do
    cond do
      Enum.any?(matching, &off_topic?/1) -> :segment_off_topic
      Enum.any?(matching, &(&1.closed_reason in @retracted)) -> :segment_retracted
      Enum.all?(matching, &is_nil(&1.classified_intent)) -> :segment_unclassified
      true -> :ok
    end
  end

  defp off_topic?(candidate) do
    IntentRouting.unroutable_intent?(candidate.classified_intent) or
      not is_nil(candidate.demoted_from)
  end

  @order [:segment_off_topic, :segment_retracted, :segment_unclassified]

  defp first_refusal(verdicts) do
    Enum.find_value(@order, fn kind ->
      case for({id, ^kind, _} <- verdicts, do: id) do
        [] -> nil
        ids -> {kind, ids}
      end
    end)
  end
end
